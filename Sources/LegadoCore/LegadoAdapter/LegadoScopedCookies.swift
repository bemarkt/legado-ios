import Foundation

/// Named accounts use the shared credential vault. Guest cookies live only for this host session.
/// Neither variant touches HTTPCookieStorage.shared or the old persistent runtime cache.
public actor LegadoCookieJar {
    public let scope: SourceScope
    private let origins: Set<String>
    private let credentials: SourceCredentialSession?
    private var guest: [String: SourceCredentialCookie] = [:]
    public init(scope: SourceScope, origins: Set<String>, credentials: SourceCredentialSession?) throws {
        guard !origins.isEmpty, origins.allSatisfy(SourceCredentialCookie.validOrigin) else {
            throw SourceDomainError(.invalidInput, "Invalid compatibility cookie origins")
        }
        if let credentials {
            guard credentials.scope == scope, credentials.allowedOrigins == origins else {
                throw SourceDomainError(.invalidInput, "Cookie session does not match this source scope")
            }
        } else if scope.accountID != "guest" { throw SourceDomainError(.invalidInput, "Named account needs credentials") }
        self.scope = scope; self.origins = origins; self.credentials = credentials
    }
    private func check(_ gate: SourceCommitGate) throws {
        try gate.check()
        if let credentials, !gate.inherits(credentials.commitGate) {
            throw SourceDomainError(.invalidInput, "Cookie access requires the active credential gate")
        }
    }
    func headers(for url: URL, gate: SourceCommitGate) async throws -> [String: String] {
        try check(gate)
        guard let origin = SourceHostHTTPPolicy.origin(url), origins.contains(origin) else {
            throw SourceHostHTTPFailure(.permissionDenied, "Cookie URL is outside the approved origins")
        }
        if let credentials {
            let result = try await credentials.headers(for: url)
            try check(gate); return result
        }
        let cookies = guest.values.filter { $0.matches(url, now: Date()) }.sorted {
            $0.path.count == $1.path.count ? $0.key < $1.key : $0.path.count > $1.path.count
        }
        let header = cookies.map { $0.name + "=" + $0.value }.joined(separator: "; ")
        guard header.utf8.count <= 16_384 else { throw SourceDomainError(.resourceLimit, "Cookie header exceeds byte budget") }
        return header.isEmpty ? [:] : ["Cookie": header]
    }
    func receive(_ cookies: [SourceCredentialCookie], gate: SourceCommitGate) async throws {
        try check(gate)
        guard cookies.allSatisfy({ origins.contains($0.origin) }) else { throw SourceHostHTTPFailure(.permissionDenied, "Response cookie is outside approved origins") }
        if let credentials { try await credentials.receive(cookies, gate: gate); return }
        var updated = guest.filter { $0.value.expiresAt.map { $0 > Date() } ?? true }
        for cookie in cookies {
            if cookie.expiresAt.map({ $0 <= Date() }) ?? false { updated.removeValue(forKey: cookie.key) }
            else { updated[cookie.key] = cookie }
        }
        guard updated.count <= 128, try SourceCoding.encode(Array(updated.values)).count <= 65_536 else {
            throw SourceDomainError(.resourceLimit, "Guest cookie session exceeds storage limits")
        }
        try gate.withCommit { guest = updated }
    }
    func remove(origin: String, gate: SourceCommitGate) async throws {
        try check(gate)
        guard origins.contains(origin) else { throw SourceHostHTTPFailure(.permissionDenied, "Cookie removal is outside approved origins") }
        if let credentials { try await credentials.removeCompatibilityCookies(origin: origin, gate: gate) }
        else { try gate.withCommit { guest = guest.filter { $0.value.origin != origin } } }
    }
}

public struct LegadoScopedCookies: JavaScriptCookieState, SourceHTTPAuthorization {
    private let jar: LegadoCookieJar
    private let policy: SourceHostHTTPPolicy
    private let control: JavaScriptExecutionControl
    private let automatic: Bool
    public init(jar: LegadoCookieJar, policy: SourceHostHTTPPolicy, control: JavaScriptExecutionControl, automatic: Bool = true) {
        self.jar = jar; self.policy = policy; self.control = control; self.automatic = automatic
    }
    public func headers(for url: URL) async throws -> [String: String] {
        try control.check(); _ = try policy.validate(url.absoluteString)
        var headers = try await jar.headers(for: url, gate: control.commitGate)
        if !automatic { headers.removeValue(forKey: "Cookie") }
        try control.check(); return headers
    }
    public func receive(_ cookies: [SourceCredentialCookie]) async throws {
        try control.check()
        if automatic { try await jar.receive(cookies, gate: control.commitGate) }
    }
    public func cookieHeader(for value: String) throws -> String {
        let url = try policy.validate(value)
        return try LegadoAsyncBridge.wait(control: control) {
            try await jar.headers(for: url, gate: control.commitGate)["Cookie"] ?? ""
        }
    }
    public func cookie(for value: String, key: String) throws -> String {
        try cookieHeader(for: value).split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) } ?? ""
    }
    public func setCookie(_ cookie: String, for value: String) throws {
        let url = try policy.validate(value)
        guard !cookie.isEmpty else { return }
        guard cookie.utf8.count <= 16_384 else { throw SourceDomainError(.resourceLimit, "Cookie exceeds byte budget") }
        let origin = SourceHostHTTPPolicy.origin(url)!
        let values = try HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": cookie], for: url)
            .compactMap { try SourceCredentialCookie.capture($0, origin: origin) }
        guard !values.isEmpty else { throw SourceDomainError(.invalidInput, "Invalid compatibility Cookie") }
        try LegadoAsyncBridge.wait(control: control) { try await jar.receive(values, gate: control.commitGate) }
    }
    public func removeCookies(for value: String) throws {
        let url = try policy.validate(value), origin = SourceHostHTTPPolicy.origin(url)!
        try LegadoAsyncBridge.wait(control: control) { try await jar.remove(origin: origin, gate: control.commitGate) }
    }
}
