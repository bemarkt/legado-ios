import Foundation
import SQLite3
import Testing
@testable import LegadoCore

@Suite("Source installation transaction recovery")
struct SourceInstallationRecoveryTests {
    private struct Fixture {
        let url: URL
        let archive: SourceArchive
        let previous: SourceInstallation
        let current: SourceInstallation
        let candidate: SourceInstallation
        let scopes: [SourceScope]
        let reviewed: [String: SourceJSON]
    }

    private func version(_ number: Int, id: UUID) throws -> SourceInstallation {
        try .init(id: id, publisherID: "org.example.recovery", name: "Recovery fixture", version: String(number),
                  source: "synthetic version \(number)", origins: ["https://example.org"],
                  originURL: "https://example.org/fixture.source.js", locallyModified: number > 1)
    }

    private func fixture() async throws -> Fixture {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("source-recovery-\(UUID().uuidString)/native.sqlite3")
        let archive = try SourceArchive(url: url), id = UUID()
        let previous = try version(1, id: id), current = try version(2, id: id), candidate = try version(3, id: id)
        try await archive.saveInstallation(previous)
        try await archive.saveInstallation(current, replacing: previous.digest)
        let first = try await archive.addAccount(name: "First reader", installationID: id)
        let second = try await archive.addAccount(name: "Second reader", installationID: id)
        let scopes = try ["guest", first.id, second.id].map { try SourceScope(installationID: id, accountID: $0) }
        try await archive.selectAccount(first.id, installationID: id)
        for scope in scopes {
            try await archive.saveConfiguration(.object(["theme": .string(scope.accountID)]), scope: scope)
            _ = try await archive.setState(scope: scope, key: "website-state", value: .string(scope.accountID))
            try await archive.saveBook(.init(key: SourceBookKey(scope: scope, bookID: "kept-book"),
                details: .init(ref: .init(id: "kept-book"), title: scope.accountID)))
        }
        return Fixture(url: url, archive: archive, previous: previous, current: current, candidate: candidate,
                       scopes: scopes, reviewed: try await archive.accountConfigurations(installationID: id))
    }

    private func sql(_ sql: String, at url: URL) throws {
        var connection: OpaquePointer?
        guard sqlite3_open(url.path, &connection) == SQLITE_OK, let connection else {
            if let connection { sqlite3_close(connection) }
            throw SourceDomainError(.unavailable, "Could not open the synthetic recovery database")
        }
        defer { sqlite3_close(connection) }
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else {
            throw SourceDomainError(.invalidData, "Could not configure the synthetic SQLite failure")
        }
    }

    private func injectFailure(namespace: String, action: String, at url: URL) throws {
        // All values are fixed test parameters. Both statement and transaction aborts must leave the API atomic.
        guard ["configuration", "installation-history", "installation"].contains(namespace),
              ["ABORT", "ROLLBACK"].contains(action) else { throw SourceDomainError(.invalidInput, "Invalid fault fixture") }
        let condition = namespace == "configuration"
            ? "AND (SELECT COUNT(*) FROM records WHERE namespace='configuration' AND payload=X'7B7D') >= 2" : ""
        for event in ["INSERT", "UPDATE"] {
            try sql("""
                CREATE TRIGGER fail_source_\(event.lowercased()) AFTER \(event) ON records
                WHEN NEW.namespace='\(namespace)' \(condition)
                BEGIN SELECT RAISE(\(action), 'Synthetic installation write failure'); END;
                """, at: url)
        }
    }

    private func removeFailure(at url: URL) throws {
        try sql("DROP TRIGGER fail_source_insert; DROP TRIGGER fail_source_update;", at: url)
    }

    private func assertAccountData(_ f: Fixture, in archive: SourceArchive) async throws {
        #expect(try await archive.accountSettings(installationID: f.current.id).selectedID == f.scopes[1].accountID)
        for scope in f.scopes {
            #expect(try await archive.state(scope: scope, key: "website-state")?.value == .string(scope.accountID))
            #expect(try await archive.books(scope: scope).map(\.details.title) == [scope.accountID])
        }
    }

