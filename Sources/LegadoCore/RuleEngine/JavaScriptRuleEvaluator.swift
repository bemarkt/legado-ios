import Foundation
import CQuickJS

public struct RuleExecutionContext: Sendable {
    public var variables: [String: String]
    public var baseURL: String
    public var key: String?
    public var page: Int?
    public var source: BookSource?
    public var book: Book?
    public var chapter: BookChapter?
    public var isHTMLFragment: Bool
    public var content: JSONValue?
    /// 登录检测脚本专用：把 `result` 绑定成「带 body() 方法的响应对象」。
    ///
    /// 书源的 `loginCheckJs` 统一写成 `String(result.body())`（Legado 语义里
    /// `result` 就是当前页面的响应对象），而普通规则求值里的 `result` 是规则输入本身。
    /// 用显式字段区分，避免改动普通规则求值时 `result` 的类型。
    public var responseBody: String?
    public var environment: JavaScriptHostEnvironment?
    var hostEnvironment: JavaScriptHostEnvironment { environment ?? .legacy }

    public init(
        variables: [String: String] = [:],
        baseURL: String = "",
        key: String? = nil,
        page: Int? = nil,
        source: BookSource? = nil,
        book: Book? = nil,
        chapter: BookChapter? = nil,
        isHTMLFragment: Bool = false,
        content: JSONValue? = nil,
        responseBody: String? = nil,
        environment: JavaScriptHostEnvironment? = nil
    ) {
        self.variables = variables
        self.baseURL = baseURL
        self.key = key
        self.page = page
        self.source = source
        self.book = book
        self.chapter = chapter
        self.isHTMLFragment = isHTMLFragment
        self.content = content
        self.responseBody = responseBody
        self.environment = environment
    }
}

public struct JavaScriptRuleResult: Sendable {
    public var value: JSONValue
    public var variables: [String: String]
}

/// JavaScript's synchronous network bridges can block. Keep those calls off
/// Swift's cooperative executor and off shared actors such as the cookie policy.
enum RuleExecutionWorker {
    static func run<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        let result = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try operation() })
            }
        }
        try Task.checkCancellation()
        return result
    }
}

public protocol JavaScriptNetworkLoading: Sendable {
    func load(_ request: URLRequest) throws -> HTTPResponse
}

public protocol JavaScriptRedirectNetworkLoading: JavaScriptNetworkLoading {
    func load(_ request: URLRequest, followRedirects: Bool) throws -> HTTPResponse
}

public final class SynchronousJavaScriptNetworkLoader: JavaScriptRedirectNetworkLoading, @unchecked Sendable {
    public init() {}

    public func load(_ request: URLRequest) throws -> HTTPResponse {
        try load(request, followRedirects: true)
    }

    public func load(_ original: URLRequest, followRedirects: Bool) throws -> HTTPResponse {
        let settings = ApplicationSettingsStore.shared.settings
        let request = settings.configure(original)
        let address = try ApplicationSettings.parseHosts(settings.hosts)[request.url?.host?.lowercased() ?? ""]
        if followRedirects || (settings.proxy.isEmpty && address != nil) {
            let semaphore = DispatchSemaphore(value: 0)
            let lock = NSLock()
            nonisolated(unsafe) var result: Result<HTTPResponse, Error>?
            // The synchronous JS caller waits for this request. Detached tasks
            // otherwise default to medium priority and cause priority inversion
            // during interactive search/source switching.
            let task = Task.detached(priority: Task.currentPriority) {
                let value: Result<HTTPResponse, Error>
                do {
                    let response: HTTPResponse
                    if followRedirects { response = try await URLSessionHTTPTransport.shared.data(for: request) }
                    else { response = try await HostsHTTPTransport.data(for: request, address: address!, ignoreCertificateErrors: settings.ignoreCertificateErrors) }
                    value = .success(response)
                } catch HTTPClientError.statusResponse(let response) { value = .success(response) }
                catch { value = .failure(error) }
                lock.withLock { result = value }
                semaphore.signal()
            }
            guard semaphore.wait(timeout: .now() + max(1, request.timeoutInterval) + 1) == .success else {
                task.cancel()
                throw URLError(.timedOut)
            }
            lock.lock(); let value = result; lock.unlock()
            return try value?.get() ?? { throw HTTPClientError.nonHTTPResponse }()
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        configuration.httpCookieStorage = .shared
        try settings.configure(configuration)
        let delegate: any URLSessionDelegate = followRedirects ? LegadoUnsafeTrustDelegate.shared : JavaScriptRedirectBlocker()
        let callbackQueue = OperationQueue()
        callbackQueue.qualityOfService = Thread.current.qualityOfService
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: callbackQueue)
        defer { session.finishTasksAndInvalidate() }
        let started = Date()
        do {
            let response = try load(request, session: session)
            DiagnosticLog.shared.network(request, status: response.statusCode, startedAt: started)
            return response
        } catch {
            DiagnosticLog.shared.network(request, error: error, startedAt: started)
            throw error
        }
    }

