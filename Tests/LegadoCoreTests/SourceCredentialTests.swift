import Foundation
import Testing
@testable import LegadoCore

final class MemorySourceCredentials: SourceCredentialPersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [SourceScope: Data] = [:]
    private var failWrites = false
    func setFailing(_ value: Bool) { lock.lock(); defer { lock.unlock() }; failWrites = value }
    func read(scope: SourceScope) throws -> Data? { lock.lock(); defer { lock.unlock() }; return records[scope] }
    func write(_ data: Data, scope: SourceScope) throws {
        lock.lock(); defer { lock.unlock() }
        if failWrites { throw SourceDomainError(.unavailable, "Synthetic secure store failure") }
        records[scope] = data
    }
}

@Suite("Native account credentials and revocation")
struct SourceCredentialTests {
    private let origin = "https://books.example"
    private let other = "https://media.example"
    private func scope(_ installation: UUID = UUID(), account: String = UUID().uuidString) throws -> SourceScope {
        try .init(installationID: installation, accountID: account)
    }
    private func cookie(origin: String = "https://books.example", name: String = "session", value: String = "secret", path: String = "/", expires: Date? = nil) throws -> SourceCredentialCookie {
        try .init(origin: origin, name: name, value: value, path: path, expiresAt: expires)
    }
    @Test func guestNeverStoresCredentials() async throws {
        let store = MemorySourceCredentials(), guest = try SourceScope(installationID: UUID())
        let vault = SourceCredentialVault(persistence: store)
        await #expect(throws: SourceDomainError.self) { try await vault.session(scope: guest, allowedOrigins: [origin]) }
        #expect(try store.read(scope: guest) == nil)
    }
    @Test func originsPortsPathsAndExpiryAreEnforced() async throws {
        let vault = SourceCredentialVault(persistence: MemorySourceCredentials()), scope = try scope()
        let session = try await vault.session(scope: scope, allowedOrigins: [origin, other, origin + ":8443"])
        try await session.receive([cookie(path: "/reader"), cookie(name: "root", value: "ok"), cookie(name: "gone", expires: .distantPast)])
        #expect(try await session.headers(for: URL(string: origin + "/reader/chapter")!)["Cookie"] == "session=secret; root=ok")
        #expect(try await session.headers(for: URL(string: origin + "/readers")!)["Cookie"] == "root=ok")
        #expect(try await session.headers(for: URL(string: other + "/reader")!).isEmpty)
        #expect(try await session.headers(for: URL(string: origin + ":8443/reader")!).isEmpty)
        await #expect(throws: SourceDomainError.self) { try await session.headers(for: URL(string: "https://books.example.evil/reader")!) }
    }
    @Test func sameWebsiteIsIsolatedByInstallationAndAccount() async throws {
        let vault = SourceCredentialVault(persistence: MemorySourceCredentials()), installation = UUID()
        let first = try await vault.session(scope: scope(installation), allowedOrigins: [origin])
        let second = try await vault.session(scope: scope(installation), allowedOrigins: [origin])
        let third = try await vault.session(scope: scope(account: first.scope.accountID), allowedOrigins: [origin])
        try await first.receive([cookie()])
        #expect(try await second.headers(for: URL(string: origin)!).isEmpty)
        #expect(try await third.headers(for: URL(string: origin)!).isEmpty)
    }
    @Test func responseCookiesPersistWithoutChangingTheLoginGeneration() async throws {
        let store = MemorySourceCredentials(), scope = try scope()
        let vault = SourceCredentialVault(persistence: store)
        let first = try await vault.session(scope: scope, allowedOrigins: [origin])
        try await first.receive([cookie()])
        try await first.receive([cookie(value: "rotated")])
        let reopened = try await SourceCredentialVault(persistence: store).session(scope: scope, allowedOrigins: [origin])
        #expect(reopened.revision == first.revision)
        #expect(try await reopened.headers(for: URL(string: origin)!)["Cookie"] == "session=rotated")
        try await first.receive([cookie(expires: .distantPast)])
        #expect(try await first.headers(for: URL(string: origin)!).isEmpty)
    }
    @Test func explicitLoginReplacementRevokesOldLeasesAndChangesIdentity() async throws {
        let vault = SourceCredentialVault(persistence: MemorySourceCredentials()), scope = try scope()
        let first = try await vault.session(scope: scope, allowedOrigins: [origin])
        let child = SourceCommitGate(parent: first.commitGate)
        try await vault.replaceBrowserCookies([cookie()], session: first)
        #expect(throws: SourceDomainError.self) { try child.check() }
        await #expect(throws: SourceDomainError.self) { try await first.headers(for: URL(string: origin)!) }
        let second = try await vault.session(scope: scope, allowedOrigins: [origin])
        #expect(second.revision != first.revision)
        #expect(try await second.headers(for: URL(string: origin)!)["Cookie"] == "session=secret")
        let a = try SourceExecutionIdentity(scope: scope, sourceDigest: String(repeating: "a", count: 64), configuration: .object([:]), credentialRevision: first.revision)
        let b = try SourceExecutionIdentity(scope: scope, sourceDigest: a.sourceDigest, configuration: .object([:]), credentialRevision: second.revision)
        #expect(a != b)
    }
    @Test func failedSecureStoreWritePreservesTheExistingLogin() async throws {
        let store = MemorySourceCredentials(), vault = SourceCredentialVault(persistence: store)
        let session = try await vault.session(scope: scope(), allowedOrigins: [origin])
        try await session.receive([cookie()])
        store.setFailing(true)
        await #expect(throws: SourceDomainError.self) { try await vault.setBearer("replacement", origin: origin, session: session) }
        try session.commitGate.check()
        #expect(try await session.headers(for: URL(string: origin)!)["Cookie"] == "session=secret")
        #expect(try await session.headers(for: URL(string: origin)!)["Authorization"] == nil)
    }
    @Test func bearerIsOriginBoundAndNeverExposedInStatus() async throws {
        let vault = SourceCredentialVault(persistence: MemorySourceCredentials()), scope = try scope()
        let first = try await vault.session(scope: scope, allowedOrigins: [origin, other])
        try await vault.setBearer("private-token", origin: origin, session: first)
        let current = try await vault.session(scope: scope, allowedOrigins: [origin, other])
        #expect(try await current.headers(for: URL(string: origin)!)["Authorization"] == "Bearer private-token")
        #expect(try await current.headers(for: URL(string: other)!).isEmpty)
        #expect(try await vault.status(scope: scope).bearerOrigins == [origin])
        await #expect(throws: SourceDomainError.self) { try await vault.setBearer("bad\r\nInjected: value", origin: origin, session: current) }
        try current.commitGate.check()
    }
    @Test func leavingAnAccountInvalidatesOldOperationsAndAllowsReentry() async throws {
        let vault = SourceCredentialVault(persistence: MemorySourceCredentials()), scope = try scope()
        let previous = try await vault.session(scope: scope, allowedOrigins: [origin])
        try await previous.receive([cookie()])
        await vault.suspend(scope: scope)
        await #expect(throws: SourceDomainError.self) { try await previous.receive([cookie(value: "late")]) }
        let next = try await vault.session(scope: scope, allowedOrigins: [origin])
        #expect(next.revision == previous.revision)
        #expect(try await next.headers(for: URL(string: origin)!)["Cookie"] == "session=secret")
    }
    @Test func logoutRejectsLateCookieResponsesAndKeepsAnEmptyNewGeneration() async throws {
        let store = MemorySourceCredentials(), scope = try scope(), vault = SourceCredentialVault(persistence: store)
        let old = try await vault.session(scope: scope, allowedOrigins: [origin])
        try await old.receive([cookie()])
        try await vault.clear(scope: scope)
        await #expect(throws: SourceDomainError.self) { try await old.receive([cookie(value: "late")]) }
        let current = try await SourceCredentialVault(persistence: store).session(scope: scope, allowedOrigins: [origin])
        #expect(current.revision != old.revision)
        #expect(try await current.headers(for: URL(string: origin)!).isEmpty)
    }
    @Test func scopeCannotWidenItsCapturedOrigins() async throws {
        let vault = SourceCredentialVault(persistence: MemorySourceCredentials()), scope = try scope()
        let wider = try await vault.session(scope: scope, allowedOrigins: [origin, other])
        try await wider.receive([cookie(origin: other)])
        let limited = try await vault.session(scope: scope, allowedOrigins: [origin])
        await #expect(throws: SourceDomainError.self) { try await limited.headers(for: URL(string: other)!) }
        await #expect(throws: SourceDomainError.self) { try await limited.receive([cookie(origin: other)]) }
        #expect(try await vault.browserCookies(session: limited).isEmpty)
    }
    @Test func malformedCookiesAndOverBudgetUpdatesLeavePriorStateUntouched() async throws {
        #expect(throws: SourceDomainError.self) { try cookie(name: "bad:name") }
        #expect(throws: SourceDomainError.self) { try cookie(value: "bad;session") }
        #expect(throws: SourceDomainError.self) { try cookie(origin: origin + "/path") }
        let vault = SourceCredentialVault(persistence: MemorySourceCredentials())
        let session = try await vault.session(scope: scope(), allowedOrigins: [origin])
        try await session.receive([cookie()])
        let tooMany = try (0..<129).map { try cookie(name: "c\($0)") }
        await #expect(throws: SourceDomainError.self) { try await session.receive(tooMany) }
        #expect(try await session.headers(for: URL(string: origin)!)["Cookie"] == "session=secret")
    }
    @Test func browserCookieRoundTripPreservesHTTPOnlySecureAndExpiry() throws {
        // Keep this expiry within the platform cookie lifetime limit.
        let expiry = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) + 86_400)
        let value = try cookie(expires: expiry)
        let browser = try #require(value.browserCookie())
        #expect(browser.isHTTPOnly && browser.isSecure)
        let restored = try #require(SourceCredentialCookie.capture(browser, origin: origin))
        #expect(restored.origin == value.origin)
        #expect(restored.name == value.name && restored.value == value.value && restored.path == value.path)
        #expect(restored.secure == value.secure && restored.httpOnly == value.httpOnly)
        #expect(restored.expiresAt == expiry)
        #expect(try SourceCredentialCookie.capture(browser, origin: other) == nil)
    }
    @Test func parentRevocationRejectsDatabaseStateAndBookCommits() async throws {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("credential-gate-\(UUID().uuidString)/native.sqlite3")
        let archive = try SourceArchive(url: f), scope = try scope(), parent = SourceCommitGate()
        let child = SourceCommitGate(parent: parent)
        parent.invalidate()
        await #expect(throws: SourceDomainError.self) { try await archive.setState(scope: scope, key: "late", value: .bool(true), gate: child) }
        let book = SourceSavedBook(key: try .init(scope: scope, bookID: "book"), details: .init(ref: .init(id: "book"), title: "Private"))
        await #expect(throws: SourceDomainError.self) { try await archive.saveBook(book, gate: child) }
        #expect(try await archive.state(scope: scope, key: "late") == nil)
        #expect(try await archive.books(scope: scope).isEmpty)
    }
    @Test func accountSelectionPersistsWithoutMixingConfigurationsOrBooks() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("accounts-\(UUID().uuidString)/native.sqlite3")
        let archive = try SourceArchive(url: url)
        let install = try SourceInstallation(publisherID: "fixture.accounts", name: "Accounts", version: "1", source: "source", origins: [origin])
        try await archive.saveInstallation(install)
        #expect(try await archive.accountSettings(installationID: install.id).selected == .guest)
        let account = try await archive.addAccount(name: " Personal ", installationID: install.id)
        #expect(account.name == "Personal" && UUID(uuidString: account.id) != nil)
        let guest = try SourceScope(installationID: install.id)
        let personal = try SourceScope(installationID: install.id, accountID: account.id)
        try await archive.saveConfiguration(.object(["theme": .string("guest")]), scope: guest)
        try await archive.saveConfiguration(.object(["theme": .string("private")]), scope: personal)
        try await archive.selectAccount(account.id, installationID: install.id)
        let reopened = try SourceArchive(url: url)
        #expect(try await reopened.accountSettings(installationID: install.id).selected == account)
        #expect(try await reopened.configuration(scope: guest) != reopened.configuration(scope: personal))
        await #expect(throws: SourceDomainError.self) { try await reopened.selectAccount("missing", installationID: install.id) }
        #expect(try await reopened.accountSettings(installationID: install.id).selected == account)
        #expect(throws: SourceDomainError.self) { try SourceAccount(name: "\n") }
    }
}
