import Foundation
import CQuickJS

/// 把 QuickJS Context 组装成「可直接执行书源脚本」的完整环境。
///
/// 存在的意义是**顺序**：各宿主层单独都能用，但注入次序错了会静默坏掉，
/// 而这类错误在书源侧只表现为「某个方法不是函数」，很难从诊断反推到装配顺序。
/// 因此把顺序固化在这里，并逐条注明为什么不能调换。
///
/// 注入次序与理由：
///  1. `result` / `src` / `$` / `baseUrl` / `key` / `page` —— 基础值，后续任何脚本都可能读到。
///  2. 纯函数宿主（`__legadoUTF8Bytes` / `__legadoAESCBC` / `__legado*`）—— 无依赖，最底层。
///  3. Cookie 宿主 + `cookieBridge` —— `cookie` 对象的方法挂好之后，胶水才能补 map/header 互转。
///  4. 网络宿主 —— `java` 层要从全局取用这几个函数值，必须先生成。
///  5. 实体宿主（`source` / `book` / `chapter`）—— `sourceBridge` 依赖 `source` 对象存在。
///  6. `java` 本体 —— 依赖网络与 Cookie 的全局函数。
///  7. 胶水脚本：`consoleBridge` → `jsonParsePatch` → `javaBridge` → `sourceBridge` → `javaImporter`。
///     `javaImporter` 必须最后，且必须早于 jsLib 与规则脚本。
enum JavaScriptHostInstaller {

    /// 组装时需要的全部外部依赖。
    ///
    /// 网络相关的两个闭包由调用方（`JavaScriptRuleEvaluator`）提供，而不是在这里重建：
    /// URL 解析涉及 `LegadoURLBuilder` 的 js 参数、charset、retry、bodyJs 等书源语法，
    /// 请求执行涉及代理 / Hosts / 证书策略。这两块都是既有逻辑，在这里重写一遍
    /// 等于迁移顺手改了书源的网络语义。
    struct Dependencies {
        var result: JSONValue
        var variables: JavaScriptVariableBox
        var executionContext: RuleExecutionContext
        var byteLimit: Int
        var loadAjax: JavaScriptNetworkHost.AjaxLoader
        var loadDirect: JavaScriptNetworkHost.DirectLoader
        var evaluateStringRule: JavaScriptJavaHosts.StringRuleEvaluator
        var evaluateStringListRule: JavaScriptJavaHosts.StringRuleListEvaluator
    }

    /// 创建并装好一个 Context。调用方负责在合适的线程上创建 Runtime 并持有它。
    static func makeContext(runtime: QuickJSRuntime, dependencies: Dependencies) throws -> QuickJSContext {
        let context = try QuickJSContext(runtime: runtime)
        installBaseValues(dependencies, into: context)
        installHosts(dependencies, into: context)
        try installBootstrapScripts(dependencies, into: context)
        return context
    }

    // MARK: - 基础值

    private static func installBaseValues(_ dependencies: Dependencies, into context: QuickJSContext) {
        let executionContext = dependencies.executionContext
        // 登录检测脚本里的 `result` 是「带 body() 方法的响应对象」，不是纯字符串：
        // 书源统一写成 `String(result.body())`。用 responseBody 显式开关，
        // 普通规则求值完全不受影响（那里 result 就是规则输入本身）。
        let resultValue: JSValue
        if let body = executionContext.responseBody {
            resultValue = responseObject(body: body, in: context)
        } else {
            resultValue = QuickJSValueConverter.value(from: dependencies.result, in: context)
        }

        // `result` / `$` 指向同一份数据的两个名字，`src` 优先取 context.content。
        // JS_SetPropertyStr 接管所有权，所以除第一次之外全部要 dup：
        // 复用同一个 JSValue 会让第一个赋值之后的引用指向已释放对象，
        // 表现为脚本读到随机内存或直接崩溃。
        // 先把三个值全部准备好，再统一赋值。
        // 反过来写（先 setGlobal("result") 再 duplicate(resultValue)）虽然此刻不会出错
        // ——对象还被 result 属性持有——但依赖这种「恰好还活着」的时序是脆弱的，
        // 换一处调用点或调整属性释放时机就会变成悬垂引用。
        let sourceContent = executionContext.content ?? dependencies.result
        let srcValue: JSValue
        if case .null = sourceContent {
            srcValue = context.duplicate(resultValue)
        } else {
            srcValue = QuickJSValueConverter.value(from: sourceContent, in: context)
        }
        let dollarValue = context.duplicate(resultValue)
        context.setGlobal("result", value: resultValue)
        context.setGlobal("$", value: dollarValue)
        context.setGlobal("src", value: srcValue)

        // UA 必须由 Swift 侧注入，不能拼进 JS 源码：UA 是用户可配置项，
        // 含单引号或反斜杠时会把整段胶水脚本变成语法错误，
        // 而 bootstrap 一挂就是 java / source / cookie 全部不可用。
        context.setGlobal(
            "__legadoUserAgent",
            value: QuickJSValueConverter.stringValue(
                ApplicationSettingsStore.shared.settings.effectiveUserAgent,
                in: context
            )
        )
        context.setGlobal("baseUrl", value: QuickJSValueConverter.stringValue(executionContext.baseURL, in: context))
        context.setGlobal("key", value: QuickJSValueConverter.stringValue(executionContext.key ?? "", in: context))
        context.setGlobal("page", value: qjs_new_number(context.rawContext, Double(executionContext.page ?? 0)))
    }

