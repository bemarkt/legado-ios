import Foundation

public struct SourceHostHTTPRequest: Decodable, Sendable {
    public let url: String
    public let method: String
    public let headers: [String: String]
    public let body: String?
    public let redirect: String
    public init(url: String, method: String = "GET", headers: [String: String] = [:], body: String? = nil, redirect: String = "follow") {
        self.url = url; self.method = method; self.headers = headers; self.body = body; self.redirect = redirect
    }
}

public struct SourceHostHTTPResponse: Encodable, Sendable {
    public let status: Int
    public let url: String
    public let headers: [String: String]
    public let body: String
}

public struct SourceHostHTTPFailure: Error, LocalizedError, Sendable, Equatable {
    public enum Code: String, Sendable {
        case invalidInput = "INVALID_INPUT", permissionDenied = "PERMISSION_DENIED", resourceLimit = "RESOURCE_LIMIT"
        case network = "NETWORK", timeout = "TIMEOUT", cancelled = "CANCELLED", stale = "STALE_SNAPSHOT"
    }
    public let code: Code
    public let message: String
    public var errorDescription: String? { message }
    init(_ code: Code, _ message: String) { self.code = code; self.message = message }
}

/// One operation shares this budget across JS fetch calls, redirects, and retries.
public actor SourceHTTPRequestBudget {
    private var remaining: Int
    public init(maximumRequests: Int) { remaining = max(0, maximumRequests) }
    public func consume() throws {
        try Task.checkCancellation()
        guard remaining > 0 else { throw SourceHostHTTPFailure(.resourceLimit, "Operation HTTP attempt budget exceeded") }
        remaining -= 1
    }
}

public struct SourceHostHTTPPolicy: Sendable {
    public let origins: Set<String>
    public let allowLoopbackHTTP: Bool
    public let maximumBytes: Int
    public let maximumRedirects: Int
    public let timeout: TimeInterval
    public let maximumAttempts: Int
    public let maximumRetryDelay: TimeInterval
    public init(origins: Set<String>, allowLoopbackHTTP: Bool = false, maximumBytes: Int = 8_388_608,
                maximumRedirects: Int = 5, timeout: TimeInterval = 15, maximumAttempts: Int = 2, maximumRetryDelay: TimeInterval = 2) {
        self.origins = origins; self.allowLoopbackHTTP = allowLoopbackHTTP; self.maximumBytes = maximumBytes
        self.maximumRedirects = maximumRedirects; self.timeout = timeout
        self.maximumAttempts = maximumAttempts; self.maximumRetryDelay = maximumRetryDelay
    }
    public static func origin(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
        let port = url.port
        let suffix = port == nil || (scheme == "https" && port == 443) || (scheme == "http" && port == 80) ? "" : ":\(port!)"
        return "\(scheme)://\(host)\(suffix)"
    }
    public func validate(_ string: String) throws -> URL {
        guard string.utf8.count <= 8192, string == string.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: string), let origin = Self.origin(url),
              url.user == nil, url.password == nil, origins.contains(origin),
              url.scheme == "https" || (allowLoopbackHTTP && url.scheme == "http" && ["127.0.0.1", "localhost", "[::1]"].contains(url.host ?? "")) else {
            throw SourceHostHTTPFailure(.permissionDenied, "URL is outside the authorized HTTP policy")
        }
        return url
    }
}

/// Redirects are returned to the host, so each hop releases its old permit before acquiring the new one.
private final class SourceNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

/// Host-owned authorization; native modules never receive the credential lease itself.
public protocol SourceHTTPAuthorization: Sendable {
    func headers(for url: URL) async throws -> [String: String]
    func receive(_ cookies: [SourceCredentialCookie]) async throws
}
extension SourceCredentialSession: SourceHTTPAuthorization {}

public struct SourceHostHTTPClient: Sendable {
    private struct Reply: Sendable {
        let status: Int
        let url: URL
        let headers: [String: String]
        let data: Data
        let cookies: [SourceCredentialCookie]
    }
    private let scheduler: SourceWorkScheduler
    public init(scheduler: SourceWorkScheduler = .init(globalLimit: 4, perOriginLimit: 2)) { self.scheduler = scheduler }

    public func fetch(_ input: SourceHostHTTPRequest, policy: SourceHostHTTPPolicy,
                      priority: SourceWorkScheduler.Priority = .reading, deadline operationDeadline: ContinuousClock.Instant? = nil,
                      budget: SourceHTTPRequestBudget? = nil, credentials: SourceCredentialSession? = nil) async throws -> SourceHostHTTPResponse {
        try await execute(input, policy: policy, priority: priority, deadline: operationDeadline, budget: budget, credentials: credentials)
    }

