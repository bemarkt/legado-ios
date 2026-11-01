import Foundation
import CQuickJS

/// JavaScript 执行的资源上限。
///
/// 迁移指南给出的三档长度只是初始值；这里额外把内存与栈也做成显式配置。
/// 关键修正：默认内存/栈上限与 jsLib 体积联动，而不是写死固定值——
/// 4MB 的 jsLib 配 1MB 默认栈会在深层解析时爆栈，这是照抄默认参数最容易踩的坑。
public struct JavaScriptRuntimeLimits: Sendable, Equatable {
    public var maximumRuleLength: Int
    public var maximumJSLibLength: Int
    public var maximumResultLength: Int
    public var maximumMemoryBytes: Int
    public var maximumStackBytes: Int
    public var timeoutMilliseconds: Int

    public init(
        maximumRuleLength: Int = 1_048_576,
        maximumJSLibLength: Int = 4_194_304,
        maximumResultLength: Int = 2_097_152,
        maximumMemoryBytes: Int? = nil,
        maximumStackBytes: Int? = nil,
        timeoutMilliseconds: Int = 5_000
    ) {
        self.maximumRuleLength = max(0, maximumRuleLength)
        self.maximumJSLibLength = max(0, maximumJSLibLength)
        self.maximumResultLength = max(0, maximumResultLength)
        // 载荷 + 32MB 余量：JS 引擎自身的对象头、原子表与 GC 需要额外空间，
        // 若上限恰好等于载荷字节数，正常脚本也会被判定 OOM。
        let payload = self.maximumRuleLength + self.maximumJSLibLength + self.maximumResultLength
        self.maximumMemoryBytes = max(0, maximumMemoryBytes ?? (payload + 33_554_432))
        self.maximumStackBytes = max(
            0,
            maximumStackBytes ?? max(2_097_152, 1_048_576 + self.maximumJSLibLength / 4)
        )
        self.timeoutMilliseconds = max(1, timeoutMilliseconds)
    }
}

/// 中断回调与宿主线程之间共享的截止时间。
///
/// QuickJS 的中断回调在 JS 执行线程上同步调用，与 `arm`/`disarm` 不必然同线程，
/// 所以用锁而不是裸 var，避免读到撕裂的 `DispatchTime`。
final class JavaScriptDeadlineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var deadline: DispatchTime?

    func arm(milliseconds: Int) {
        lock.lock()
        deadline = DispatchTime.now() + .milliseconds(max(1, milliseconds))
        lock.unlock()
    }

    func disarm() {
        lock.lock()
        deadline = nil
        lock.unlock()
    }

    /// 返回 true 表示应中断执行。
    func shouldInterrupt() -> Bool {
        lock.lock()
        let target = deadline
        lock.unlock()
        guard let target else { return false }
        return DispatchTime.now() >= target
    }
}

/// 全局函数（无捕获）才能转成 C 函数指针，这是 `JS_SetInterruptHandler` 的要求。
/// Swift **不允许**把
/// `@convention(c)` 标在 `func` 声明上（CI 实测报错：
/// "attribute can only be applied to types, not declarations"）。
/// 该属性只能修饰函数类型，因此这里声明成带 C 函数类型的常量闭包；
/// 闭包不捕获任何上下文，才能合法转成 C 函数指针。
private let legadoQuickJSInterruptHandler: @convention(c) (
    OpaquePointer?,
    UnsafeMutableRawPointer?
) -> Int32 = { _, opaque in
    guard let opaque else { return 0 }
    let box = Unmanaged<JavaScriptDeadlineBox>.fromOpaque(opaque).takeUnretainedValue()
    return box.shouldInterrupt() ? 1 : 0
}

/// 一个 `JSRuntime` 的 Swift 持有者。
///
/// 生命周期约定（依据 QuickJS 实际 API 语义，不照搬 JSC 的 VirtualMachine）：
/// - 一个 Runtime 只能在创建它的线程上使用，禁止跨线程并发；
/// - Context 由 Runtime 创建，释放顺序必须先 Context 后 Runtime；
/// - Runtime 负责内存上限、栈上限与中断回调，这些是 Runtime 级配置而非 Context 级。
public final class QuickJSRuntime {
    public let limits: JavaScriptRuntimeLimits

    /// 直接暴露给同模块的 QuickJSContext 使用；对外不公开，避免上层绕过封装调 C API。
    let rawRuntime: OpaquePointer

    private let deadlineBox = JavaScriptDeadlineBox()

    public init(limits: JavaScriptRuntimeLimits = JavaScriptRuntimeLimits()) throws {
        guard let runtime = JS_NewRuntime() else {
            throw JavaScriptRuntimeError.runtimeInitializationFailed(detail: "JS_NewRuntime 返回 NULL（内存不足或引擎未正确链接）")
        }
        rawRuntime = runtime
        self.limits = limits

        JS_SetMemoryLimit(runtime, limits.maximumMemoryBytes)
        JS_SetMaxStackSize(runtime, limits.maximumStackBytes)
        // 单线程执行，不需要 Atomics.wait 的阻塞能力。
        JS_SetCanBlock(runtime, false)

        let opaque = Unmanaged.passUnretained(deadlineBox).toOpaque()
        JS_SetInterruptHandler(runtime, legadoQuickJSInterruptHandler, opaque)
    }

    deinit {
        JS_SetInterruptHandler(rawRuntime, nil, nil)
        JS_FreeRuntime(rawRuntime)
    }

    /// 每次开始执行前调用：重置截止时间并同步栈顶。
    ///
    /// `JS_UpdateStackTop` 必须在真正执行 JS 的线程上调用，否则栈溢出检测
    /// 会基于错误的栈指针误判（这是跨线程复用 Runtime 时最常见的崩溃原因）。
    func beginExecution() {
        deadlineBox.arm(milliseconds: limits.timeoutMilliseconds)
        JS_UpdateStackTop(rawRuntime)
    }

    func endExecution() {
        deadlineBox.disarm()
    }

    /// 超时后生成统一错误，供 Context 在拿到 `JS_TAG_EXCEPTION` 时优先返回。
    func timeoutError() -> JavaScriptRuntimeError {
        .executionTimedOut(limitMilliseconds: limits.timeoutMilliseconds)
    }

    var didTimeOut: Bool {
        deadlineBox.shouldInterrupt()
    }
}
