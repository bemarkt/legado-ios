import Foundation
import CQuickJS

/// 一个 `JSContext` 的 Swift 持有者。
///
/// 生命周期约定（依据 QuickJS 实际 API 语义，不照搬 JSC 的 JSVirtualMachine）：
/// - Context 由 Runtime 创建，必须先于 Runtime 释放；`deinit` 里只做 `JS_FreeContext`。
/// - 任何 `JSValue` 都归属创建它的 Runtime，跨 Runtime 传递是未定义行为，这里不提供该能力。
/// - Context 不是线程安全的；调用方保证同一 Runtime/Context 只在单一线程上使用。
public final class QuickJSContext {

    /// 宿主函数签名：拿到上下文、this、参数，返回一个**已拥有所有权**的 `JSValue`。
    public typealias HostFunction = (QuickJSContext, JSValue, [JSValue]) throws -> JSValue

    let runtime: QuickJSRuntime
    let rawContext: OpaquePointer

    private var hostFunctions: [Int32: HostFunction] = [:]
    private var nextHostFunctionID: Int32 = 1

    /// C 侧宿主函数桥。里面只有 self 的 unretained 指针与一个未类型化函数指针，
    /// 由 `qjs_shim.c` 的 trampoline 通过 `JS_GetContextOpaque` 取回。
    private var bridge: UnsafeMutableRawPointer?

    public init(runtime: QuickJSRuntime) throws {
        guard let context = JS_NewContext(runtime.rawRuntime) else {
            throw JavaScriptRuntimeError.contextInitializationFailed(detail: "JS_NewContext 返回 NULL")
        }
        self.runtime = runtime
        self.rawContext = context
        // unretained 是必须的：Context 持有该桥，retained 会形成自持环、永不释放。
        // 函数指针用 unsafeBitCast 过桥，而不是让 Swift 直接把 `@convention(c)` 值
        // 交给 `JS_NewCFunctionData`——那条链上 Swift 推断不出类型（CI 实测
        // "type of expression is ambiguous without a type annotation"）。
        let created = qjs_host_bridge_new(
            Unmanaged.passUnretained(self).toOpaque(),
            unsafeBitCast(legadoHostCall, to: UnsafeMutableRawPointer.self)
        )
        bridge = created
        JS_SetContextOpaque(context, created)
    }

    deinit {
        // 先让引擎彻底停下（可能触发 JS 对象析构），再释放桥。
        // 顺序反了会让析构期仍在跑的宿主函数读到已释放的桥。
        JS_SetContextOpaque(rawContext, nil)
        JS_FreeContext(rawContext)
        if let bridge { qjs_host_bridge_free(bridge) }
    }

    // MARK: - 全局对象

    public var globalObject: JSValue {
        JS_GetGlobalObject(rawContext)
    }

    /// 设置全局变量；`value` 的所有权转移给引擎。
    public func setGlobal(_ name: String, value: JSValue) {
        let global = JS_GetGlobalObject(rawContext)
        JS_SetPropertyStr(rawContext, global, name, value)
        JS_FreeValue(rawContext, global)
    }

    // MARK: - 宿主函数注册

    /// 构造一个绑定到 Swift 闭包的 JS 函数值，所有权交给调用方。
    ///
    /// 拆成独立方法的原因：`source.*` / `book.*` / `chapter.*` / `cookie.*` 是
    /// 「在命名空间对象上挂方法」，不是全局函数。只有能先拿到函数值，
    /// 才挂得到任意对象上；否则宿主层只能退化成全局函数，
    /// 书源里 `source.getKey()` 这类写法会全部失效。
    ///
    /// 函数对象的构造放在 C 侧（`qjs_new_host_function`）：Swift 这里只传标量、
    /// C 字符串与一个整数标识，`JS_NewCFunctionData` 的指针运算全部留在 shim 里。
    public func makeFunction(argumentCount: Int = 0, body: @escaping HostFunction) -> JSValue {
        let identifier = nextHostFunctionID
        nextHostFunctionID += 1
        hostFunctions[identifier] = body

        return "legadoHost".withCString { pointer in
            qjs_new_host_function(rawContext, pointer, Int32(argumentCount), identifier)
        }
    }

    public func defineFunction(_ name: String, argumentCount: Int = 0, body: @escaping HostFunction) {
        setGlobal(name, value: makeFunction(argumentCount: argumentCount, body: body))
    }

