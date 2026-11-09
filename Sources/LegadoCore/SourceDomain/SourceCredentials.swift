import Foundation
import Security

/// Persistence is synchronous within the vault actor, so a read/modify/write cannot interleave.
public protocol SourceCredentialPersistence: Sendable {
    func read(scope: SourceScope) throws -> Data?
    func write(_ data: Data, scope: SourceScope) throws
}

public struct SourceKeychainCredentials: SourceCredentialPersistence {
    private let service: String
    public init(service: String = "com.epiboly.legado.native.credentials.v1") { self.service = service }
    private func query(_ scope: SourceScope) throws -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: SourceCoding.digest(try SourceCoding.encode(scope)), kSecAttrSynchronizable as String: false]
    }
    public func read(scope: SourceScope) throws -> Data? {
        var query = try query(scope)
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw SourceDomainError(.unavailable, "暂时无法读取系统凭据，请解锁设备后重试。")
        }
        return data
    }
    public func write(_ data: Data, scope: SourceScope) throws {
        let query = try query(scope)
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insertion = query
            attributes.forEach { insertion[$0.key] = $0.value }
            status = SecItemAdd(insertion as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw SourceDomainError(.unavailable, "无法保存系统凭据，请解锁设备后重试。") }
    }
}

/// Cookies are partitioned by the exact approved origin, even if a server supplies Domain.
/// Secrets never enter a SourceRef, configuration, database export, or the source execution page.
public struct SourceCredentialCookie: Codable, Sendable, Equatable {
    public let origin: String
    public let name: String
    public let value: String
    public let path: String
    public let secure: Bool
    public let httpOnly: Bool
    public let expiresAt: Date?
    public init(origin: String, name: String, value: String, path: String = "/", secure: Bool = true,
                httpOnly: Bool = true, expiresAt: Date? = nil) throws {
        guard Self.validOrigin(origin), !name.isEmpty, name.utf8.count <= 256,
              name.utf8.allSatisfy({ $0 > 32 && $0 < 127 && ![34,40,41,44,47,58,59,60,61,62,63,64,91,92,93,123,125].contains($0) }),
              value.utf8.count <= 4096, value.utf8.allSatisfy({ $0 >= 32 && $0 < 127 && ![10,13,59].contains($0) }),
              path.hasPrefix("/"), path.utf8.count <= 4096, !path.contains("\r"), !path.contains("\n") else {
            throw SourceDomainError(.invalidInput, "无效的登录 Cookie。")
        }
        self.origin = origin; self.name = name; self.value = value; self.path = path
        self.secure = secure; self.httpOnly = httpOnly; self.expiresAt = expiresAt
    }
    static func validOrigin(_ origin: String) -> Bool {
        guard let url = URL(string: origin), SourceHostHTTPPolicy.origin(url) == origin,
              url.scheme == "https" || (url.scheme == "http" && ["127.0.0.1", "localhost", "[::1]"].contains(url.host ?? "")),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, url.path.isEmpty else { return false }
        return true
    }
    public static func capture(_ cookie: HTTPCookie, origin: String) throws -> Self? {
        guard let url = URL(string: origin), let host = url.host?.lowercased() else { return nil }
        let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard host == domain || (cookie.domain.hasPrefix(".") && host.hasSuffix("." + domain)) else { return nil }
        if cookie.isSecure && url.scheme != "https" { return nil }
        return try .init(origin: origin, name: cookie.name, value: cookie.value, path: cookie.path,
                         secure: cookie.isSecure, httpOnly: cookie.isHTTPOnly, expiresAt: cookie.expiresDate)
    }
    public func browserCookie() -> HTTPCookie? {
        guard let host = URL(string: origin)?.host else { return nil }
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: host, .path: path]
        if secure { properties[.secure] = "TRUE" }
        if httpOnly { properties[HTTPCookiePropertyKey(rawValue: "HttpOnly")] = "TRUE" }
        if let expiresAt { properties[.expires] = expiresAt }
        return HTTPCookie(properties: properties)
    }
    var key: String { origin + "\n" + name + "\n" + path }
    func matches(_ url: URL, now: Date) -> Bool {
        guard SourceHostHTTPPolicy.origin(url) == origin, expiresAt.map({ $0 > now }) ?? true,
              !secure || url.scheme == "https" else { return false }
        let requestPath = url.path.isEmpty ? "/" : url.path
        return requestPath == path || (requestPath.hasPrefix(path) && (path.hasSuffix("/") || requestPath.dropFirst(path.count).hasPrefix("/")))
    }
}

