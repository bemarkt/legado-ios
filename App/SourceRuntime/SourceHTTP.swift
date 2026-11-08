import Foundation
#if SWIFT_PACKAGE
import LegadoCore
#endif

struct SourceHTTPRequest: Decodable, Sendable {
    let url: String
    let method: String
    let headers: [String: String]
    let body: String? // base64, bounded before decoding
    let redirect: String
}

struct SourceHTTPResponse: Encodable, Sendable {
    let status: Int
    let url: String
    let headers: [String: String]
    let body: String // base64 preserves arbitrary response bytes
}

struct SourceHTTPPolicy: Sendable {
    let origins: Set<String>
    let allowLoopbackHTTP: Bool
    let maximumBytes: Int
    let maximumRedirects: Int
    let timeout: TimeInterval

    static func origin(_ url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
        let port = url.port
        let suffix = port == nil || (scheme == "https" && port == 443) || (scheme == "http" && port == 80) ? "" : ":\(port!)"
        return "\(scheme)://\(host)\(suffix)"
    }

    func validate(_ string: String) throws -> URL {
        guard string.utf8.count <= 8192, string == string.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: string), let origin = Self.origin(url),
              url.user == nil, url.password == nil, origins.contains(origin),
              url.scheme == "https" || (allowLoopbackHTTP && url.scheme == "http" && ["127.0.0.1", "localhost", "[::1]"].contains(url.host ?? "")) else {
            throw SourceFailure(code: "PERMISSION_DENIED", message: "URL is outside the authorized HTTP policy")
        }
        return url
    }
}

/// URLSession delegate state is locked because callbacks are not MainActor-isolated.
private final class SourceRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let policy: SourceHTTPPolicy
    private let redirect: String
    private let lock = NSLock()
    private var hops = 0
    private var rejection: SourceFailure?
    init(policy: SourceHTTPPolicy, redirect: String) { self.policy = policy; self.redirect = redirect }
    var failure: SourceFailure? { lock.lock(); defer { lock.unlock() }; return rejection }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        do {
            guard redirect == "follow" else { throw SourceFailure(code: "NETWORK", message: "Redirect rejected by request policy") }
            hops += 1
            guard hops <= policy.maximumRedirects else { throw SourceFailure(code: "RESOURCE_LIMIT", message: "Redirect budget exceeded") }
            _ = try policy.validate(request.url?.absoluteString ?? "")
            var safe = request
            if response.url.flatMap(SourceHTTPPolicy.origin) != request.url.flatMap(SourceHTTPPolicy.origin) {
                // Cross-origin redirects retain only these content-negotiation headers.
                for key in (safe.allHTTPHeaderFields ?? [:]).keys where !["accept", "accept-language", "content-type"].contains(key.lowercased()) {
                    safe.setValue(nil, forHTTPHeaderField: key)
                }
            }
            if response.statusCode == 303 && safe.httpMethod != "HEAD" ||
                ([301, 302].contains(response.statusCode) && task.currentRequest?.httpMethod == "POST") {
                safe.httpMethod = "GET"
                safe.httpBody = nil
                safe.setValue(nil, forHTTPHeaderField: "Content-Type")
                safe.setValue(nil, forHTTPHeaderField: "Content-Length")
            }
            completionHandler(safe)
        } catch {
            rejection = error as? SourceFailure ?? SourceFailure(code: "NETWORK", message: "Redirect failed")
            completionHandler(nil)
        }
    }
}

enum SourceHTTP {
    private static let scheduler = SourceWorkScheduler(globalLimit: 4, perOriginLimit: 2)
    static func fetch(_ input: SourceHTTPRequest, policy: SourceHTTPPolicy, priority: SourceWorkScheduler.Priority = .reading) async throws -> SourceHTTPResponse {
        let url = try policy.validate(input.url)
        do {
            return try await scheduler.withPermit(origin: SourceHTTPPolicy.origin(url) ?? "", priority: priority, deadline: Date().addingTimeInterval(policy.timeout)) {
                try await perform(input, policy: policy)
            }
        } catch is CancellationError { throw SourceFailure(code: "CANCELLED", message: "HTTP request cancelled in queue") }
        catch let error as SourceDomainError { throw SourceFailure(code: "TIMEOUT", message: error.message) }
    }
    private static func perform(_ input: SourceHTTPRequest, policy: SourceHTTPPolicy) async throws -> SourceHTTPResponse {
        let url = try policy.validate(input.url)
        guard ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE"].contains(input.method),
              ["follow", "error"].contains(input.redirect),
              !(["GET", "HEAD"].contains(input.method) && input.body != nil), input.headers.count <= 64 else {
            throw SourceFailure(code: "INVALID_INPUT", message: "Invalid HTTP method, body or headers")
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: policy.timeout)
        request.httpMethod = input.method
        request.httpShouldHandleCookies = false
        let forbidden = Set(["host", "content-length", "cookie", "cookie2", "connection", "transfer-encoding", "upgrade", "proxy-authorization", "proxy-connection", "te", "trailer", "accept-encoding"])
        var names = Set<String>()
        for (name, value) in input.headers {
            let key = name.lowercased()
            guard name.range(of: "^[!#$%&'*+.^_`|~0-9A-Za-z-]+$", options: .regularExpression) != nil,
                  !forbidden.contains(key), !key.hasPrefix("sec-"), names.insert(key).inserted,
                  value.utf8.count <= 8192, !value.contains("\r"), !value.contains("\n"), !value.contains("\0") else {
                throw SourceFailure(code: "INVALID_INPUT", message: "Invalid or host-owned HTTP header")
            }
            request.setValue(value, forHTTPHeaderField: name)
        }
        if let body = input.body {
            guard body.utf8.count <= 2_796_204, let data = Data(base64Encoded: body), data.count <= 2_097_152 else {
                throw SourceFailure(code: "RESOURCE_LIMIT", message: "HTTP request body exceeds 2 MiB")
            }
            request.httpBody = data
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let delegate = SourceRedirectDelegate(policy: policy, redirect: input.redirect)
        do {
            let (bytes, response) = try await session.bytes(for: request, delegate: delegate)
            if let failure = delegate.failure { throw failure }
            guard let response = response as? HTTPURLResponse, let finalURL = response.url else {
                throw SourceFailure(code: "NETWORK", message: "Missing HTTP response")
            }
            _ = try policy.validate(finalURL.absoluteString)
            guard response.expectedContentLength <= Int64(policy.maximumBytes) else {
                throw SourceFailure(code: "RESOURCE_LIMIT", message: "HTTP response exceeds byte budget")
            }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < policy.maximumBytes else {
                    throw SourceFailure(code: "RESOURCE_LIMIT", message: "HTTP response exceeds byte budget")
                }
                data.append(byte)
            }
            var headers: [String: String] = [:]
            for (key, value) in response.allHeaderFields {
                let key = String(describing: key).lowercased()
                if !["set-cookie", "set-cookie2"].contains(key) { headers[key] = String(describing: value) }
            }
            return SourceHTTPResponse(status: response.statusCode, url: finalURL.absoluteString,
                                      headers: headers, body: data.base64EncodedString())
        } catch let failure as SourceFailure { throw failure }
        catch {
            if let failure = delegate.failure { throw failure }
            if Task.isCancelled || (error as? URLError)?.code == .cancelled {
                throw SourceFailure(code: "CANCELLED", message: "HTTP request cancelled")
            }
            if (error as? URLError)?.code == .timedOut {
                throw SourceFailure(code: "TIMEOUT", message: "HTTP request timed out")
            }
            throw SourceFailure(code: "NETWORK", message: "HTTP transport failed")
        }
    }
}