    @Test(arguments: ["configuration", "installation-history", "installation"], ["ABORT", "ROLLBACK"])
    func failedWriteRollsBackEveryAccountAndHistory(namespace: String, action: String) async throws {
        let f = try await fixture()
        try injectFailure(namespace: namespace, action: action, at: f.url)
        await #expect(throws: SourceDomainError.self) {
            try await f.archive.saveInstallation(f.candidate, replacing: f.current.digest,
                reviewedConfigurations: f.reviewed, resetAllAccountConfigurations: true)
        }
        // Reopen before removing the trigger: recovery must not depend on a successful retry.
        let reopened = try SourceArchive(url: f.url)
        for archive in [f.archive, reopened] {
            #expect(try await archive.installation(f.current.id) == f.current)
            #expect(try await archive.installationHistory(f.current.id) == [f.previous])
            #expect(try await archive.accountConfigurations(installationID: f.current.id) == f.reviewed)
            try await assertAccountData(f, in: archive)
        }
        try removeFailure(at: f.url)
        try await reopened.saveInstallation(f.candidate, replacing: f.current.digest,
            reviewedConfigurations: f.reviewed, resetAllAccountConfigurations: true)
        let committed = try SourceArchive(url: f.url)
        #expect(try await committed.installation(f.current.id) == f.candidate)
        #expect(try await committed.installationHistory(f.current.id) == [f.current, f.previous])
        let configurations = try await committed.accountConfigurations(installationID: f.current.id)
        #expect(configurations.count == f.reviewed.count && configurations.values.allSatisfy { $0 == .object([:]) })
        try await assertAccountData(f, in: committed)
    }

    @Test func retryAfterFailureRequiresFreshAccountReview() async throws {
        let f = try await fixture()
        try injectFailure(namespace: "installation", action: "ABORT", at: f.url)
        await #expect(throws: SourceDomainError.self) {
            try await f.archive.saveInstallation(f.candidate, replacing: f.current.digest,
                reviewedConfigurations: f.reviewed, resetAllAccountConfigurations: true)
        }
        try removeFailure(at: f.url)
        let other = try SourceArchive(url: f.url)
        try await other.saveConfiguration(.object(["theme": .string("edited after failure")]), scope: f.scopes[2])
        let fresh = try await other.accountConfigurations(installationID: f.current.id)
        await #expect(throws: SourceDomainError.self) {
            try await f.archive.saveInstallation(f.candidate, replacing: f.current.digest,
                reviewedConfigurations: f.reviewed, resetAllAccountConfigurations: true)
        }
        #expect(try await other.installation(f.current.id) == f.current)
        #expect(try await other.installationHistory(f.current.id) == [f.previous])
        #expect(try await other.accountConfigurations(installationID: f.current.id) == fresh)
        try await f.archive.saveInstallation(f.candidate, replacing: f.current.digest, reviewedConfigurations: fresh)
        #expect(try await other.installation(f.current.id) == f.candidate)
        #expect(try await other.accountConfigurations(installationID: f.current.id) == fresh)
        try await assertAccountData(f, in: other)
    }

    @Test func historyEvictionAndRollbackPreserveCurrentAccountData() async throws {
        let f = try await fixture()
        var current = f.current
        for number in 3...11 {
            let candidate = try version(number, id: current.id)
            try await f.archive.saveInstallation(candidate, replacing: current.digest, reviewedConfigurations: f.reviewed)
            current = candidate
        }
        let history = try await f.archive.installationHistory(current.id)
        #expect(history.map(\.version) == (3...10).reversed().map(String.init))
        let restore = try #require(history.last)
        try injectFailure(namespace: "installation", action: "ROLLBACK", at: f.url)
        await #expect(throws: SourceDomainError.self) {
            try await f.archive.saveInstallation(restore, replacing: current.digest, reviewedConfigurations: f.reviewed)
        }
        let reopened = try SourceArchive(url: f.url)
        #expect(try await reopened.installation(current.id) == current)
        #expect(try await reopened.installationHistory(current.id) == history)
        try removeFailure(at: f.url)
        try await reopened.saveInstallation(restore, replacing: current.digest, reviewedConfigurations: f.reviewed)
        let restored = try SourceArchive(url: f.url)
        #expect(try await restored.installation(current.id) == restore)
        #expect(try await restored.installationHistory(current.id) == Array(([current] + history).prefix(8)))
        #expect(try await restored.accountConfigurations(installationID: current.id) == f.reviewed)
        try await assertAccountData(f, in: restored)
    }
}
