import Foundation
import SQLite3
import Testing
@testable import LegadoCore

struct LegacyMigrationSnapshotTests {
    private struct Interrupted: Error {}
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-snapshot-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    private func fixture(_ root: URL) async throws -> (LegadoDatabase, URL) {
        let url = root.appendingPathComponent("legacy.sqlite3"), database = try LegadoDatabase(url: url)
        var source = BookSource(bookSourceUrl: "https://fixture.invalid", bookSourceName: "Fixture")
        source.additionalFields["unknown"] = .object(["keep": .bool(true)])
        try await database.replaceBookSources([source])
        try await database.replaceBooks([.init(bookUrl: "https://fixture.invalid/book?q=1", name: "Book", origin: source.id)])
        return (database, url)
    }
    private func sql(_ sql: String, at url: URL) throws {
        var connection: OpaquePointer?
        guard sqlite3_open(url.path, &connection) == SQLITE_OK, let connection else { throw SourceDomainError(.unavailable, "Fixture DB failed") }
        defer { sqlite3_close(connection) }
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else { throw SourceDomainError(.invalidData, "Fixture SQL failed") }
    }

    @Test func inventoryUsesRelativeFileNamesForCanonicalAndAliasRoots() throws {
        let root = try root(), directory = root.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("file".utf8).write(to: directory.appendingPathComponent("legacy.sqlite3"))
        #expect(try LegacyMigrationSnapshot.fileInventory(directory).keys.sorted() == ["legacy.sqlite3"])
        #expect(try LegacyMigrationSnapshot.fileInventory(directory.resolvingSymlinksInPath()).keys.sorted() == ["legacy.sqlite3"])
    }

    @Test func sqliteBackupIncludesWALAndAllTablesAndLeavesOriginalBytesUntouched() async throws {
        let root = try root(), (database, original) = try await fixture(root)
        let external = root.appendingPathComponent("chapters"), nested = external.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("kept content 😀".utf8).write(to: nested.appendingPathComponent("chapter.json"))
        let before = try Data(contentsOf: original), wal = try Data(contentsOf: URL(fileURLWithPath: original.path + "-wal"))
        #expect(!wal.isEmpty)
        let destination = root.appendingPathComponent("snapshot"), defaults = Data("private-defaults".utf8)
        let manifest = try LegacyMigrationSnapshot.capture(databaseURL: original,
            externalDirectories: ["chapters": external, "missing": root.appendingPathComponent("absent")], defaults: defaults, destination: destination)
        let copyURL = LegacyMigrationSnapshot.databaseURL(at: destination, manifest: manifest)
        #expect(!FileManager.default.fileExists(atPath: copyURL.path + "-wal"))
        #expect(!FileManager.default.fileExists(atPath: copyURL.path + "-shm"))
        #expect(manifest.schemaVersion == 7); #expect(manifest.tables.count == 21)
        #expect(manifest.tables["books"] == 1); #expect(manifest.tables["book_sources"] == 1)
        #expect(manifest.missingExternalDirectories == ["missing"])
        #expect(try LegacyMigrationSnapshot.verify(at: destination) == manifest)
        #expect(try Data(contentsOf: original) == before)
        #expect(try Data(contentsOf: URL(fileURLWithPath: original.path + "-wal")) == wal)
        let copied = try LegadoDatabase(url: LegacyMigrationSnapshot.databaseURL(at: destination, manifest: manifest))
        let originalBooks = try await database.loadBooks(), originalSources = try await database.loadBookSources()
        #expect(try await copied.loadBooks() == originalBooks)
        #expect(try await copied.loadBookSources() == originalSources)
    }