    /// 构造登录检测用的响应对象：`result.body()` 返回当前页面 HTML。
    ///
    /// 只提供书源实际用到的两个方法。`toString` 也指向正文，
    /// 因为部分书源会写 `String(result)` 而不是 `result.body()`。
    private static func responseObject(body: String, in context: QuickJSContext) -> JSValue {
        let object = JS_NewObject(context.rawContext)
        context.setProperty("body", on: object, value: context.makeFunction { ctx, _, _ in
            QuickJSValueConverter.stringValue(body, in: ctx)
        })
        context.setProperty("toString", on: object, value: context.makeFunction { ctx, _, _ in
            QuickJSValueConverter.stringValue(body, in: ctx)
        })
        return object
    }

    // MARK: - 宿主层

    private static func installHosts(_ dependencies: Dependencies, into context: QuickJSContext) {
        JavaScriptPrimitiveHosts(byteLimit: dependencies.byteLimit).install(into: context)
        JavaScriptCookieHost().install(into: context)
        JavaScriptNetworkHost(
            loadAjax: dependencies.loadAjax,
            loadDirect: dependencies.loadDirect,
            maximumResultBytes: dependencies.byteLimit
        ).install(into: context)
        JavaScriptEntityHosts(
            source: dependencies.executionContext.source,
            book: dependencies.executionContext.book,
            chapter: dependencies.executionContext.chapter
        ).install(into: context)
        // `org.jsoup` 桥必须先于 javaImporter / 规则脚本注入：
        // 书源正文规则第一句就是 `org.jsoup.Jsoup.parse(result)`。
        JavaScriptJsoupHost(byteLimit: dependencies.byteLimit).install(into: context)
        JavaScriptJavaHosts(
            variables: dependencies.variables,
            executionContext: dependencies.executionContext,
            byteLimit: dependencies.byteLimit,
            evaluateStringRule: dependencies.evaluateStringRule,
            evaluateStringListRule: dependencies.evaluateStringListRule
        ).install(into: context)
    }

    // MARK: - 胶水脚本

    private static func installBootstrapScripts(_ dependencies: Dependencies, into context: QuickJSContext) throws {
        // 顺序不可调换，理由见类型注释第 7 条。
        try run(RhinoCompatibilityScripts.consoleBridge, named: "console-bridge.js", in: context)
        try run(RhinoCompatibilityScripts.jsonParsePatch, named: "json-parse-patch.js", in: context)
        // `cookie` 对象的方法已由 JavaScriptCookieHost 挂好，这里只补纯 JS 的 map/header 互转。
        try run(RhinoCompatibilityScripts.cookieBridge, named: "cookie-compat.js", in: context)
        try run(RhinoCompatibilityScripts.javaBridge, named: "java-bridge.js", in: context)
        // 没有书源上下文时 source 对象不存在，注入 sourceBridge 会直接抛 ReferenceError。
        if dependencies.executionContext.source != nil {
            try run(RhinoCompatibilityScripts.sourceBridge, named: "source-bridge.js", in: context)
        }
        try run(RhinoCompatibilityScripts.javaImporter, named: "java-importer.js", in: context)
        // `org.jsoup` 与 JavaImporter 并列，但必须在规则脚本之前就位。
        try run(RhinoCompatibilityScripts.jsoupBridge, named: "jsoup-bridge.js", in: context)
    }

    /// 执行一段胶水脚本。
    ///
    /// 这里不吞异常：胶水注入失败意味着整个执行环境不可用，
    /// 静默继续只会让后续每条规则都报「xxx is not a function」，
    /// 把真正的原因埋掉。
    private static func run(_ script: String, named filename: String, in context: QuickJSContext) throws {
        let value = try context.evaluate(script, filename: filename)
        context.release(value)
    }

    // MARK: - jsLib

    /// 注入书源共享脚本（jsLib）。
    ///
    /// 长度按 UTF-8 字节数与 `maximumJSLibLength` 比较，而不是字符数：
    /// 中文注释占 3 字节，按字符数算会让限额虚高到三倍。
    /// 同时不再用任何字符串黑名单预检——非法死循环交给中断回调处理，
    /// 文本匹配既误杀合法脚本又拦不住真死循环。
    static func installLibrary(
        _ library: String,
        limits: JavaScriptRuntimeLimits,
        into context: QuickJSContext
    ) throws {
        let trimmed = library.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let byteCount = trimmed.utf8.count
        guard byteCount <= limits.maximumJSLibLength else {
            throw JavaScriptRuntimeError.libraryTooLong(
                limit: limits.maximumJSLibLength,
                actual: byteCount
            )
        }
        let value = try context.evaluate(trimmed, filename: "jsLib.js")
        context.release(value)
    }
}