    /// 在指定对象上挂属性或方法。值的所有权转移给引擎。
    public func setProperty(_ name: String, on object: JSValue, value: JSValue) {
        JS_SetPropertyStr(rawContext, object, name, value)
    }

    // MARK: - 求值

    /// 执行脚本。异常一律转成 `JavaScriptRuntimeError`，不返回 null 静默吞掉。
    public func evaluate(_ script: String, filename: String = "legado-rule.js") throws -> JSValue {
        runtime.beginExecution()
        defer { runtime.endExecution() }

        let result = script.withCString { pointer in
            JS_Eval(rawContext, pointer, script.utf8.count, filename, qjs_eval_type_global())
        }
        // 与 compile / runCompiled 保持一致，统一走 shim 包装，
        // 不直接绑 quickjs.h 里的 static inline 谓词。
        if qjs_is_exception(result) {
            throw captureException(script: script)
        }
        return result
    }

    /// 只编译不执行，返回函数字节码（`JS_TAG_FUNCTION_BYTECODE`）。
    ///
    /// 编译产物属于 Runtime 而非 Context，可以被同一 Runtime 下的多个 Context
    /// 反复执行——这正是 `replacementEvaluator` 多轮匹配复用 jsLib 的基础。
    /// 语法错误在这一步就会暴露，而不是等到执行到一半才发现。
    // ⚠️ realm 约束：字节码绑定**编译时所在的 Context**（realm）的全局对象。
    // 换一个 Context 去 JS_EvalFunction，脚本读到的仍是原 realm 的全局名，
    // 表现为 ReferenceError: java / result is not defined，
    // 释放阶段还可能因跨 realm 持有字节码而崩溃（signal 11）。
    // 因此只在「同一 Context 内编译并执行」的场景使用；
    // replacementEvaluator 已改为每轮在同一 Context 内求值，不再跨 Context 复用字节码。
    public func compile(_ script: String, filename: String = "legado-rule.js") throws -> JSValue {
        // 编译期同样要挂截止时间：4MB jsLib 的解析本身可能耗时很长，
        // 不 arm deadline 就等于留了一条「靠超大脚本把执行时间推长」的绕过路径。
        runtime.beginExecution()
        defer { runtime.endExecution() }

        let flags = qjs_eval_type_global() | qjs_eval_flag_compile_only()
        let result = script.withCString { pointer in
            JS_Eval(rawContext, pointer, script.utf8.count, filename, flags)
        }
        if qjs_is_exception(result) {
            throw captureException(script: script)
        }
        return result
    }

    /// 执行已编译的字节码。
    ///
    /// `JS_EvalFunction` 会接管传入值的所有权，因此先 dup 一份再交给它，
    /// 调用方持有的字节码在下一轮匹配里仍然可用。
    func runCompiled(_ function: JSValue, filename: String = "legado-compiled.js") throws -> JSValue {
        runtime.beginExecution()
        defer { runtime.endExecution() }
        let copy = JS_DupValue(rawContext, function)
        let result = JS_EvalFunction(rawContext, copy)
        if qjs_is_exception(result) {
            throw captureException(script: "<compiled \(filename)>")
        }
        return result
    }

    /// 取出并清空引擎异常状态，映射成统一错误。
    func captureException(script: String) -> JavaScriptRuntimeError {
        // 时间上限触发的 `JS_TAG_EXCEPTION` 与脚本自身抛错在 C 侧同形，
        // 用截止时间判定优先归类为超时，便于上层提示「规则过于复杂」。
        let timedOut = runtime.didTimeOut
        let exception = JS_GetException(rawContext)
        let detail = string(from: exception) ?? "未知 JavaScript 异常"
        JS_FreeValue(rawContext, exception)
        if timedOut { return runtime.timeoutError() }
        return .thrown(script: script, detail: detail, stack: nil)
    }

    /// 在宿主函数里把 Swift 错误抛回 JS 侧。
    func throwString(_ message: String) -> JSValue {
        let text = message.isEmpty ? "宿主接口调用失败" : message
        let value = text.withCString { JS_NewStringLen(rawContext, $0, text.utf8.count) }
        _ = JS_Throw(rawContext, value)
        return qjs_exception()
    }