    @Test(arguments: [LegacyMigrationSnapshot.Checkpoint.databaseCopied, .externalFileCopied, .beforePublish, .published])
    func interruptedSnapshotIsEitherUnpublishedOrCompleteAndRetriesSafely(at point: LegacyMigrationSnapshot.Checkpoint) async throws {
        let root = try root(), (database, original) = try await fixture(root)
        let external = root.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try Data("one".utf8).write(to: external.appendingPathComponent("a"))
        let destination = root.appendingPathComponent("snapshot")
        #expect(throws: Interrupted.self) {
            try LegacyMigrationSnapshot.capture(databaseURL: original, externalDirectories: ["data": external], destination: destination) {
                if $0 == point { throw Interrupted() }
            }
        }
        #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("manifest.json").path) == (point == .published))
        let result = try LegacyMigrationSnapshot.capture(databaseURL: original, externalDirectories: ["data": external], destination: destination)
        #expect(try LegacyMigrationSnapshot.verify(at: destination) == result)
        #expect(result.tables["books"] == 1)
        let again = try LegacyMigrationSnapshot.capture(databaseURL: original, externalDirectories: ["data": external], destination: destination)
        #expect(again == result)
        #expect(try await database.loadBooks().count == 1)
    }

    @Test func changingSourceDatabaseOrExternalFileNeverPublishesMixedSnapshot() async throws {
        let root = try root(), (database, original) = try await fixture(root)
        let destination = root.appendingPathComponent("snapshot")
        #expect(throws: SourceDomainError.self) {
            try LegacyMigrationSnapshot.capture(databaseURL: original, destination: destination) { point in
                if point == .databaseCopied { try sql("INSERT INTO legacy_imports(key) VALUES('concurrent')", at: original) }
            }
        }
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("manifest.json").path))
        let retry = try LegacyMigrationSnapshot.capture(databaseURL: original, destination: destination)
        #expect(retry.tables["legacy_imports"] == 1)
        let external = root.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        let file = external.appendingPathComponent("changing")
        try Data("original".utf8).write(to: file)
        let other = root.appendingPathComponent("second-snapshot")
        #expect(throws: SourceDomainError.self) {
            try LegacyMigrationSnapshot.capture(databaseURL: original, externalDirectories: ["data": external], destination: other) { point in
                if point == .externalFileCopied { try Data("changed and longer".utf8).write(to: file) }
            }
        }
        #expect(!FileManager.default.fileExists(atPath: other.appendingPathComponent("manifest.json").path))
        #expect(try await database.loadBooks().count == 1)
    }

    @Test func capacityCorruptionTamperingAndSymlinksLeaveSourceIntact() async throws {
        let root = try root(), (database, original) = try await fixture(root)
        #expect(throws: SourceDomainError.self) {
            try LegacyMigrationSnapshot.capture(databaseURL: original, destination: root.appendingPathComponent("small"), maximumBytes: 1)
        }
        let corrupt = root.appendingPathComponent("corrupt.sqlite")
        try Data("not a database".utf8).write(to: corrupt)
        #expect(throws: SourceDomainError.self) {
            try LegacyMigrationSnapshot.capture(databaseURL: corrupt, destination: root.appendingPathComponent("corrupt-copy"))
        }
        let destination = root.appendingPathComponent("snapshot")
        let manifest = try LegacyMigrationSnapshot.capture(databaseURL: original, destination: destination)
        try Data("extra".utf8).write(to: destination.appendingPathComponent(manifest.attempt).appendingPathComponent("unexpected"))
        #expect(throws: SourceDomainError.self) { try LegacyMigrationSnapshot.verify(at: destination) }
        let external = root.appendingPathComponent("links")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: external.appendingPathComponent("outside"), withDestinationURL: original)
        #expect(throws: SourceDomainError.self) {
            try LegacyMigrationSnapshot.capture(databaseURL: original, externalDirectories: ["data": external], destination: root.appendingPathComponent("links-copy"))
        }
        #expect(try await database.loadBooks().count == 1)
    }

    @Test func directoryAliasesAndUnicodeNamesKeepExactRelativePaths() async throws {
        let root = try root(), (database, original) = try await fixture(root)
        let external = root.appendingPathComponent("资料 目录")
        let nested = external.appendingPathComponent("章节/第一章 📖.json")
        try FileManager.default.createDirectory(at: nested.deletingLastPathComponent(), withIntermediateDirectories: true)
        let contents = Data("离线正文".utf8)
        try contents.write(to: nested)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: external)
        let destination = root.appendingPathComponent("snapshot")
        let manifest = try LegacyMigrationSnapshot.capture(databaseURL: original, externalDirectories: ["chapters": alias], destination: destination)
        let relative = "external/chapters/章节/第一章 📖.json"
        #expect(manifest.files.contains { $0.relativePath == relative })
        #expect(try Data(contentsOf: destination.appendingPathComponent(manifest.attempt).appendingPathComponent(relative)) == contents)
        #expect(try LegacyMigrationSnapshot.verify(at: destination) == manifest)
        #expect(try await database.loadBooks().count == 1)
    }

    @Test func explicitConfigurationFilesAreVerifiedAndChangesBeforePublicationRejected() async throws {
        let root = try root(), (database, original) = try await fixture(root)
        let rules = root.appendingPathComponent("rules.json")
        try Data("[]".utf8).write(to: rules)
        let files = ["replace-rules": rules, "missing": root.appendingPathComponent("absent.json")]
        let destination = root.appendingPathComponent("snapshot")
        #expect(throws: SourceDomainError.self) {
            try LegacyMigrationSnapshot.capture(databaseURL: original, externalFiles: files, destination: destination) { point in
                if point == .beforePublish { try Data("[{}]".utf8).write(to: rules) }
            }
        }
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("manifest.json").path))
        let manifest = try LegacyMigrationSnapshot.capture(databaseURL: original, externalFiles: files, destination: destination)
        #expect(manifest.missingExternalFiles == ["missing"])
        #expect(manifest.files.contains { $0.relativePath == "files/replace-rules" })
        #expect(try LegacyMigrationSnapshot.verify(at: destination) == manifest)
        #expect(try await database.loadBooks().count == 1)
    }

    @Test func emptyHistoricalAndLargeDatabasesHaveVerifiedCounts() async throws {
        let root = try root(), emptyURL = root.appendingPathComponent("empty.sqlite")
        let empty = try LegadoDatabase(url: emptyURL)
        let emptySnapshot = try LegacyMigrationSnapshot.capture(databaseURL: emptyURL, destination: root.appendingPathComponent("empty-copy"))
        #expect(emptySnapshot.tables.count == 21); #expect(emptySnapshot.tables.values.allSatisfy { $0 == 0 })
        #expect(try await empty.loadBooks().isEmpty)
        let oldURL = root.appendingPathComponent("v1.sqlite")
        try sql("CREATE TABLE books(book_url TEXT PRIMARY KEY,payload BLOB); PRAGMA user_version=1;", at: oldURL)
        let old = try LegacyMigrationSnapshot.capture(databaseURL: oldURL, destination: root.appendingPathComponent("v1-copy"))
        #expect(old.schemaVersion == 1); #expect(old.tables == ["books": 0])
        let manyURL = root.appendingPathComponent("many.sqlite"), many = try LegadoDatabase(url: manyURL)
        try await many.replaceBooks((0..<2000).map { .init(bookUrl: "book-\($0)", name: "Book \($0)") })
        let large = try LegacyMigrationSnapshot.capture(databaseURL: manyURL, destination: root.appendingPathComponent("many-copy"))
        #expect(large.tables["books"] == 2000)
    }
}
