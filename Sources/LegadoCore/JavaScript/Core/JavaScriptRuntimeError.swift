import Foundation

/// QuickJS 运行环境的统一错误类型。
///
/// 三条设计约束（来自迁移指南第八节，并按工程实际修正）：
/// 1. 不把异常简单转换成 `null`：每条失败都带出脚本标识、行号或堆栈；
/// 2. 不另起诊断体系：通过 `ruleError` 映射回既有 `RuleEngineError`，
///    让上层 `RuleDiagnostic` 与 `rule.resource_limit` 等稳定码继续有效；
/// 3. 资源类失败与语义类失败分开：前者应提示「规则过大 / 超时」，
///    后者应提示「书源规则有误」，两者在 UI 上的处理策略不同。
public enum JavaScriptRuntimeError: Error, Equatable, Sendable {
    /// `JS_NewRuntime` 返回 NULL。
    case runtimeInitializationFailed(detail: String)
    /// `JS_NewContext` 返回 NULL。
    case contextInitializationFailed(detail: String)
    /// 解析期失败。用 `JS_EVAL_FLAG_COMPILE_ONLY` 先编译，此时脚本一行都还没执行。
    case syntaxError(script: String, detail: String, line: Int?)
    /// 执行期抛出的异常，包含脚本自己 `throw` 的对象。
    case thrown(script: String, detail: String, stack: String?)
    /// 注册进 Context 的宿主函数自身失败（网络、Cookie、加解密等）。
    case hostCallFailed(function: String, detail: String)
    /// 规则脚本超过 `maximumRuleLength`。
    case ruleTooLong(limit: Int, actual: Int)
    /// 书源 jsLib 超过 `maximumJSLibLength`。
    case libraryTooLong(limit: Int, actual: Int)
    /// 返回值超过 `maximumResultLength`。
    case resultTooLong(limit: Int, actual: Int)
    /// 触到 `JS_SetMemoryLimit` 上限。
    case memoryLimitExceeded(limit: Int)
    /// 触到中断回调的截止时间。
    case executionTimedOut(limitMilliseconds: Int)
    /// QuickJS 值与 Swift 值互转失败。
    case valueConversionFailed(detail: String)

    /// 与 `RuleEngineError.code` 保持同一套字符串，便于日志与 UI 复用。
    public var code: String {
        switch self {
        case .ruleTooLong, .libraryTooLong, .resultTooLong,
             .memoryLimitExceeded, .executionTimedOut:
            return "rule.resource_limit"
        case .runtimeInitializationFailed, .contextInitializationFailed, .valueConversionFailed:
            return "rule.invalid_input"
        case .syntaxError, .thrown, .hostCallFailed:
            return "rule.malformed"
        }
    }

    /// 是否属于资源限制类失败。上层据此决定「跳过该规则」还是「报书源错误」。
    public var isResourceFailure: Bool {
        switch self {
        case .ruleTooLong, .libraryTooLong, .resultTooLong,
             .memoryLimitExceeded, .executionTimedOut:
            return true
        default:
            return false
        }
    }

    /// 映射回既有错误类型，避免上层出现第二套诊断码。
    public var ruleError: RuleEngineError {
        switch self {
        case .ruleTooLong(_, let actual):
            return .resourceLimit(rule: "", detail: "JavaScript 规则超过长度上限（实际 \(actual) 字节）")
        case .libraryTooLong(_, let actual):
            return .resourceLimit(rule: "", detail: "书源 jsLib 超过长度上限（实际 \(actual) 字节）")
        case .resultTooLong(_, let actual):
            return .resourceLimit(rule: "", detail: "JavaScript 结果超过长度上限（实际 \(actual) 字节）")
        case .memoryLimitExceeded(let limit):
            return .resourceLimit(rule: "", detail: "JavaScript 内存用量超过上限（\(limit) 字节）")
        case .executionTimedOut(let milliseconds):
            return .resourceLimit(rule: "", detail: "JavaScript 执行超过时间上限（\(milliseconds) 毫秒）")
        case .syntaxError(let script, let detail, let line):
            return .malformedRule(rule: Self.preview(script), detail: Self.withLine(detail, line))
        case .thrown(let script, let detail, let stack):
            let combined = stack.map { "\(detail)\n\($0)" } ?? detail
            return .malformedRule(rule: Self.preview(script), detail: combined)
        case .hostCallFailed(let function, let detail):
            return .malformedRule(rule: function, detail: detail)
        case .runtimeInitializationFailed(let detail):
            return .invalidInput(rule: "QuickJSRuntime", expected: detail)
        case .contextInitializationFailed(let detail):
            return .invalidInput(rule: "QuickJSContext", expected: detail)
        case .valueConversionFailed(let detail):
            return .invalidInput(rule: "QuickJSValueConverter", expected: detail)
        }
    }

    /// 截断脚本预览，避免把 1MB 规则整段塞进诊断或日志。
    private static func preview(_ script: String) -> String {
        let limit = 160
        guard script.count > limit else { return script }
        return String(script.prefix(limit)) + "…"
    }

    private static func withLine(_ detail: String, _ line: Int?) -> String {
        guard let line else { return detail }
        return "第 \(line) 行：\(detail)"
    }
}

/// QuickJS 侧所有失败都以该类型抛出，调用方只需捕获一种错误。
extension JavaScriptRuntimeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .runtimeInitializationFailed(let detail):
            return "QuickJS Runtime 初始化失败：\(detail)"
        case .contextInitializationFailed(let detail):
            return "QuickJS Context 初始化失败：\(detail)"
        case .syntaxError(_, let detail, let line):
            return "JavaScript 语法错误：\(Self.withLine(detail, line))"
        case .thrown(_, let detail, _):
            return "JavaScript 执行失败：\(detail)"
        case .hostCallFailed(let function, let detail):
            return "宿主接口 \(function) 调用失败：\(detail)"
        case .ruleTooLong(let limit, let actual):
            return "JavaScript 规则超过长度上限：\(actual) / \(limit) 字节"
        case .libraryTooLong(let limit, let actual):
            return "书源 jsLib 超过长度上限：\(actual) / \(limit) 字节"
        case .resultTooLong(let limit, let actual):
            return "JavaScript 结果超过长度上限：\(actual) / \(limit) 字节"
        case .memoryLimitExceeded(let limit):
            return "JavaScript 内存超限：上限 \(limit) 字节"
        case .executionTimedOut(let milliseconds):
            return "JavaScript 执行超时：上限 \(milliseconds) ms"
        case .valueConversionFailed(let detail):
            return "JavaScript 值转换失败：\(detail)"
        }
    }
}
