import Foundation
import LegadoCore

/// Synthetic-only CI executable. Never linked into the App or allowed to inspect its default store.
@main struct LegacyMigrationRecoveryProbe {
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count == 3, ["seed", "prepare", "inspect", "adopt", "inspect-adoption"].contains(args[1]) else {
            throw SourceDomainError(.invalidInput, "Usage: LegacyMigrationRecoveryProbe seed|prepare|inspect /synthetic/directory")
        }
        let root = URL(fileURLWithPath: args[2]).standardizedFileURL
        guard root.lastPathComponent.hasPrefix("legacy-migration-process-"), root.path != LegadoDatabase.defaultURL().deletingLastPathComponent().path else {
            throw SourceDomainError(.invalidInput, "A dedicated synthetic directory is required")
        }
        let original = root.appendingPathComponent("legacy.sqlite3"), cache = root.appendingPathComponent("chapters")
        let snapshot = root.appendingPathComponent("snapshot"), mapping = root.appendingPathComponent("mapping")
        if args[1] == "seed" {
            guard !FileManager.default.fileExists(atPath: original.path) else { throw CocoaError(.fileWriteFileExists) }
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let database = try LegadoDatabase(url: original)
            let source = BookSource(bookSourceUrl: "https://recovery.invalid", bookSourceName: "Synthetic recovery")
            try await database.replaceBookSources([source])
            var book = Book(bookUrl: "https://recovery.invalid/book?edition=a", name: "Recovery", origin: source.id)
            book.durChapterIndex = 1; book.durChapterPos = 4; book.durChapterTime = 1000
            var config = BookReadConfig(); config.useReplaceRule = false; book.readConfig = config
            try await database.replaceBooks([book])
            let chapters = (0..<2).map { BookChapter(url: "https://recovery.invalid/chapter/\($0)", title: "Repeated", bookUrl: book.id, index: $0) }
            try await database.replaceChapters(chapters, bookURL: book.id)
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            for chapter in chapters {
                let value = CachedChapterContent(bookURL: book.id, chapterURL: chapter.url, content: "The preserved chapter \(chapter.index)", sourceID: source.id)
                try SourceCoding.encode(value).write(to: cache.appendingPathComponent("\(chapter.index).json"))
            }
            try emit(["seeded": true]); return
        }
        guard FileManager.default.fileExists(atPath: original.path) else { throw CocoaError(.fileNoSuchFile) }
        if args[1] == "prepare" {
            _ = try LegacyMigrationSnapshot.capture(databaseURL: original, externalDirectories: ["chapters": cache], destination: snapshot) { point in
                try checkpoint("snapshot." + point.rawValue, root: root)
            }
            _ = try await LegacyMigrationMapper.prepare(snapshotAt: snapshot, destination: mapping) { point in
                try checkpoint("mapping." + point.rawValue, root: root)
            }
        }
        if args[1] == "adopt" || args[1] == "inspect-adoption" {
            let archive = try SourceArchive(url: root.appendingPathComponent("active.sqlite3"))
            let report = try LegacyMigrationMapper.verify(at: mapping, snapshotAt: snapshot)
            if args[1] == "adopt" {
                _ = try await LegacyMigrationMapper.adopt(at: mapping, snapshotAt: snapshot, into: archive) { phase in
                    try checkpoint("adoption." + phase, root: root)
                }
                try checkpoint("adoption.committed", root: root)
            }
            try emit(["installed": try await archive.installations().count,
                      "cachedChapters": try await archive.chapterStorageUsage().offlineCount,
                      "receipt": try await archive.migrationReceipt(report.snapshotID) != nil])
            return
        }
        var summary: [String: Any] = ["snapshotReady": false, "mappingReady": false]
        if FileManager.default.fileExists(atPath: snapshot.appendingPathComponent("manifest.json").path) {
            let value = try LegacyMigrationSnapshot.verify(at: snapshot)
            summary["snapshotReady"] = true; summary["originalBooks"] = value.tables["books"]
        }
        if FileManager.default.fileExists(atPath: mapping.appendingPathComponent("report.json").path) {
            let value = try LegacyMigrationMapper.verify(at: mapping, snapshotAt: snapshot)
            summary["mappingReady"] = true; summary["books"] = value.books.count; summary["cachedChapters"] = value.cacheFilesMapped
            summary["progressMapped"] = value.books.allSatisfy(\.progressMapped)
            summary["reportDigest"] = SourceCoding.digest(try SourceCoding.encode(value))
            let preview = try SourceArchive(url: LegacyMigrationMapper.makePreview(at: mapping, snapshotAt: snapshot))
            let book = value.books[0]
            summary["offlineChapters"] = try await preview.chapterStorageUsage().offlineCount
            summary["position"] = try await preview.anchor(book: book.key)?.offsetUTF16
        }
        try emit(summary)
    }
    private static func emit(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        try FileHandle.standardOutput.write(contentsOf: data + Data([10]))
    }
    private static func checkpoint(_ phase: String, root: URL) throws {
        let environment = ProcessInfo.processInfo.environment
        if environment["LEGADO_MIGRATION_ENOSPC_AT"] == phase {
            throw NSError(domain: NSPOSIXErrorDomain, code: 28, userInfo: [NSLocalizedDescriptionKey: "Synthetic ENOSPC fault"])
        }
        if environment["LEGADO_MIGRATION_STOP_AT"] == phase {
            try Data(phase.utf8).write(to: root.appendingPathComponent("reached-checkpoint"), options: .atomic)
            // The Python controller observes this exact phase and sends SIGKILL to this process.
            while true { Thread.sleep(forTimeInterval: 0.05) }
        }
    }
}
