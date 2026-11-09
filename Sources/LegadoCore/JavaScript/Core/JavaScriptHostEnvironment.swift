import Foundation

/// The compatibility bridge receives all process-external state from its host.
/// A native provider must supply one environment pinned to its installation/account.
public protocol JavaScriptSourceState: Sendable {
    func get(sourceID: String, key: String) throws -> String
    func put(sourceID: String, key: String, value: String) throws
    func loginHeaders(sourceID: String) throws -> [String: String]
}

public protocol JavaScriptCookieState: Sendable {
    func cookieHeader(for value: String) throws -> String
    func cookie(for value: String, key: String) throws -> String
    func setCookie(_ cookie: String, for value: String) throws
    func removeCookies(for value: String) throws
}

extension BookSourceRuntimeStore: JavaScriptSourceState {}
extension LegadoCookieStore: JavaScriptCookieState {}

/// Shared by nested VMs and synchronous host calls for one native operation.
/// Cancellation is terminal; callers create a new control for the next operation.
public final class JavaScriptExecutionControl: @unchecked Sendable {
    private let lock = NSLock()
    private var failure: (any Error)?
    public let deadline: ContinuousClock.Instant

    public init(timeout: Duration = .seconds(30)) {
        deadline = ContinuousClock.now.advanced(by: timeout)
    }

    public func check() throws {
        try lock.withLock {
            if let failure { throw failure }
            if ContinuousClock.now >= deadline { throw URLError(.timedOut) }
        }
    }

    public func cancel() { invalidate(CancellationError()) }

    public func invalidate(_ error: any Error) {
        lock.withLock { if failure == nil { failure = error } }
    }

    public var shouldInterrupt: Bool {
        do { try check(); return false } catch { return true }
    }
}

public struct JavaScriptHostEnvironment: Sendable {
    public let control: JavaScriptExecutionControl
    public let sourceState: any JavaScriptSourceState
    public let cookies: any JavaScriptCookieState
    public let network: any JavaScriptNetworkLoading
    public let userAgent: String
    public let identifier: @Sendable () throws -> String
    public let record: @Sendable (String) -> Void
    public let renderWebPage: @Sendable (String) throws -> String
    public let openBrowser: @Sendable (String) throws -> String

    public init(sourceState: any JavaScriptSourceState, cookies: any JavaScriptCookieState,
                control: JavaScriptExecutionControl = .init(),
                network: any JavaScriptNetworkLoading, userAgent: String,
                identifier: @escaping @Sendable () throws -> String,
                record: @escaping @Sendable (String) -> Void = { _ in },
                renderWebPage: @escaping @Sendable (String) throws -> String = { _ in
                    throw RuleEngineError.unsupportedRule(rule: "java.webView", feature: "Synchronous WebView rendering")
                },
                openBrowser: @escaping @Sendable (String) throws -> String = { _ in
                    throw RuleEngineError.unsupportedRule(rule: "java.startBrowser", feature: "Browser UI requires host interaction")
                }) {
        self.control = control
        self.sourceState = sourceState; self.cookies = cookies; self.network = network
        self.userAgent = userAgent; self.identifier = identifier; self.record = record
        self.renderWebPage = renderWebPage; self.openBrowser = openBrowser
    }

    /// Existing application entry points keep their persisted stores until migration.
    /// The independent provider must never construct its environment from this value.
    static var legacy: Self {
        .init(sourceState: BookSourceRuntimeStore.shared, cookies: LegadoCookieStore.shared,
              network: SynchronousJavaScriptNetworkLoader(),
              userAgent: ApplicationSettingsStore.shared.settings.effectiveUserAgent,
              identifier: {
                  let key = "ios.installation.identifier"
                  let stored = BookSourceRuntimeStore.shared.get(sourceID: "__app__", key: key)
                  if !stored.isEmpty { return stored }
                  let value = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
                  BookSourceRuntimeStore.shared.put(sourceID: "__app__", key: key, value: value)
                  return value
              }, record: { DiagnosticLog.shared.record(category: "JS", message: $0) },
              renderWebPage: {
                  DiagnosticLog.shared.record(category: "JS", message: "java.webView 未执行真实 WebView 渲染（同步宿主限制），已回退为原始 HTML")
                  return $0
              }, openBrowser: {
                  DiagnosticLog.shared.record(category: "JS", message: "java.startBrowser: \($0)")
                  return $0
              })
    }
}
