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
    private var callbacks: [UUID: @Sendable (any Error) -> Void] = [:]
    private var remainingRequests: Int
    public let commitGate: SourceCommitGate
    public let deadline: ContinuousClock.Instant

    public init(timeout: Duration = .seconds(30), maximumRequests: Int = 64, gate: SourceCommitGate? = nil) {
        remainingRequests = max(0, maximumRequests)
        commitGate = SourceCommitGate(parent: gate)
        deadline = ContinuousClock.now.advanced(by: timeout)
    }

    public func check() throws {
        do {
            try lock.withLock { if let failure { throw failure } }
            if ContinuousClock.now >= deadline { throw URLError(.timedOut) }
            try commitGate.check()
        } catch { invalidate(error); throw error }
    }

    public func consumeRequest() throws {
        try check()
        try lock.withLock {
            guard remainingRequests > 0 else {
                throw SourceDomainError(.resourceLimit, "Compatibility request budget exceeded")
            }
            remainingRequests -= 1
        }
    }

    public func cancel() { invalidate(CancellationError()) }

    public func invalidate(_ error: any Error) {
        let pending: [@Sendable (any Error) -> Void] = lock.withLock {
            guard failure == nil else { return [] }
            failure = error
            let pending = Array(callbacks.values)
            callbacks.removeAll()
            return pending
        }
        commitGate.invalidate()
        // Never call back into a task while holding the control lock.
        for callback in pending { callback(error) }
    }

    func onTermination(_ callback: @escaping @Sendable (any Error) -> Void) -> UUID {
        let token = UUID()
        let terminal: (any Error)? = lock.withLock {
            if let failure { return failure }
            callbacks[token] = callback
            return nil
        }
        if let terminal { callback(terminal) }
        return token
    }
    func removeObserver(_ token: UUID) { _ = lock.withLock { callbacks.removeValue(forKey: token) } }

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