    /// Legacy host requests share the same policy, scheduler, redirect loop and byte limits.
    /// Explicit Cookie headers are restricted to the initiating origin; native fetch still rejects them.
    public func fetchCompatibility(_ request: URLRequest, followRedirects: Bool, policy: SourceHostHTTPPolicy, priority: SourceWorkScheduler.Priority = .reading,
                                   deadline: ContinuousClock.Instant, budget: SourceHTTPRequestBudget,
                                   credentials: any SourceHTTPAuthorization) async throws -> HTTPResponse {
        guard let url = request.url, request.httpBodyStream == nil else { throw SourceHostHTTPFailure(.invalidInput, "Invalid compatibility request") }
        var headers = request.allHTTPHeaderFields ?? [:]
        let cookieName = headers.keys.first { $0.lowercased() == "cookie" }
        let cookie = cookieName.flatMap { headers.removeValue(forKey: $0) }
        if let cookie {
            guard cookie.utf8.count <= 8192, cookie.utf8.allSatisfy({ $0 >= 32 && $0 < 127 }) else {
                throw SourceHostHTTPFailure(.invalidInput, "Invalid compatibility Cookie header")
            }
        }
        let result = try await execute(.init(url: url.absoluteString, method: request.httpMethod ?? "GET", headers: headers,
                                             body: request.httpBody?.base64EncodedString()),
            policy: policy, priority: priority, deadline: deadline, budget: budget, credentials: credentials,
            compatibility: true, cookie: cookie, returnRedirect: !followRedirects)
        guard let finalURL = URL(string: result.url), let data = Data(base64Encoded: result.body) else {
            throw SourceHostHTTPFailure(.network, "Invalid host response")
        }
        return .init(data: data, statusCode: result.status, headers: result.headers, finalURL: finalURL)
    }