    private func load(_ request: URLRequest, session: URLSession) throws -> HTTPResponse {
        let semaphore = DispatchSemaphore(value: 0)
        let lock = NSLock()
        nonisolated(unsafe) var output: Result<HTTPResponse, Error>?
        let task = session.dataTask(with: request) { data, response, error in
            let result: Result<HTTPResponse, Error>
            if let error {
                result = .failure(error)
            } else if let http = response as? HTTPURLResponse, let url = http.url {
                result = .success(.init(
                    data: data ?? Data(),
                    statusCode: http.statusCode,
                    headers: http.allHeaderFields.reduce(into: [:]) { values, entry in
                        values[String(describing: entry.key)] = String(describing: entry.value)
                    },
                    finalURL: url
                ))
            } else {
                result = .failure(HTTPClientError.nonHTTPResponse)
            }
            lock.lock()
            output = result
            lock.unlock()
            semaphore.signal()
        }
        task.resume()
        let timeout = min(max(request.timeoutInterval, 1), 180)
        guard semaphore.wait(timeout: .now() + timeout + 1) == .success else {
            task.cancel()
            throw URLError(.timedOut)
        }
        lock.lock()
        let result = output
        lock.unlock()
        return try result?.get() ?? { throw HTTPClientError.nonHTTPResponse }()
    }
}

private final class JavaScriptRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        LegadoUnsafeTrustDelegate.resolution(for: challenge)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// 书源 JavaScript 的唯一执行入口。
///
/// 引擎为 vendored quickjs-ng（QJS 0.17.0），不再保留 JavaScriptCore、
/// 不提供双引擎、不做回退。资源约束全部交给引擎：
/// - 长度：UTF-8 字节数分别按规则 / jsLib / 返回值三项独立上限；
/// - 内存与栈：`JS_SetMemoryLimit` / `JS_SetMaxStackSize`，默认随 jsLib 体积联动；
/// - 时间：`JS_SetInterruptHandler` + 真实截止时间，不再用字符串黑名单预检。
public struct JavaScriptRuleEvaluator: Sendable {
    public var maximumRuleLength: Int
    public var maximumJSLibLength: Int
    public var maximumResultLength: Int
    public var timeoutMilliseconds: Int

    private let networkLoader: any JavaScriptNetworkLoading
    private let urlBuilder: LegadoURLBuilder

    public init(
        maximumRuleLength: Int = 1_048_576,
        maximumJSLibLength: Int = 4_194_304,
        maximumResultLength: Int = 2_097_152,
        timeoutMilliseconds: Int = 5_000,
        networkLoader: any JavaScriptNetworkLoading = SynchronousJavaScriptNetworkLoader(),
        urlBuilder: LegadoURLBuilder = .init()
    ) {
        self.maximumRuleLength = max(0, maximumRuleLength)
        self.maximumJSLibLength = max(0, maximumJSLibLength)
        self.maximumResultLength = max(0, maximumResultLength)
        self.timeoutMilliseconds = max(1, timeoutMilliseconds)
        self.networkLoader = networkLoader
        self.urlBuilder = urlBuilder
    }