public struct SourceCredentialStatus: Sendable, Equatable {
    public let cookieCount: Int
    public let bearerOrigins: [String]
}

/// A host-only lease. Revocation rejects HTTP responses, state writes, and library commits.
public struct SourceCredentialSession: Sendable {
    public let scope: SourceScope
    public let revision: String
    public let commitGate: SourceCommitGate
    public let allowedOrigins: Set<String>
    fileprivate let vault: SourceCredentialVault
    public func headers(for url: URL) async throws -> [String: String] { try await vault.headers(for: url, session: self) }
    public func receive(_ cookies: [SourceCredentialCookie]) async throws { try await vault.receive(cookies, session: self) }
    public func receive(_ cookies: [SourceCredentialCookie], gate: SourceCommitGate) async throws {
        try await vault.receive(cookies, session: self, gate: gate)
    }
    public func removeCompatibilityCookies(origin: String, gate: SourceCommitGate) async throws {
        try await vault.removeCompatibilityCookies(origin: origin, session: self, gate: gate)
    }

    /// These values are exposed only to the legacy adapter, never the native module bridge.
    public func legacyValue(key: String) async throws -> String { try await vault.legacyValue(key: key, session: self) }
    public func setLegacyValue(_ value: String, key: String, gate: SourceCommitGate) async throws {
        try await vault.setLegacyValue(value, key: key, session: self, gate: gate)
    }

}