    private func execute(_ input: SourceHostHTTPRequest, policy: SourceHostHTTPPolicy,
                         priority: SourceWorkScheduler.Priority, deadline operationDeadline: ContinuousClock.Instant?,
                         budget: SourceHTTPRequestBudget?, credentials: (any SourceHTTPAuthorization)?,
                         compatibility: Bool = false, cookie: String? = nil, returnRedirect: Bool = false) async throws -> SourceHostHTTPResponse {
        do {
            guard policy.timeout.isFinite, policy.timeout > 0, policy.timeout <= 300,
                  (0...20).contains(policy.maximumRedirects), (1...3).contains(policy.maximumAttempts),
                  policy.maximumBytes > 0, policy.maximumBytes <= 8_388_608,
                  policy.maximumRetryDelay.isFinite, (0...30).contains(policy.maximumRetryDelay) else {
                throw SourceHostHTTPFailure(.invalidInput, "Invalid HTTP policy budget")
            }
            var request = try makeRequest(input, policy: policy)
            let initialOrigin = SourceHostHTTPPolicy.origin(request.url!)
            let timeout = ContinuousClock.now.advanced(by: .seconds(policy.timeout))
            let deadline = operationDeadline.map { min($0, timeout) } ?? timeout
            let retryable = ["GET", "HEAD"].contains(input.method)
            var redirects = 0, retries = 0
            var visited: Set<String> = [request.httpMethod! + " " + request.url!.absoluteString]
            while true {
                try Self.check(deadline)
                let hop = request
                let reply: Reply
                do {
                    reply = try await scheduler.withPermit(origin: SourceHostHTTPPolicy.origin(hop.url!)!, priority: priority, deadline: deadline) {
                        try Self.check(deadline)
                        var authorized = hop
                        if let credentials {
                            for (name, value) in try await credentials.headers(for: hop.url!) { authorized.setValue(value, forHTTPHeaderField: name) }
                        }
                        if let cookie, SourceHostHTTPPolicy.origin(hop.url!) == initialOrigin {
                            let explicit = cookie.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
                            let names = Set(explicit.map { $0.split(separator: "=", maxSplits: 1).first.map(String.init) ?? "" })
                            let stored = (authorized.value(forHTTPHeaderField: "Cookie") ?? "").split(separator: ";")
                                .map { $0.trimmingCharacters(in: .whitespaces) }
                                .filter { !names.contains($0.split(separator: "=", maxSplits: 1).first.map(String.init) ?? "") }
                            let merged = (stored + explicit).filter { !$0.isEmpty }.joined(separator: "; ")
                            guard merged.utf8.count <= 16_384 else { throw SourceHostHTTPFailure(.resourceLimit, "Cookie header exceeds byte budget") }
                            authorized.setValue(merged, forHTTPHeaderField: "Cookie")
                        }
                        try Self.check(deadline)
                        try await budget?.consume()
                        return try await Self.perform(authorized, policy: policy, deadline: deadline, captureCookies: credentials != nil, exposeCookies: compatibility, returnRedirect: returnRedirect)
                    }
                } catch let error as URLError where retryable && retries + 1 < policy.maximumAttempts && error.code == .networkConnectionLost {
                    try Self.check(deadline)
                    guard let delay = Self.retryDelay(header: nil, maximumDelay: policy.maximumRetryDelay, remaining: Self.remaining(deadline)) else { throw error }
                    retries += 1
                    try await Self.wait(delay, deadline: deadline)
                    continue
                }
                try Self.check(deadline)
                try await credentials?.receive(reply.cookies)
                if !returnRedirect, [301,302,303,307,308].contains(reply.status), let location = reply.headers["location"] {
                    guard input.redirect == "follow" else { throw SourceHostHTTPFailure(.network, "Redirect rejected by request policy") }
                    guard redirects < policy.maximumRedirects else { throw SourceHostHTTPFailure(.resourceLimit, "Redirect budget exceeded") }
                    guard let url = URL(string: location, relativeTo: reply.url)?.absoluteURL else { throw SourceHostHTTPFailure(.network, "Invalid redirect URL") }
                    let validated = try policy.validate(url.absoluteString)
                    var next = request
                    next.url = validated
                    if SourceHostHTTPPolicy.origin(reply.url) != SourceHostHTTPPolicy.origin(validated) {
                        for name in (next.allHTTPHeaderFields ?? [:]).keys where !["accept", "accept-language", "content-type"].contains(name.lowercased()) {
                            next.setValue(nil, forHTTPHeaderField: name)
                        }
                    }
                    if reply.status == 303 && next.httpMethod != "HEAD" || ([301,302].contains(reply.status) && next.httpMethod == "POST") {
                        next.httpMethod = "GET"; next.httpBody = nil
                        next.setValue(nil, forHTTPHeaderField: "Content-Type")
                        next.setValue(nil, forHTTPHeaderField: "Content-Length")
                    }
                    let key = next.httpMethod! + " " + validated.absoluteString
                    guard visited.insert(key).inserted else { throw SourceHostHTTPFailure(.resourceLimit, "Redirect loop detected") }
                    redirects += 1; request = next
                    continue
                }
                if retryable, [429,503].contains(reply.status), retries + 1 < policy.maximumAttempts,
                   let delay = Self.retryDelay(header: reply.headers["retry-after"], maximumDelay: policy.maximumRetryDelay, remaining: Self.remaining(deadline)) {
                    retries += 1
                    try await Self.wait(delay, deadline: deadline)
                    continue
                }
                return SourceHostHTTPResponse(status: reply.status, url: reply.url.absoluteString, headers: reply.headers, body: reply.data.base64EncodedString())
            }
        } catch let failure as SourceHostHTTPFailure { throw failure }
        catch let failure as SourceDomainError {
            let code: SourceHostHTTPFailure.Code = failure.code == .stale ? .stale : failure.code == .timeout ? .timeout : failure.code == .resourceLimit ? .resourceLimit : .network
            throw SourceHostHTTPFailure(code, failure.message)
        }
        catch {
            if Task.isCancelled || error is CancellationError { throw SourceHostHTTPFailure(.cancelled, "HTTP request cancelled") }
            if (error as? URLError)?.code == .timedOut { throw SourceHostHTTPFailure(.timeout, "HTTP deadline exceeded") }
            throw SourceHostHTTPFailure(.network, "HTTP transport failed")
        }
    }