    /// Top-level compatibility requests use the same URL/header/body hosts as nested JS calls.
    public func request(_ url: String, context: RuleExecutionContext) async throws -> HTTPResponse {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await RuleExecutionWorker.run {
                try loadJavaScriptRequest(url, extraHeaders: [:], timeoutMilliseconds: nil, executionContext: context)
            }
        } onCancel: { context.environment?.control.cancel() }
    }

    public func evaluateAsync(
        script: String,
        result: JSONValue,
        executionContext: RuleExecutionContext
    ) async throws -> JavaScriptRuleResult {
        try await withTaskCancellationHandler {
            try await RuleExecutionWorker.run {
                try executionContext.environment?.control.check()
                return try evaluate(script: script, result: result, executionContext: executionContext)
            }
        } onCancel: {
            executionContext.environment?.control.cancel()
        }
    }

    public func evaluate(
        script: String,
        result: JSONValue,
        executionContext: RuleExecutionContext
    ) throws -> JavaScriptRuleResult {
        try evaluate(
            script: script,
            result: result,
            executionContext: executionContext,
            stringifyResult: false,
            depth: 0
        )
    }

    private var limits: JavaScriptRuntimeLimits {
        JavaScriptRuntimeLimits(
            maximumRuleLength: maximumRuleLength,
            maximumJSLibLength: maximumJSLibLength,
            maximumResultLength: maximumResultLength,
            timeoutMilliseconds: timeoutMilliseconds
        )
    }

    /// 执行一段规则脚本，并把引擎异常统一映射成 `RuleEngineError`。
    ///
    /// 这层映射不是装饰：上游 `RuleEngine.evaluatePipeline`、`HTTPClient`、
    /// `ContentSanitizer` 都按 `RuleEngineError` 分派诊断码（`rule.resource_limit`
    /// / `rule.malformed` / `rule.invalid_input`）。引擎错误若原样抛出，
    /// 会落进通用 catch 变成 `rule.javascript`，书源侧就看不到
    /// 「规则过大 / 执行超时」，只剩一条含义模糊的失败。
    private func evaluate(
        script: String,
        result: JSONValue,
        executionContext: RuleExecutionContext,
        stringifyResult: Bool,
        depth: Int
    ) throws -> JavaScriptRuleResult {
        try executionContext.environment?.control.check()
        do {
            let result = try evaluateRaw(
                script: script,
                result: result,
                executionContext: executionContext,
                stringifyResult: stringifyResult,
                depth: depth
            )
            try executionContext.environment?.control.check()
            return result
        } catch {
            // A script may catch a host exception; cancellation still owns the final outcome.
            try executionContext.environment?.control.check()
            if let error = error as? JavaScriptRuntimeError {
                throw Self.ruleEngineError(error, script: script)
            }
            throw error
        }
    }

    /// 引擎异常 → 既有诊断类型。
    ///
    /// 资源类与语义类必须分开：前者提示「规则过大 / 超时」，后者提示
    /// 「书源规则有误」，二者在 UI、重试策略与日志聚合上的处理方式都不同。
    static func ruleEngineError(_ error: JavaScriptRuntimeError, script: String) -> RuleEngineError {
        let detail = error.errorDescription ?? "JavaScript 执行失败"
        switch error {
        case .ruleTooLong, .libraryTooLong, .resultTooLong,
             .memoryLimitExceeded, .executionTimedOut:
            return .resourceLimit(rule: script, detail: detail)
        case .syntaxError, .thrown, .hostCallFailed:
            return .malformedRule(rule: script, detail: detail)
        case .runtimeInitializationFailed, .contextInitializationFailed, .valueConversionFailed:
            return .invalidInput(rule: script, expected: detail)
        }
    }

    /// 真正的执行体。`depth` 只用于 `java.getString` 的嵌套求值，防止规则自引用爆栈。
    private func evaluateRaw(
        script: String,
        result: JSONValue,
        executionContext: RuleExecutionContext,
        stringifyResult: Bool,
        depth: Int
    ) throws -> JavaScriptRuleResult {
        let byteCount = script.utf8.count
        guard byteCount <= maximumRuleLength else {
            throw JavaScriptRuntimeError.ruleTooLong(limit: maximumRuleLength, actual: byteCount)
        }
        let limits = self.limits
        let runtime = try QuickJSRuntime(limits: limits, shouldInterrupt: {
            executionContext.environment?.control.shouldInterrupt ?? false
        })
        let variables = JavaScriptVariableBox(executionContext.variables)
        let context = try JavaScriptHostInstaller.makeContext(
            runtime: runtime,
            dependencies: dependencies(result: result, variables: variables, executionContext: executionContext, depth: depth)
        )
        if let library = executionContext.source?.jsLib {
            try JavaScriptHostInstaller.installLibrary(library, limits: limits, into: context)
        }

        // 先编译再执行：语法错误在这一步就能报行号，而不是执行到一半才失败。
        let compiled = try context.compile(script)
        defer { context.release(compiled) }
        let evaluated = try context.runCompiled(compiled)
        defer { context.release(evaluated) }

        let value: JSONValue
        if stringifyResult {
            value = .string(replacementText(for: evaluated, in: context))
        } else {
            value = context.jsonValue(from: evaluated)
        }

        let resultByteCount = value.stringValue.utf8.count
        guard resultByteCount <= maximumResultLength else {
            throw JavaScriptRuntimeError.resultTooLong(limit: maximumResultLength, actual: resultByteCount)
        }
        return .init(value: value, variables: variables.snapshot)
    }

    /// 替换表达式的返回值收敛规则（与 JSC 版逐字对齐）：
    /// `undefined` / `null` → `"null"`；有限数字 → `String(double)`；其余 → JS `toString()`。
    private func replacementText(for value: JSValue, in context: QuickJSContext) -> String {
        if qjs_is_undefined(value) || qjs_is_null(value) { return "null" }
        if qjs_is_number(value) {
            var ok = false
            let number = qjs_to_double(context.rawContext, value, &ok)
            if ok, number.isFinite { return String(number) }
        }
        return context.string(from: value) ?? "null"
    }

    private func dependencies(
        result: JSONValue,
        variables: JavaScriptVariableBox,
        executionContext: RuleExecutionContext,
        depth: Int
    ) -> JavaScriptHostInstaller.Dependencies {
        JavaScriptHostInstaller.Dependencies(
            result: result,
            variables: variables,
            executionContext: executionContext,
            byteLimit: maximumResultLength,
            loadAjax: { rawURL, extraHeaders, timeout in
                try loadJavaScriptRequest(
                    rawURL,
                    extraHeaders: extraHeaders,
                    timeoutMilliseconds: timeout,
                    executionContext: executionContext
                )
            },
            loadDirect: { method, rawURL, body, headers, timeout in
                try loadDirectJavaScriptRequest(
                    method: method,
                    rawURL: rawURL,
                    body: body,
                    headers: headers,
                    timeoutMilliseconds: timeout,
                    executionContext: executionContext
                )
            },
            evaluateStringRule: { rule, content, isURL in
                do {
                    return try evaluateStringRule(rule, content: content, isURL: isURL,
                        executionContext: executionContext, depth: depth + 1)
                } catch {
                    if executionContext.environment != nil { throw error }
                    return ""
                }
            },
            evaluateStringListRule: { rule, content, isURL in
                do {
                    return try evaluateStringRuleValues(rule, content: content, isURL: isURL,
                        executionContext: executionContext, depth: depth + 1)
                } catch {
                    if executionContext.environment != nil { throw error }
                    return []
                }
            }
        )
    }

    /// 一次替换规则的共享运行时。
    ///
    /// 语义与 JSC 版一致：多次匹配共享 `java.get/put` 存储，每次匹配各自拥有全新全局环境。
    ///
    /// 为什么不能「编译一次、多轮执行字节码」（原设计已废弃）：
    /// quickjs-ng 的 `JS_TAG_FUNCTION_BYTECODE` 绑定它**编译时所在的 realm**
    /// （`FunctionBytecode.realm` → 该 Context 的全局对象）。跨 Context 执行
    /// `JS_EvalFunction` 时，脚本读到的仍是编译期那个 realm 的全局名，
    /// 于是逐条 `ReferenceError: java is not defined` / `result is not defined`
    /// （CI：QuickJSRuntimeTests、ReplaceRuleExecutionTests 三条用例），
    /// 严重时还会因跨 realm 持有字节码在释放阶段崩溃（signal 11）。
    /// 所以编译与执行必须落在同一个 Context：每轮新建 Context（保住「全局环境全新」），
    /// 在该 Context 内注入宿主、求值 jsLib、再求值替换脚本。
    ///
    /// 代价如实记录：jsLib 每轮重新解析一次。这与 JSC 版行为一致
    /// （那边同样每轮 `evaluateScript(library)`），因此不是回归，
    /// 只是没能拿到原先设想的加速。
    final class ReplacementSession {
        private let runtime: QuickJSRuntime
        private let evaluator: JavaScriptRuleEvaluator
        private let script: String
        private var executionContext: RuleExecutionContext
        private let variables: JavaScriptVariableBox

        /// QuickJS 明确禁止同一个 Runtime 被多个线程并发操作。
        ///
        /// 这里跨多次调用共享同一个 Runtime，而替换净化在多本书同时刷新正文时
        /// 可能被并发触发，所以必须把每一轮渲染串行化。
        /// 锁范围覆盖「新建 Context → 注入宿主 → 求值 jsLib → 求值替换脚本」全过程：
        /// Context 的创建与求值本身都在操作同一个 Runtime。
        private let renderLock = NSLock()

        init(evaluator: JavaScriptRuleEvaluator, script: String, executionContext: RuleExecutionContext) throws {
            self.runtime = try QuickJSRuntime(limits: evaluator.limits, shouldInterrupt: {
                executionContext.environment?.control.shouldInterrupt ?? false
            })
            self.evaluator = evaluator
            self.script = script
            self.executionContext = executionContext
            self.variables = JavaScriptVariableBox(executionContext.variables)
        }

        func render(_ match: String) throws -> String {
            renderLock.lock()
            defer { renderLock.unlock() }
            let dependencies = evaluator.dependencies(
                result: .string(match),
                variables: variables,
                executionContext: executionContext,
                depth: 0
            )
            // jsLib 与替换脚本都在这个 Context 内求值：字节码绑定 realm，
            // 编译与执行分到两个 Context 就会读到错的全局（详见类型注释）。
            let context = try JavaScriptHostInstaller.makeContext(runtime: runtime, dependencies: dependencies)
            if let library = executionContext.source?.jsLib {
                try JavaScriptHostInstaller.installLibrary(library, limits: evaluator.limits, into: context)
            }
            let evaluated = try context.evaluate(script, filename: "legado-replacement.js")
            defer { context.release(evaluated) }
            let text = evaluator.replacementText(for: evaluated, in: context)
            executionContext.variables = variables.snapshot
            let byteCount = text.utf8.count
            guard byteCount <= evaluator.maximumResultLength else {
                throw JavaScriptRuntimeError.resultTooLong(limit: evaluator.maximumResultLength, actual: byteCount)
            }
            return text
        }
    }

    /// A rule shares java.get/put storage, but each match gets fresh JS globals.
    /// Keep this closure on the synchronous replacement call's thread.
    func replacementEvaluator(script: String, book: Book, chapter: BookChapter) -> (String) throws -> String {
        var session: ReplacementSession?
        var executionContext = RuleExecutionContext(book: book, chapter: chapter)
        return { match in
            let current: ReplacementSession
            if let session {
                current = session
            } else {
                let created = try ReplacementSession(
                    evaluator: self,
                    script: script,
                    executionContext: executionContext
                )
                session = created
                current = created
            }
            let text: String
            do {
                text = try autoreleasepool { try current.render(match) }
            } catch let error as JavaScriptRuntimeError {
                // 替换净化同样按 RuleEngineError 分派诊断，
                // 不能把引擎错误原样抛给 ContentSanitizer。
                throw Self.ruleEngineError(error, script: script)
            }
            executionContext.variables = current.variablesSnapshot
            return text
        }
    }

    // MARK: - 网络

    private func loadDirectJavaScriptRequest(
        method: String,
        rawURL: String,
        body: String?,
        headers: [String: String],
        timeoutMilliseconds: Double?,
        executionContext: RuleExecutionContext
    ) throws -> HTTPResponse {
        try executionContext.environment?.control.check()
        let baseText = executionContext.baseURL.isEmpty
            ? executionContext.source?.bookSourceUrl ?? ""
            : executionContext.baseURL
        let baseURL = URL(string: baseText)
        guard let url = URL(string: rawURL, relativeTo: baseURL)?.absoluteURL,
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            throw RuleEngineError.invalidInput(rule: rawURL, expected: "java.get/head/post URL")
        }
        let milliseconds = timeoutMilliseconds ?? 30_000
        var request = URLRequest(url: url, timeoutInterval: min(max(milliseconds / 1_000, 1), 180))
        request.httpMethod = method.uppercased()
        request.httpShouldHandleCookies = executionContext.environment == nil && executionContext.source?.enabledCookieJar != false
        var requestHeaders = try executionContext.source.map { try BookSourceHeaderResolver().resolve($0, environment: executionContext.environment) } ?? [:]
        requestHeaders.merge(headers) { _, explicit in explicit }
        if !requestHeaders.keys.contains(where: { $0.caseInsensitiveCompare("User-Agent") == .orderedSame }) {
            requestHeaders["User-Agent"] = executionContext.hostEnvironment.userAgent
        }
        requestHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        if method.caseInsensitiveCompare("POST") == .orderedSame {
            request.httpBody = Data((body ?? "").utf8)
        }
        if executionContext.source?.enabledCookieJar != false, executionContext.environment?.networkHandlesCookies != true {
            let stored = try executionContext.hostEnvironment.cookies.cookieHeader(for: url.absoluteString)
            let explicit = request.value(forHTTPHeaderField: "Cookie") ?? ""
            let merged = Self.mergeCookieHeaders(stored, explicit)
            if !merged.isEmpty { request.setValue(merged, forHTTPHeaderField: "Cookie") }
        }
        try executionContext.environment?.control.check()
        let response: HTTPResponse
        let loader = executionContext.environment?.network ?? networkLoader
        try executionContext.environment?.control.consumeRequest()
        if let redirectLoader = loader as? any JavaScriptRedirectNetworkLoading {
            response = try redirectLoader.load(request, followRedirects: false)
        } else {
            response = try loader.load(request)
        }
        try executionContext.environment?.control.check()
        if executionContext.environment?.networkHandlesCookies != true, let cookie = response.headers.first(where: { $0.key.caseInsensitiveCompare("Set-Cookie") == .orderedSame })?.value {
            try executionContext.hostEnvironment.cookies.setCookie(cookie, for: response.finalURL.absoluteString)
        }
        return response
    }

    private func loadJavaScriptRequest(
        _ rawURL: String,
        extraHeaders: [String: String],
        timeoutMilliseconds: Double?,
        executionContext: RuleExecutionContext
    ) throws -> HTTPResponse {
        guard !rawURL.isEmpty else {
            throw RuleEngineError.invalidInput(rule: rawURL, expected: "java.ajax/connect URL")
        }
        try executionContext.environment?.control.check()
        let source = executionContext.source
        var headers = try source.map { try BookSourceHeaderResolver().resolve($0, environment: executionContext.environment) } ?? [:]
        headers.merge(extraHeaders) { _, extra in extra }
        let base = URL(string: executionContext.baseURL.isEmpty ? source?.bookSourceUrl ?? "" : executionContext.baseURL)
        let prepared = try urlBuilder.prepare(rawURL, context: .init(
            key: executionContext.key, page: executionContext.page,
            variables: executionContext.variables, source: source, book: executionContext.book,
            chapter: executionContext.chapter, environment: executionContext.environment
        ), baseURL: base, defaultHeaders: headers)
        if prepared.useWebView || prepared.webJavaScript != nil {
            throw RuleEngineError.unsupportedRule(rule: rawURL, feature: "JS 内 WKWebView 请求")
        }
        if executionContext.environment != nil, prepared.proxy != nil || prepared.dnsIP != nil || prepared.serverID != nil {
            throw RuleEngineError.unsupportedRule(rule: rawURL, feature: "Source-specific proxy, DNS or server overrides")
        }
        var responseContext = executionContext
        responseContext.variables.merge(prepared.variables) { _, new in new }
        let timeout = timeoutMilliseconds.map { min(max($0 / 1_000, 1), 180) }
            ?? min(max(Double(source?.respondTime ?? 30_000) / 1_000, 5), 180)
        var request = prepared.urlRequest(timeout: timeout,
            handleCookies: executionContext.environment == nil && source?.enabledCookieJar != false,
            useApplicationTimeout: executionContext.environment == nil)
        if source?.enabledCookieJar != false, executionContext.environment?.networkHandlesCookies != true {
            let stored = try executionContext.hostEnvironment.cookies.cookieHeader(for: prepared.url.absoluteString)
            let explicit = request.value(forHTTPHeaderField: "Cookie") ?? ""
            let merged = Self.mergeCookieHeaders(stored, explicit)
            if !merged.isEmpty { request.setValue(merged, forHTTPHeaderField: "Cookie") }
        }
        let loader = executionContext.environment?.network ?? networkLoader
        let retryCount = max(prepared.retry, 0)
        let attempts = retryCount == Int.max ? Int.max : retryCount + 1
        var lastError: Error = HTTPClientError.nonHTTPResponse
        for attempt in 0..<attempts {
            do {
                try executionContext.environment?.control.check()
                try executionContext.environment?.control.consumeRequest()
                var response = try loader.load(request)
                try executionContext.environment?.control.check()
                response.requestedCharset = prepared.charset
                response.requestVariables = responseContext.variables
                if executionContext.environment?.networkHandlesCookies != true, let cookie = response.headers.first(where: { $0.key.caseInsensitiveCompare("Set-Cookie") == .orderedSame })?.value {
                    try executionContext.hostEnvironment.cookies.setCookie(cookie, for: response.finalURL.absoluteString)
                }
                guard (200 ... 299).contains(response.statusCode) else {
                    throw HTTPClientError.statusResponse(response)
                }
                if prepared.responseType != nil {
                    response.data = Data(response.data.map { String(format: "%02x", $0) }.joined().utf8)
                    response.requestedCharset = "utf-8"
                } else if let bodyScript = prepared.bodyJavaScript {
                    let transformed = try evaluate(
                        script: bodyScript,
                        result: .string(response.decodedText),
                        executionContext: responseContext,
                        stringifyResult: true,
                        depth: 0
                    )
                    response.data = Data(transformed.value.stringValue.utf8)
                    response.requestedCharset = "utf-8"
                    response.requestVariables = transformed.variables
                }
                return response
            } catch {
                lastError = error
                guard case HTTPClientError.statusResponse = error, attempt + 1 < attempts else {
                    throw error
                }
            }
        }
        throw lastError
    }

    // MARK: - java.getString 的二次求值

    /// `java.getString(rule, content, isUrl)` 回到 Swift 侧再走一遍规则解析。
    ///
    /// 这条路径会递归进 `@js` 分支，因此在 `depth` 上设 8 层上限：
    /// 规则里出现自引用（`java.getString('@js:...')` 套自身）时，原来的实现是直接爆栈崩溃，
    /// 现在会抛 `resourceLimit` 并落进诊断，书源侧能看到一条明确错误。
    private func evaluateStringRule(
        _ rule: String,
        content: JSONValue?,
        isURL: Bool,
        executionContext: RuleExecutionContext,
        depth: Int
    ) throws -> String {
        try evaluateStringRuleValues(
            rule,
            content: content,
            isURL: isURL,
            executionContext: executionContext,
            depth: depth
        ).joined(separator: "\n")
    }

    /// 列表模式求值：不拼接，按命中顺序返回。
    ///
    /// `java.getStringList` 只能走这条路径，不能对 `java.getString` 的结果切分：
    /// 正文与简介里本来就有换行，切分会把一条内容拆成多条；而多个命中之间
    /// 也没有天然分隔符可以还原边界。
    private func evaluateStringRuleValues(
        _ rule: String,
        content: JSONValue?,
        isURL: Bool,
        executionContext: RuleExecutionContext,
        depth: Int
    ) throws -> [String] {
        guard depth <= 8 else {
            throw RuleEngineError.resourceLimit(rule: rule, detail: "java.getString 嵌套层数超过上限")
        }
        let trimmedRule = rule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRule.isEmpty else { return [] }

        let input = content ?? executionContext.content ?? .null

        if case .object(let object) = input,
           let direct = object[trimmedRule] {
            return [resolveJavaScriptRuleURL(direct.stringValue, enabled: isURL, context: executionContext)]
        }

        let jsonContent: JSONValue?
        if case .string(let text) = input { jsonContent = try? JSONValue.decode(data: Data(text.utf8)) }
        else { jsonContent = input }
        let plan = try RuleExpressionParser().parse(trimmedRule, inputLooksLikeJSON: jsonContent != nil)
        var branchResults: [[String]] = []
        for branch in plan.branches {
            var values: [String]
            if branch.expression.isEmpty {
                values = [input.stringValue]
            } else {
                switch branch.mode {
                case .css:
                    values = try HTMLRuleEvaluator().extractCSS(
                        branch.expression,
                        html: input.stringValue,
                        baseURL: executionContext.baseURL,
                        isFragment: executionContext.isHTMLFragment
                    )
                case .xpath:
                    values = try HTMLRuleEvaluator().extractXPath(
                        branch.expression,
                        html: input.stringValue,
                        isFragment: executionContext.isHTMLFragment
                    )
                case .jsonPath:
                    let json: JSONValue
                    if case .string(let text) = input {
                        json = try JSONValue.decode(data: Data(text.utf8))
                    } else {
                        json = input
                    }
                    values = RuleEvaluation(values: try JSONPathEvaluator().evaluateRule(branch.expression, in: json)).strings
                case .regex:
                    values = try RegexEvaluator().captureGroups(pattern: branch.expression, input: input.stringValue)
                        .map { $0.count > 1 ? $0.dropFirst().joined() : $0.first ?? "" }
                case .javaScript:
                    // 列表模式下 `@js` 常写成 `result.map(x => ...)`，返回的是**数组**。
                    // 只取 value.stringValue 会把整组结果压成一条，`java.getStringList`
                    // 刚接上的真列表求值就在这个入口又退化成单值。数组按元素展开，
                    // 其余类型保持原有单值语义。
                    let evaluated = try evaluate(
                        script: branch.expression,
                        result: input,
                        executionContext: executionContext,
                        stringifyResult: false,
                        depth: depth
                    ).value
                    if case .array(let items) = evaluated {
                        values = items.map(\.stringValue)
                    } else {
                        values = [evaluated.stringValue]
                    }
                case .webJavaScript:
                    throw RuleEngineError.unsupportedRule(rule: branch.expression, feature: "java.getString WebView JavaScript")
                }
            }
            if plan.combination == .fallback, values.joined(separator: "\n").isEmpty { values = [] }
            branchResults.append(values)
            if plan.combination == .fallback, !values.isEmpty { break }
        }

        let combined: [String]
        switch plan.combination {
        case .single, .concatenate:
            combined = branchResults.flatMap { $0 }
        case .fallback:
            combined = branchResults.first(where: { !$0.isEmpty }) ?? []
        case .interleave:
            // 列表模式下没有「首个分支」时返回空列表，不能再返回空串：
            // 函数返回类型已改为 [String]，返回字符串在这里是编译错误。
            guard let firstCount = branchResults.first?.count else { return [] }
            combined = (0..<firstCount).flatMap { index in
                branchResults.compactMap { $0.indices.contains(index) ? $0[index] : nil }
            }
        }
        var values = combined
        if let branch = plan.branches.first, let pattern = branch.replacePattern, !pattern.isEmpty {
            values = try values.map {
                try RegexEvaluator().replacing(
                    pattern: pattern,
                    in: $0,
                    with: branch.replacement,
                    firstOnly: branch.replaceFirst
                )
            }
        }
        return values.map { resolveJavaScriptRuleURL($0, enabled: isURL, context: executionContext) }
    }

    private func resolveJavaScriptRuleURL(
        _ value: String,
        enabled: Bool,
        context: RuleExecutionContext
    ) -> String {
        guard enabled else { return value }
        let baseText = context.baseURL.isEmpty ? context.source?.bookSourceUrl ?? "" : context.baseURL
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return baseText }
        guard let baseURL = URL(string: baseText),
              let absolute = URL(string: value, relativeTo: baseURL)?.absoluteURL else { return value }
        return absolute.absoluteString
    }

    private static func mergeCookieHeaders(_ stored: String, _ explicit: String) -> String {
        var order: [String] = []
        var values: [String: String] = [:]
        for header in [stored, explicit] {
            for part in header.split(separator: ";") {
                let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
                guard pair.count == 2 else { continue }
                let name = pair[0].trimmingCharacters(in: .whitespaces)
                if values[name] == nil { order.append(name) }
                values[name] = pair[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return order.compactMap { name in values[name].map { "\(name)=\($0)" } }.joined(separator: "; ")
    }
}

extension JavaScriptRuleEvaluator.ReplacementSession {
    var variablesSnapshot: [String: String] { variables.snapshot }
}