public actor SourceCredentialVault {
    public static let shared = SourceCredentialVault(persistence: SourceKeychainCredentials())
    private struct Bundle: Codable, Sendable {
        var revision: String
        var cookies: [SourceCredentialCookie]
        var bearer: [String: String]
        var legacy: [String: String]?
    }
    private struct Entry { var bundle: Bundle; let gate: SourceCommitGate }
    private let persistence: any SourceCredentialPersistence
    private var entries: [SourceScope: Entry] = [:]
    public init(persistence: any SourceCredentialPersistence) { self.persistence = persistence }

    public func session(scope: SourceScope, allowedOrigins: Set<String>) throws -> SourceCredentialSession {
        guard scope.accountID != "guest", !allowedOrigins.isEmpty, allowedOrigins.allSatisfy(SourceCredentialCookie.validOrigin) else {
            throw SourceDomainError(.invalidInput, "凭据需要独立账号与有效访问范围。")
        }
        let entry = try load(scope)
        return .init(scope: scope, revision: entry.bundle.revision, commitGate: entry.gate, allowedOrigins: allowedOrigins, vault: self)
    }
    public func suspend(scope: SourceScope) { entries.removeValue(forKey: scope)?.gate.invalidate() }
    public func status(scope: SourceScope) throws -> SourceCredentialStatus {
        let entry = try load(scope)
        return .init(cookieCount: entry.bundle.cookies.filter { $0.expiresAt.map { $0 > Date() } ?? true }.count,
                     bearerOrigins: entry.bundle.bearer.keys.sorted())
    }
    public func browserCookies(session: SourceCredentialSession) throws -> [SourceCredentialCookie] {
        let entry = try validated(session)
        return entry.bundle.cookies.filter { session.allowedOrigins.contains($0.origin) && ($0.expiresAt.map { $0 > Date() } ?? true) }
    }
    public func replaceBrowserCookies(_ cookies: [SourceCredentialCookie], session: SourceCredentialSession,
                                      replacingOrigins: Set<String>? = nil, changeGate: SourceCommitGate? = nil) throws {
        let entry = try validated(session)
        let origins = replacingOrigins ?? session.allowedOrigins
        guard !origins.isEmpty, origins.isSubset(of: session.allowedOrigins), cookies.allSatisfy({ origins.contains($0.origin) }) else {
            throw SourceDomainError(.invalidInput, "Cookie 超出账号授权范围。")
        }
        var bundle = entry.bundle
        bundle.cookies.removeAll { origins.contains($0.origin) }
        bundle.cookies.append(contentsOf: cookies.filter { $0.expiresAt.map { $0 > Date() } ?? true })
        if let changeGate { try changeGate.withCommit { try replace(bundle, scope: session.scope) } }
        else { try replace(bundle, scope: session.scope) }
    }
    public func setBearer(_ token: String?, origin: String, session: SourceCredentialSession, changeGate: SourceCommitGate? = nil) throws {
        let entry = try validated(session)
        guard session.allowedOrigins.contains(origin) else { throw SourceDomainError(.invalidInput, "令牌网站不在授权范围内。") }
        if let token {
            guard !token.isEmpty, token.utf8.count <= 8192, token.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else {
                throw SourceDomainError(.invalidInput, "令牌不能为空或包含空白控制字符。")
            }
        }
        var bundle = entry.bundle
        bundle.bearer[origin] = token
        if let changeGate { try changeGate.withCommit { try replace(bundle, scope: session.scope) } }
        else { try replace(bundle, scope: session.scope) }
    }
    public func clear(session: SourceCredentialSession, changeGate: SourceCommitGate) throws {
        _ = try validated(session)
        try changeGate.withCommit { try clear(scope: session.scope) }
    }
    public func clear(scope: SourceScope) throws {
        _ = try load(scope)
        try replace(Bundle(revision: "", cookies: [], bearer: [:]), scope: scope)
    }
    fileprivate func legacyValue(key: String, session: SourceCredentialSession) throws -> String {
        guard ["loginInfo", "loginHeader"].contains(key) else { throw SourceDomainError(.invalidInput, "Unknown compatibility credential key") }
        return try validated(session).bundle.legacy?[key] ?? ""
    }
    fileprivate func setLegacyValue(_ value: String, key: String, session: SourceCredentialSession, gate: SourceCommitGate) throws {
        guard gate.inherits(session.commitGate) else { throw SourceDomainError(.invalidInput, "Credential writes require a gate bound to this session") }
        _ = try legacyValue(key: key, session: session)
        var bundle = try validated(session).bundle
        if bundle.legacy == nil { bundle.legacy = [:] }
        bundle.legacy?[key] = value.isEmpty ? nil : value
        let data = try encoded(bundle)
        try gate.withCommit { try persistence.write(data, scope: session.scope) }
        entries[session.scope]?.bundle = bundle
    }

    private func load(_ scope: SourceScope) throws -> Entry {
        guard scope.accountID != "guest" else { throw SourceDomainError(.invalidInput, "访客不保存登录凭据。") }
        if let entry = entries[scope] { return entry }
        let bundle: Bundle
        if let data = try persistence.read(scope: scope) {
            guard data.count <= 65_536 else { throw SourceDomainError(.invalidData, "登录凭据超出保存范围。") }
            do { bundle = try SourceCoding.decode(Bundle.self, from: data) }
            catch { throw SourceDomainError(.invalidData, "保存的登录凭据无法读取。") }
            _ = try encoded(bundle)
        } else {
            bundle = Bundle(revision: UUID().uuidString, cookies: [], bearer: [:])
            try persistence.write(encoded(bundle), scope: scope)
        }
        let entry = Entry(bundle: bundle, gate: SourceCommitGate())
        entries[scope] = entry
        return entry
    }
    private func validated(_ session: SourceCredentialSession) throws -> Entry {
        try session.commitGate.check()
        guard let entry = entries[session.scope], entry.gate === session.commitGate, entry.bundle.revision == session.revision else {
            throw SourceDomainError(.stale, "账号登录状态已改变，请重新打开。")
        }
        return entry
    }
    private func encoded(_ bundle: Bundle) throws -> Data {
        guard UUID(uuidString: bundle.revision) != nil, bundle.cookies.count <= 128, bundle.bearer.count <= 32,
              Set(bundle.cookies.map(\.key)).count == bundle.cookies.count else { throw SourceDomainError(.resourceLimit, "登录凭据超过数量限制。") }
        for cookie in bundle.cookies {
            _ = try SourceCredentialCookie(origin: cookie.origin, name: cookie.name, value: cookie.value, path: cookie.path,
                                           secure: cookie.secure, httpOnly: cookie.httpOnly, expiresAt: cookie.expiresAt)
        }
        for (origin, token) in bundle.bearer {
            guard SourceCredentialCookie.validOrigin(origin), !token.isEmpty, token.utf8.count <= 8192,
                  token.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else { throw SourceDomainError(.invalidData, "保存的令牌无效。") }
        }
        if let legacy = bundle.legacy {
            guard Set(legacy.keys).isSubset(of: ["loginInfo", "loginHeader"]),
                  legacy.values.allSatisfy({ $0.utf8.count <= 16_384 }) else {
                throw SourceDomainError(.resourceLimit, "Compatibility login state exceeds storage limits")
            }
        }
        let data = try SourceCoding.encode(bundle)
        guard data.count <= 65_536 else { throw SourceDomainError(.resourceLimit, "登录凭据超过容量限制。") }
        return data
    }
    private func replace(_ value: Bundle, scope: SourceScope) throws {
        var bundle = value; bundle.revision = UUID().uuidString
        try persistence.write(encoded(bundle), scope: scope)
        entries.removeValue(forKey: scope)?.gate.invalidate()
        entries[scope] = Entry(bundle: bundle, gate: SourceCommitGate())
    }
    fileprivate func headers(for url: URL, session: SourceCredentialSession) throws -> [String: String] {
        let entry = try validated(session)
        guard let origin = SourceHostHTTPPolicy.origin(url), session.allowedOrigins.contains(origin) else {
            throw SourceDomainError(.invalidInput, "凭据请求不在授权网站内。")
        }
        var headers: [String: String] = [:]
        let cookies = entry.bundle.cookies.filter { $0.matches(url, now: Date()) }.sorted { $0.path.count > $1.path.count }
        if !cookies.isEmpty { headers["Cookie"] = cookies.map { $0.name + "=" + $0.value }.joined(separator: "; ") }
        if let token = entry.bundle.bearer[origin] { headers["Authorization"] = "Bearer " + token }
        guard headers.values.reduce(0, { $0 + $1.utf8.count }) <= 16_384 else {
            throw SourceDomainError(.resourceLimit, "请求凭据超过头部容量限制。")
        }
        return headers
    }
    fileprivate func removeCompatibilityCookies(origin: String, session: SourceCredentialSession, gate: SourceCommitGate) throws {
        guard gate.inherits(session.commitGate), session.allowedOrigins.contains(origin) else {
            throw SourceDomainError(.invalidInput, "Cookie removal is outside the operation scope")
        }
        var bundle = try validated(session).bundle
        bundle.cookies.removeAll { $0.origin == origin }
        try gate.withCommit { try persistence.write(encoded(bundle), scope: session.scope) }
        entries[session.scope]?.bundle = bundle
    }
    fileprivate func receive(_ cookies: [SourceCredentialCookie], session: SourceCredentialSession, gate: SourceCommitGate? = nil) throws {
        if let gate, !gate.inherits(session.commitGate) { throw SourceDomainError(.invalidInput, "Cookie writes require the session gate") }
        let entry = try validated(session)
        guard !cookies.isEmpty else { return }
        var values = Dictionary(uniqueKeysWithValues: entry.bundle.cookies.map { ($0.key, $0) })
        let now = Date()
        for cookie in cookies {
            guard session.allowedOrigins.contains(cookie.origin) else { throw SourceDomainError(.invalidInput, "响应 Cookie 超出授权范围。") }
            if cookie.expiresAt.map({ $0 <= now }) ?? false { values.removeValue(forKey: cookie.key) }
            else { values[cookie.key] = cookie }
        }
        var bundle = entry.bundle
        bundle.cookies = values.values.filter { $0.expiresAt.map { $0 > now } ?? true }.sorted { $0.key < $1.key }
        if bundle.cookies == entry.bundle.cookies { return }
        // Routine cookie rotation keeps the login generation; an explicit login change does not.
        try (gate ?? session.commitGate).withCommit { try persistence.write(encoded(bundle), scope: session.scope) }
        entries[session.scope]?.bundle = bundle
    }
}
