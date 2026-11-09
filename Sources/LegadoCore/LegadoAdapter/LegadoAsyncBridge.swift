import Foundation

/// Only used on RuleExecutionWorker's dispatch threads, never a Swift cooperative executor.
/// The terminal result is chosen once; a late task cannot overwrite cancellation.
enum LegadoAsyncBridge {
    private final class Reply<Value: Sendable>: @unchecked Sendable {
        let ready = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var result: Result<Value, any Error>?
        func finish(_ value: Result<Value, any Error>) {
            let first = lock.withLock {
                guard result == nil else { return false }
                result = value; return true
            }
            if first { ready.signal() }
        }
        func value() throws -> Value {
            try lock.withLock {
                guard let result else { throw URLError(.unknown) }
                return try result.get()
            }
        }
    }

    static func wait<Value: Sendable>(control: JavaScriptExecutionControl,
                                      operation: @escaping @Sendable () async throws -> Value) throws -> Value {
        try control.check()
        let reply = Reply<Value>()
        let task = Task.detached(priority: Task.currentPriority) {
            do { reply.finish(.success(try await operation())) }
            catch { reply.finish(.failure(error)) }
        }
        let token = control.onTermination { error in task.cancel(); reply.finish(.failure(error)) }
        defer { control.removeObserver(token) }
        // The bounded wait also observes a revoked parent gate when no network callback arrives.
        while reply.ready.wait(timeout: .now() + 0.025) != .success {
            do { try control.check() }
            catch { task.cancel(); throw error }
        }
        try control.check()
        return try reply.value()
    }
}

/// The closure must use the host's scoped HTTP client. Synchronous legacy calls do not own a session.
public struct LegadoAsyncNetworkLoader: JavaScriptRedirectNetworkLoading {
    public typealias Fetch = @Sendable (URLRequest, Bool) async throws -> HTTPResponse
    private let control: JavaScriptExecutionControl
    private let fetch: Fetch
    public init(control: JavaScriptExecutionControl, fetch: @escaping Fetch) {
        self.control = control; self.fetch = fetch
    }
    public func load(_ request: URLRequest) throws -> HTTPResponse { try load(request, followRedirects: true) }
    public func load(_ request: URLRequest, followRedirects: Bool) throws -> HTTPResponse {
        try LegadoAsyncBridge.wait(control: control) { try await fetch(request, followRedirects) }
    }
}
