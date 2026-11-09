import Foundation
import LegadoCore

/// CI helper. Never linked into the iOS App, never opens a user's default database.
@main struct SourceRecoveryProbe {
    private struct Summary: Encodable {
        let active: String
        let version: String
        let history: [String]
        let configurations: [String: SourceJSON]
        let selected: String
        let websiteState: [String: SourceJSON]
        let books: [String: [String]]
    }
    private static func emit<T: Encodable>(_ value: T) throws {
        try FileHandle.standardOutput.write(contentsOf: SourceCoding.encode(value) + Data([10]))
    }
    private static func version(_ number: Int, id: UUID) throws -> SourceInstallation {
        // A near-limit source forces history pages to spill to WAL before the transaction commits.
        let source = "// Synthetic recovery source \(number)\n" + String(repeating: "x", count: 1_900_000)
        return try .init(id: id, publisherID: "org.example.process-recovery", name: "Recovery fixture", version: String(number),
                         source: source, origins: ["https://example.org"])
    }
    private static func summary(_ archive: SourceArchive) async throws -> Summary {
        guard let installation = try await archive.installations().first else { throw CocoaError(.fileReadCorruptFile) }
        let settings = try await archive.accountSettings(installationID: installation.id)
        var state: [String: SourceJSON] = [:], books: [String: [String]] = [:]
        for account in settings.accounts {
            let scope = try SourceScope(installationID: installation.id, accountID: account.id)
            state[account.id] = try await archive.state(scope: scope, key: "kept-state")?.value
            books[account.id] = try await archive.books(scope: scope).map(\.details.title)
        }
        let history = try await archive.installationHistory(installation.id).map(\.digest)
        let configurations = try await archive.accountConfigurations(installationID: installation.id)
        return Summary(active: installation.digest, version: installation.version, history: history,
            configurations: configurations, selected: settings.selectedID, websiteState: state, books: books)
    }
    static func main() async throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 3, ["seed", "update", "inspect"].contains(arguments[1]) else {
            throw SourceDomainError(.invalidInput, "Usage: SourceRecoveryProbe seed|update|inspect /absolute/path/native.sqlite3")
        }
        let database = URL(fileURLWithPath: arguments[2]).standardizedFileURL
        guard database.lastPathComponent == "native.sqlite3", database.path != SourceArchive.defaultURL().path else {
            throw SourceDomainError(.invalidInput, "A dedicated synthetic database is required")
        }
        if arguments[1] == "seed" {
            guard !FileManager.default.fileExists(atPath: database.path) else { throw CocoaError(.fileWriteFileExists) }
        } else {
            guard FileManager.default.fileExists(atPath: database.path) else { throw CocoaError(.fileNoSuchFile) }
        }
        let archive = try SourceArchive(url: database)
        if arguments[1] == "seed" {
            let id = UUID()
            var current = try version(1, id: id)
            try await archive.saveInstallation(current)
            for number in 2...9 {
                let next = try version(number, id: id)
                try await archive.saveInstallation(next, replacing: current.digest)
                current = next
            }
            let personal = try await archive.addAccount(name: "Fixture reader", installationID: id)
            try await archive.selectAccount(personal.id, installationID: id)
            for account in try await archive.accountSettings(installationID: id).accounts {
                let scope = try SourceScope(installationID: id, accountID: account.id)
                try await archive.saveConfiguration(.object(["fixture": .string(account.id)]), scope: scope)
                _ = try await archive.setState(scope: scope, key: "kept-state", value: .string(account.id))
                try await archive.saveBook(.init(key: SourceBookKey(scope: scope, bookID: "kept"), details: .init(ref: .init(id: "kept"), title: account.id)))
            }
            try emit(await summary(archive))
        } else if arguments[1] == "inspect" {
            try emit(await summary(archive))
        } else {
            guard let current = try await archive.installations().first else { throw CocoaError(.fileReadCorruptFile) }
            let reviewed = try await archive.accountConfigurations(installationID: current.id)
            let candidate = try version(10, id: current.id)
            try emit(["phase": "ready", "candidate": candidate.digest])
            guard readLine() == "go" else { throw SourceDomainError(.cancelled, "Probe was not released") }
            try await archive.saveInstallation(candidate, replacing: current.digest,
                reviewedConfigurations: reviewed, resetAllAccountConfigurations: true)
            try emit(["phase": "committed"])
            _ = readLine() // Remain alive so the parent can kill exactly after a completed commit.
        }
    }
}
