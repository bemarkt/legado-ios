import Foundation
import Testing
@testable import LegadoCore

struct SourceCookieScopeTests {
    private let web = "https://www.books.example"
    private let reader = "https://read.books.example"
    private func domainCookie(_ origin: String, value: String = "parent", expires: Date? = nil) throws -> SourceCredentialCookie {
        try .init(origin: origin, name: "sid", value: value, expiresAt: expires, domain: "books.example")
    }

    @Test func browserCaptureKeepsParentDomainAndHostCookiesWithTheSameName() async throws {
        let parent = try #require(HTTPCookie(properties: [.name: "sid", .value: "parent", .domain: ".books.example", .path: "/", .secure: "TRUE"]))
        let host = try #require(HTTPCookie(properties: [.name: "sid", .value: "host", .domain: "www.books.example", .path: "/", .secure: "TRUE"]))
        let a = try #require(SourceCredentialCookie.capture(parent, origin: web))
        let b = try #require(SourceCredentialCookie.capture(host, origin: web))
        #expect(a.key != b.key)
        #expect(a.domain == "books.example")
        #expect(b.domain == nil)
        #expect(a.browserCookie()?.domain == ".books.example")
        #expect(b.browserCookie()?.domain == "www.books.example")
        let vault = SourceCredentialVault(persistence: MemorySourceCredentials())
        let session = try await vault.session(scope: .init(installationID: UUID()), allowedOrigins: [web])
        try await session.receive([a, b])
        let before = try #require(try await session.headers(for: URL(string: web)!)["Cookie"])
        #expect(before.contains("sid=parent")); #expect(before.contains("sid=host"))
        // A host-only Set-Cookie deletion must not remove its parent-domain sibling.
        let deletion = try #require(HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": "sid=; Max-Age=0; Path=/"], for: URL(string: web)!).first)
        try await session.receive([try #require(SourceCredentialCookie.capture(deletion, origin: web))])
        #expect(try await session.headers(for: URL(string: web)!)["Cookie"] == "sid=parent")
    }

    @Test func domainRotationUpdatesAlreadyApprovedCopiesAndSurvivesReopening() async throws {
        let persistence = MemorySourceCredentials(), scope = try SourceScope(installationID: UUID())
        let vault = SourceCredentialVault(persistence: persistence)
        let initial = try await vault.session(scope: scope, allowedOrigins: [web, reader])
        try await vault.replaceBrowserCookies([domainCookie(web), domainCookie(reader)], session: initial)
        let active = try await vault.session(scope: scope, allowedOrigins: [web, reader])
        try await active.receive([domainCookie(web, value: "rotated")])
        #expect(try await active.headers(for: URL(string: reader + "/chapter")!)["Cookie"] == "sid=rotated")
        let reopened = try await SourceCredentialVault(persistence: persistence).session(scope: scope, allowedOrigins: [web, reader])
        #expect(reopened.revision == active.revision)
        #expect(try await reopened.headers(for: URL(string: web + "/catalog")!)["Cookie"] == "sid=rotated")
        #expect(try await reopened.headers(for: URL(string: reader + "/chapter")!)["Cookie"] == "sid=rotated")
        try await reopened.receive([domainCookie(reader, expires: .distantPast)])
        #expect(try await reopened.headers(for: URL(string: web)!).isEmpty)
        #expect(try await reopened.headers(for: URL(string: reader)!).isEmpty)
    }

    @Test func aDomainResponseDoesNotCreateNewOriginCookiePermissions() async throws {
        let vault = SourceCredentialVault(persistence: MemorySourceCredentials())
        let session = try await vault.session(scope: .init(installationID: UUID()), allowedOrigins: [web, reader])
        try await session.receive([domainCookie(web)])
        #expect(try await session.headers(for: URL(string: reader)!).isEmpty)
        let restricted = try await vault.session(scope: session.scope, allowedOrigins: [web])
        await #expect(throws: SourceDomainError.self) { try await restricted.headers(for: URL(string: reader)!) }
    }

    @Test func domainAttributeEqualToTheHostDoesNotCreateASecondCookieIdentity() throws {
        let hostOnly = try SourceCredentialCookie(origin: web, name: "sid", value: "a")
        let domain = try SourceCredentialCookie(origin: web, name: "sid", value: "b", domain: "www.books.example")
        #expect(hostOnly.key == domain.key)
        #expect(hostOnly != domain)
        #expect(throws: SourceDomainError.self) { try SourceCredentialCookie(origin: web, name: "sid", value: "x", domain: "unrelated.example") }
    }

    @Test func oldCredentialsWithoutDomainStillDecodeAndStayOriginBound() throws {
        let data = Data(#"{"origin":"https://www.books.example","name":"sid","value":"legacy","path":"/","secure":true,"httpOnly":true}"#.utf8)
        let old = try SourceCoding.decode(SourceCredentialCookie.self, from: data)
        #expect(old.domain == nil)
        #expect(old.matches(URL(string: web)!, now: Date()))
        #expect(!old.matches(URL(string: reader)!, now: Date()))
        #expect(old.browserCookie()?.domain == "www.books.example")
    }

    @Test func decodedCredentialsValidateOriginAndDomainBeforeUse() throws {
        for (origin, domain) in [("not-an-origin", "books.example"), (web, "unrelated.example")] {
            let data = try JSONSerialization.data(withJSONObject: ["origin": origin, "name": "sid", "value": "x", "path": "/",
                "secure": true, "httpOnly": true, "domain": domain])
            #expect(throws: SourceDomainError.self) { try SourceCoding.decode(SourceCredentialCookie.self, from: data) }
        }
    }

    @Test func replacingDomainCookieWithHostOnlyWithdrawsSavedSubdomainCopy() async throws {
        let subdomain = "https://nested.www.books.example"
        let vault = SourceCredentialVault(persistence: MemorySourceCredentials())
        let initial = try await vault.session(scope: .init(installationID: UUID()), allowedOrigins: [web, subdomain])
        try await vault.replaceBrowserCookies([web, subdomain].map {
            try .init(origin: $0, name: "sid", value: "old", domain: "www.books.example")
        }, session: initial)
        let session = try await vault.session(scope: initial.scope, allowedOrigins: [web, subdomain])
        try await session.receive([.init(origin: web, name: "sid", value: "host")])
        #expect(try await session.headers(for: URL(string: web)!)["Cookie"] == "sid=host")
        #expect(try await session.headers(for: URL(string: subdomain)!).isEmpty)
    }

    @Test func cookieDiagnosticsReportAttachmentWithoutExportingSecrets() async throws {
        var request = URLRequest(url: URL(string: web + "/private?token=private-query")!)
        request.setValue("private-name=private-cookie; second=secret", forHTTPHeaderField: "Cookie")
        request.setValue("private-user-agent", forHTTPHeaderField: "User-Agent")
        let exchange = SourceHTTPExchangeSummary(request: request, status: 202, responseBytes: 209,
            cookies: [try .init(origin: web, name: "gone", value: "", expiresAt: .distantPast)], hasSetCookieHeader: true)
        #expect(exchange.sentCookieCount == 2)
        #expect(exchange.receivedCookieCount == 1)
        #expect(exchange.deletedCookieCount == 1)
        let log = SourceDiagnostics()
        let identity = try SourceExecutionIdentity(scope: .init(installationID: UUID()), sourceDigest: String(repeating: "a", count: 64),
            configuration: .object([:]), credentialRevision: "private-login-revision")
        for _ in 0..<128 {
            await log.record(id: UUID(), operation: .chapters, identity: identity, issue: nil, elapsedMilliseconds: 1,
                cookieJarEnabled: true, httpExchanges: Array(repeating: exchange, count: 20))
        }
        let exported = String(decoding: try await log.export(), as: UTF8.self)
        for secret in [web, "private-query", "private-name", "private-cookie", "private-user-agent", "private-login-revision"] {
            #expect(!exported.contains(secret))
        }
        #expect(await log.records().first?.httpExchanges?.count == 16)
        #expect(exported.utf8.count < 1_048_576)
    }
}
