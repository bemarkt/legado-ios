import Foundation
import Testing
@testable import LegadoCore

struct LegadoScopedStateTests {
    private let sourceID = "https://fixture.invalid"
    private func setup() async throws -> (SourceArchive, SourceInstallation, URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-state-\(UUID().uuidString)/archive.sqlite")
        let archive = try SourceArchive(url: url)
        let installation = try SourceInstallation(publisherID: "test.scoped", name: "Scoped", version: "1", source: "fixture", origins: [sourceID])
        try await archive.saveInstallation(installation)
        return (archive, installation, url)
    }
    private func identity(_ installation: SourceInstallation, account: String = "guest", revision: String? = nil) throws -> SourceExecutionIdentity {
        try .init(scope: .init(installationID: installation.id, accountID: account), sourceDigest: installation.digest,
                  configuration: .object([:]), credentialRevision: revision)
    }
    private func key(_ key: String) -> String { "legado.source." + SourceCoding.digest(Data(key.utf8)) }

    @Test func ordinaryStateSurvivesRestartAndNeverUsesSharedLegacyStores() async throws {
        let (archive, installation, url) = try await setup()
        let identity = try identity(installation), control = JavaScriptExecutionControl()
        let state = try LegadoScopedSourceState(sourceID: sourceID, identity: identity, archive: archive, credentials: nil, control: control)
        try await RuleExecutionWorker.run { try state.put(sourceID: sourceID, key: "cursor", value: "persisted") }
        control.cancel()
        let reopened = try SourceArchive(url: url)
        let restored = try LegadoScopedSourceState(sourceID: sourceID, identity: identity, archive: reopened,
                                                  credentials: nil, control: .init())
        #expect(try await RuleExecutionWorker.run { try restored.get(sourceID: sourceID, key: "cursor") } == "persisted")
        await #expect(throws: SourceDomainError.self) {
            try await RuleExecutionWorker.run { try restored.put(sourceID: "https://foreign.invalid", key: "cursor", value: "bad") }
        }
        await #expect(throws: SourceDomainError.self) {
            try await RuleExecutionWorker.run { try restored.put(sourceID: sourceID, key: "loginInfo", value: "secret") }
        }
        #expect(try await RuleExecutionWorker.run { try restored.get(sourceID: sourceID, key: "loginInfo") }.isEmpty)
    }

    @Test func loginValuesAreSecureScopedPersistedAndRevocable() async throws {
        let (archive, installation, _) = try await setup()
        let account = try await archive.addAccount(name: "Alice", installationID: installation.id)
        try await archive.selectAccount(account.id, installationID: installation.id)
        let scope = try SourceScope(installationID: installation.id, accountID: account.id)
        let persistence = MemorySourceCredentials(), vault = SourceCredentialVault(persistence: persistence)
        let session = try await vault.session(scope: scope, allowedOrigins: [sourceID])
        let control = JavaScriptExecutionControl(gate: session.commitGate)
        let identity = try identity(installation, account: account.id, revision: session.revision)
        let state = try LegadoScopedSourceState(sourceID: sourceID, identity: identity, archive: archive, credentials: session, control: control)
        try await RuleExecutionWorker.run {
            try state.put(sourceID: sourceID, key: "loginInfo", value: "secret-login")
            try state.put(sourceID: sourceID, key: "loginHeader", value: #"{"Authorization":"Bearer secret"}"#)
        }
        #expect(try await archive.state(scope: scope, key: key("loginInfo")) == nil)
        #expect(try await archive.state(scope: scope, key: key("loginHeader")) == nil)
        let reopened = SourceCredentialVault(persistence: persistence)
        let resumed = try await reopened.session(scope: scope, allowedOrigins: [sourceID])
        #expect(try await resumed.legacyValue(key: "loginInfo") == "secret-login")
        #expect(try await RuleExecutionWorker.run { try state.loginHeaders(sourceID: sourceID) } == ["Authorization": "Bearer secret"])
        let other = try await vault.session(scope: .init(installationID: installation.id, accountID: "another"), allowedOrigins: [sourceID])
        #expect(try await other.legacyValue(key: "loginInfo").isEmpty)
        try await vault.clear(scope: scope)
        await #expect(throws: SourceDomainError.self) {
            try await RuleExecutionWorker.run { try state.put(sourceID: sourceID, key: "loginInfo", value: "late") }
        }
        let fresh = try await vault.session(scope: scope, allowedOrigins: [sourceID])
        #expect(try await fresh.legacyValue(key: "loginInfo").isEmpty)
    }

    @Test func snapshotAndCancellationAreCheckedInsideStateWrites() async throws {
        let (archive, installation, _) = try await setup()
        let identity = try identity(installation), control = JavaScriptExecutionControl()
        let state = try LegadoScopedSourceState(sourceID: sourceID, identity: identity, archive: archive, credentials: nil, control: control)
        try await RuleExecutionWorker.run { try state.put(sourceID: sourceID, key: "value", value: "original") }
        try await archive.saveConfiguration(.object(["mode": .string("changed")]), scope: identity.scope)
        await #expect(throws: SourceDomainError.self) {
            try await RuleExecutionWorker.run { try state.put(sourceID: sourceID, key: "value", value: "stale") }
        }
        #expect(try await archive.state(scope: identity.scope, key: key("value"))?.value == .string("original"))
        control.cancel()
        await #expect(throws: CancellationError.self) {
            try await RuleExecutionWorker.run { try state.put(sourceID: sourceID, key: "value", value: "cancelled") }
        }
        #expect(try await archive.state(scope: identity.scope, key: key("value"))?.value == .string("original"))
    }

    @Test func accountSelectionAndSourceUpdateRejectOldDatabaseWrites() async throws {
        let (archive, installation, _) = try await setup()
        let originalIdentity = try identity(installation)
        let state = try LegadoScopedSourceState(sourceID: sourceID, identity: originalIdentity, archive: archive, credentials: nil, control: .init())
        let account = try await archive.addAccount(name: "Other", installationID: installation.id)
        try await archive.selectAccount(account.id, installationID: installation.id)
        await #expect(throws: SourceDomainError.self) {
            try await RuleExecutionWorker.run { try state.put(sourceID: sourceID, key: "late", value: "value") }
        }
        try await archive.selectAccount("guest", installationID: installation.id)
        let replacement = try SourceInstallation(id: installation.id, publisherID: installation.publisherID,
            name: installation.name, version: "2", source: "updated", origins: [sourceID])
        try await archive.saveInstallation(replacement, replacing: installation.digest)
        await #expect(throws: SourceDomainError.self) {
            try await RuleExecutionWorker.run { try state.put(sourceID: sourceID, key: "late", value: "value") }
        }
        #expect(try await archive.state(scope: originalIdentity.scope, key: key("late")) == nil)
    }

    @Test func credentialGateMustBelongToTheExactSession() async throws {
        let (archive, installation, _) = try await setup()
        let vault = SourceCredentialVault(persistence: MemorySourceCredentials())
        let session = try await vault.session(scope: .init(installationID: installation.id, accountID: "alice"), allowedOrigins: [sourceID])
        let identity = try identity(installation, account: "alice", revision: session.revision)
        #expect(throws: SourceDomainError.self) {
            try LegadoScopedSourceState(sourceID: sourceID, identity: identity, archive: archive, credentials: session, control: .init())
        }
        await #expect(throws: SourceDomainError.self) {
            try await session.setLegacyValue("secret", key: "loginInfo", gate: SourceCommitGate())
        }
    }
}