    // MARK: - 取值

    /// `JS_ToCStringLen2` 的长度是字节数，按 UTF-8 解码可以保留中文与 emoji。
    public func string(from value: JSValue) -> String? {
        guard !qjs_is_undefined(value), !qjs_is_null(value),
              !qjs_is_exception(value), !qjs_is_uninitialized(value) else { return nil }
        var length = 0
        guard let pointer = JS_ToCStringLen2(rawContext, &length, value, false) else { return nil }
        defer { JS_FreeCString(rawContext, pointer) }
        let bytes = UnsafeBufferPointer(start: pointer, count: length).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// 把任意 JS 值收敛成 `JSONValue`。
    ///
    /// 对象与数组走 `JS_JSONStringify` + `JSONValue.decode`，避免在 Swift 侧
    /// 手工枚举 `JSPropertyEnum`（那需要处理二级指针的所有权，出错就是泄漏或野指针）。
    public func jsonValue(from value: JSValue) -> JSONValue {
        if qjs_is_null(value) || qjs_is_undefined(value) { return .null }
        if qjs_is_bool(value) { return .bool(qjs_to_bool(rawContext, value) == 1) }
        if qjs_is_number(value) {
            var ok = false
            let number = qjs_to_double(rawContext, value, &ok)
            guard ok else { return .null }
            return number.isFinite ? .number(number) : .null
        }
        if qjs_is_string(value) { return .string(string(from: value) ?? "") }

        let stringified = JS_JSONStringify(rawContext, value, qjs_undefined(), qjs_undefined())
        if qjs_is_exception(stringified) {
            // 清空异常状态，否则后续求值会被污染。
            let exception = JS_GetException(rawContext)
            JS_FreeValue(rawContext, exception)
            return .string(string(from: value) ?? "")
        }
        defer { JS_FreeValue(rawContext, stringified) }
        guard let text = string(from: stringified) else { return .null }
        return (try? JSONValue.decode(data: Data(text.utf8))) ?? .null
    }

    public func release(_ value: JSValue) {
        JS_FreeValue(rawContext, value)
    }

    /// 复制一个值以延长其生命周期。
    ///
    /// 宿主函数收到的入参所有权属于调用方（`JSCFunctionData` 的 `argv` 只是借用），
    /// 任何「把入参原样返回」的宿主函数（`__legadoLog`、`source.put` 的返回值等）
    /// 都必须先 dup，否则返回后原值被释放、JS 侧拿到悬垂引用。
    public func duplicate(_ value: JSValue) -> JSValue {
        JS_DupValue(rawContext, value)
    }
}

/// 宿主函数分发回调，由 `qjs_shim.c` 的 `legado_host_trampoline` 调用。
///
/// Swift 只允许 `@convention(c)` 修饰函数**类型**，标在 `func` 声明上是非法语法
/// （CI 实测：attribute can only be applied to types, not declarations），
/// 所以这里写成带 C 函数类型的常量闭包；闭包不捕获任何上下文，
/// 才能合法转成 C 函数指针。
///
/// 形参顺序与 C 侧 `LegadoHostCall` 逐一对齐：
/// swiftContext / ctx / this_val / argc / argv / identifier。
private let legadoHostCall: @convention(c) (
    UnsafeMutableRawPointer?,
    OpaquePointer?,
    JSValue,
    Int32,
    UnsafePointer<JSValue>?,
    Int32
) -> JSValue = { swiftContext, ctx, thisValue, argc, argv, identifier in
    guard let swiftContext, ctx != nil else { return qjs_exception() }
    let context = Unmanaged<QuickJSContext>.fromOpaque(swiftContext).takeUnretainedValue()
    guard let body = context.hostFunction(for: identifier) else { return qjs_exception() }

    var arguments: [JSValue] = []
    if let argv, argc > 0 {
        arguments = Array(UnsafeBufferPointer(start: argv, count: Int(argc)))
    }

    do {
        return try body(context, thisValue, arguments)
    } catch let error as JavaScriptRuntimeError {
        return context.throwString(error.errorDescription ?? "宿主接口调用失败")
    } catch {
        return context.throwString(error.localizedDescription)
    }
}

extension QuickJSContext {
    func hostFunction(for identifier: Int32) -> HostFunction? {
        hostFunctions[identifier]
    }
}