    private func makeRequest(_ input: SourceHostHTTPRequest, policy: SourceHostHTTPPolicy) throws -> URLRequest {
        let url = try policy.validate(input.url)
        guard ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE"].contains(input.method),
              ["follow", "error"].contains(input.redirect), !( ["GET", "HEAD"].contains(input.method) && input.body != nil), input.headers.count <= 64 else {
            throw SourceHostHTTPFailure(.invalidInput, "Invalid HTTP method, body or headers")
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: policy.timeout)
        request.httpMethod = input.method; request.httpShouldHandleCookies = false
        let forbidden = Set(["host", "content-length", "cookie", "cookie2", "connection", "transfer-encoding", "upgrade", "proxy-authorization", "proxy-connection", "te", "trailer", "accept-encoding"])
        var names = Set<String>()
        for (name, value) in input.headers {
            let key = name.lowercased()
            guard name.range(of: "^[!#$%&'*+.^_`|~0-9A-Za-z-]+$", options: .regularExpression) != nil,
                  !forbidden.contains(key), !key.hasPrefix("sec-"), names.insert(key).inserted,
                  value.utf8.count <= 8192, !value.contains("\r"), !value.contains("\n"), !value.contains("\0") else {
                throw SourceHostHTTPFailure(.invalidInput, "Invalid or host-owned HTTP header")
            }
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let body = input.body {
            guard body.utf8.count <= 2_796_204, let data = Data(base64Encoded: body), data.count <= 2_097_152 else {
                throw SourceHostHTTPFailure(.resourceLimit, "HTTP request body exceeds 2 MiB")
            }
            request.httpBody = data
        }
        return request
    }
    private static func check(_ deadline: ContinuousClock.Instant) throws {
        try Task.checkCancellation()
        guard deadline > ContinuousClock.now else { throw SourceHostHTTPFailure(.timeout, "HTTP deadline exceeded") }
    }
    private static func remaining(_ deadline: ContinuousClock.Instant) -> TimeInterval {
        let duration = ContinuousClock.now.duration(to: deadline).components
        return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
    }
    private static func wait(_ delay: TimeInterval, deadline: ContinuousClock.Instant) async throws {
        try check(deadline)
        try await ContinuousClock().sleep(until: min(deadline, ContinuousClock.now.advanced(by: .seconds(delay))))
        try check(deadline)
    }
    /// A server delay outside the available budget is not shortened; the original HTTP response is returned.
    static func retryDelay(header: String?, maximumDelay: TimeInterval, remaining: TimeInterval, now: Date = Date()) -> TimeInterval? {
        let delay: TimeInterval
        if let header {
            let value = header.trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty, value.utf8.count <= 128 else { return nil }
            if value.allSatisfy({ $0.isASCII && $0.isNumber }), let seconds = Double(value), seconds.isFinite { delay = seconds }
            else {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.isLenient = false
                var date: Date?
                for format in ["EEE, dd MMM yyyy HH:mm:ss 'GMT'", "EEEE, dd-MMM-yy HH:mm:ss 'GMT'", "EEE MMM d HH:mm:ss yyyy"] {
                    formatter.dateFormat = format
                    if let parsed = formatter.date(from: value) { date = parsed; break }
                }
                guard let date else { return nil }
                delay = max(0, date.timeIntervalSince(now))
            }
        } else { delay = 0.25 }
        guard delay <= maximumDelay, delay + 0.05 < remaining else { return nil }
        return delay
    }

    private static func perform(_ original: URLRequest, policy: SourceHostHTTPPolicy, deadline: ContinuousClock.Instant, captureCookies: Bool, exposeCookies: Bool = false, returnRedirect: Bool = false) async throws -> Reply {
        try check(deadline)
        var request = original
        let timeout = remaining(deadline)
        request.timeoutInterval = timeout
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = timeout; configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        let watchdog = Task {
            do { try await ContinuousClock().sleep(until: deadline); session.invalidateAndCancel() } catch { }
        }
        defer { watchdog.cancel(); session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: SourceNoRedirectDelegate())
            try check(deadline)
            guard let response = response as? HTTPURLResponse, let url = response.url else { throw SourceHostHTTPFailure(.network, "Missing HTTP response") }
            _ = try policy.validate(url.absoluteString)
            var headers: [String: String] = [:]
            var cookieHeaders: [String: String] = [:]
            for (name, value) in response.allHeaderFields {
                let name = String(describing: name).lowercased()
                if !["set-cookie", "set-cookie2"].contains(name) { headers[name] = String(describing: value) }
                // Foundation’s cookie parser expects canonical field names on Darwin.
                else if captureCookies { cookieHeaders[name == "set-cookie" ? "Set-Cookie" : "Set-Cookie2"] = String(describing: value) }
                if exposeCookies && ["set-cookie", "set-cookie2"].contains(name) { headers[name] = String(describing: value) }
            }
            let cookies: [SourceCredentialCookie]
            if captureCookies, let origin = SourceHostHTTPPolicy.origin(url) {
                cookies = try HTTPCookie.cookies(withResponseHeaderFields: cookieHeaders, for: url).compactMap { try SourceCredentialCookie.capture($0, origin: origin) }
            } else { cookies = [] }
            // Cancel/dispose this response before acquiring a permit for its redirect target.
            if !returnRedirect, [301,302,303,307,308].contains(response.statusCode), headers["location"] != nil {
                return Reply(status: response.statusCode, url: url, headers: headers, data: Data(), cookies: cookies)
            }
            guard response.expectedContentLength <= Int64(policy.maximumBytes) else { throw SourceHostHTTPFailure(.resourceLimit, "HTTP response exceeds byte budget") }
            var data = Data()
            for try await byte in bytes {
                if (data.count & 4095) == 0 { try check(deadline) }
                guard data.count < policy.maximumBytes else { throw SourceHostHTTPFailure(.resourceLimit, "HTTP response exceeds byte budget") }
                data.append(byte)
            }
            try check(deadline)
            return Reply(status: response.statusCode, url: url, headers: headers, data: data, cookies: cookies)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            if deadline <= ContinuousClock.now { throw SourceHostHTTPFailure(.timeout, "HTTP deadline exceeded") }
            throw error
        }
    }
}
