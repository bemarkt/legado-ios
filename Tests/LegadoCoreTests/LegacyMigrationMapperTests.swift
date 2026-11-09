import Foundation
import SQLite3
import Testing
@testable import LegadoCore

struct LegacyMigrationMapperTests {
    private struct Interrupted: Error {}
    private struct Fixture {
        let root: URL
        let database: LegadoDatabase
        let databaseURL: URL
        let snapshot: URL
        let destination: URL
        let source: BookSource
        let book: Book
        let chapters: [BookChapter]
        let cache: URL
    }
    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-map-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("original.sqlite3"), database = try LegadoDatabase(url: url)
        var source = BookSource(bookSourceUrl: "https://fixture.invalid", bookSourceName: "迁移示例")
        source.additionalFields["unknownField"] = .object(["preserve": .bool(true)])
        source.enabled = false; source.bookSourceGroup = "旧分组"
        try await database.replaceBookSources([source])
        var book = Book(bookUrl: "https://fixture.invalid/book?id=1&edition=a", name: "同名章节示例", author: "作者", origin: source.id)
        book.tocUrl = "https://fixture.invalid/toc?id=1"; book.durChapterIndex = 1; book.durChapterPos = 6; book.durChapterTime = 1000
        book.order = 3; book.group = 2
        var config = BookReadConfig(); config.useReplaceRule = false; book.readConfig = config
        try await database.replaceBooks([book, .init(bookUrl: "file:///Documents/local.txt", name: "本地书")])
        let chapters = (0..<2).map { BookChapter(url: "https://fixture.invalid/chapter?id=\($0)&edition=a", title: "重复标题", bookUrl: book.bookUrl, index: $0) }
        try await database.replaceChapters(chapters, bookURL: book.bookUrl)
        var mark = Bookmark(time: 1000, bookName: book.name, bookAuthor: book.author)
        mark.chapterIndex = 1; mark.chapterPosition = 6; mark.chapterName = "重复标题"; mark.bookText = "paragraph"; mark.content = "保留的笔记"
        try await database.replaceBookmarks([mark])
        let cache = root.appendingPathComponent("cache")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        for chapter in chapters {
            let content = CachedChapterContent(bookURL: book.bookUrl, chapterURL: chapter.url, title: chapter.title,
                content: "First paragraph chapter \(chapter.index) 😀", savedAt: 1000, sourceID: source.id)
            try SourceCoding.encode(content).write(to: cache.appendingPathComponent("chapter-\(chapter.index).json"))
        }
        try sql("INSERT INTO caches(key,value,deadline) VALUES('v_https://fixture.invalid_saved','kept',0),('loginHeader_https://fixture.invalid','secret-login-sentinel',0); INSERT INTO cookies(url,cookie) VALUES('https://fixture.invalid','secret-cookie-sentinel');", at: url)
        return .init(root: root, database: database, databaseURL: url, snapshot: root.appendingPathComponent("snapshot"), destination: root.appendingPathComponent("mapping"), source: source, book: book, chapters: chapters, cache: cache)
    }
    private func sql(_ text: String, at url: URL) throws {
        var pointer: OpaquePointer?
        guard sqlite3_open(url.path, &pointer) == SQLITE_OK, let pointer else { throw SourceDomainError(.unavailable, "fixture") }
        defer { sqlite3_close(pointer) }
        guard sqlite3_exec(pointer, text, nil, nil, nil) == SQLITE_OK else { throw SourceDomainError(.invalidData, "fixture SQL") }
    }
    private func capture(_ fixture: Fixture) throws {
        _ = try LegacyMigrationSnapshot.capture(databaseURL: fixture.databaseURL, externalDirectories: ["chapters": fixture.cache], destination: fixture.snapshot)
    }
    @Test func mapsExactReferencesOfflineTextProgressNotesAndPreservesUnknownData() async throws {
        let fixture = try await fixture(); try capture(fixture)
        let result = try await LegacyMigrationMapper.prepare(snapshotAt: fixture.snapshot, destination: fixture.destination)
        #expect(result.tables.count == 21); #expect(result.tables["books"]?.mapped == 1); #expect(result.tables["books"]?.retained == 1)
        #expect(result.tables["chapters"]?.mapped == 2); #expect(result.cacheFilesMapped == 2)
        #expect(result.sources[0].enabled == false); #expect(result.sources[0].group == "旧分组")
        #expect(result.sources[0].installation.source.contains("unknownField"))
        #expect(result.sources[0].scope.accountID != "guest")
        #expect(result.books[0].order == 3); #expect(result.books[0].group == 2); #expect(result.books[0].progressMapped)
        #expect(result.annotations[0].bookmark.content == "保留的笔记"); #expect(result.annotations[0].anchor?.offsetUTF16 == 6)
        #expect(result.records.contains { $0.reason == .reauthentication })
        let preview = try LegacyMigrationMapper.makePreview(at: fixture.destination, snapshotAt: fixture.snapshot)
        let archive = try SourceArchive(url: preview), source = result.sources[0], book = result.books[0]
        let catalog = try #require(try await archive.catalog(book: book.key))
        #expect(catalog.chapters.count == 2); #expect(catalog.chapters[0].ref.id != catalog.chapters[1].ref.id)
        #expect(catalog.chapters[1].ref.url == fixture.chapters[1].url)
        let anchor = try #require(try await archive.anchor(book: book.key))
        #expect(anchor.chapter.chapterID == catalog.chapters[1].ref.id)
        let stored = try #require(try await archive.chapter(anchor.chapter, identity: catalog.identity, allowPreviousExtraction: true))
        #expect(stored.document.plainText == "First paragraph chapter 1 😀")
        #expect(try await archive.chapterStorageUsage().offlineCount == 2)
        #expect(try await archive.state(scope: source.scope, key: "legado.source." + SourceCoding.digest(Data("saved".utf8)))?.value == .string("kept"))
        #expect(try await archive.books(scope: .init(installationID: source.id)).isEmpty)
        let reportBytes = try Data(contentsOf: fixture.destination.appendingPathComponent("report.json"))
        let draftBytes = try Data(contentsOf: LegacyMigrationMapper.archiveURL(at: fixture.destination, report: result))
        for secret in ["secret-login-sentinel", "secret-cookie-sentinel"] {
            #expect(reportBytes.range(of: Data(secret.utf8)) == nil); #expect(draftBytes.range(of: Data(secret.utf8)) == nil)
        }
        #expect(try LegacyMigrationMapper.verify(at: fixture.destination, snapshotAt: fixture.snapshot) == result)
        #expect(try await fixture.database.loadBooks().count == 2)
    }
    @Test(arguments: [LegacyMigrationMapper.Checkpoint.sourcesMapped, .booksMapped, .cachesMapped, .beforePublish, .published])
    func retriesAfterEveryCheckpointWithoutDuplicateBooksOrOverwritingOriginal(_ point: LegacyMigrationMapper.Checkpoint) async throws {
        let fixture = try await fixture(); try capture(fixture)
        await #expect(throws: Interrupted.self) {
            try await LegacyMigrationMapper.prepare(snapshotAt: fixture.snapshot, destination: fixture.destination) { if $0 == point { throw Interrupted() } }
        }
        #expect(FileManager.default.fileExists(atPath: fixture.destination.appendingPathComponent("report.json").path) == (point == .published))
        let result = try await LegacyMigrationMapper.prepare(snapshotAt: fixture.snapshot, destination: fixture.destination)
        let again = try await LegacyMigrationMapper.prepare(snapshotAt: fixture.snapshot, destination: fixture.destination)
        #expect(result == again); #expect(result.books.count == 1); #expect(result.annotations.count == 1)
        #expect(try await fixture.database.loadBooks().count == 2)
    }
    @Test func malformedRowsForeignAndDuplicateCachesRemainReviewable() async throws {
        let fixture = try await fixture()
        try sql("UPDATE chapters SET payload='broken-json' WHERE chapter_index=1", at: fixture.databaseURL)
        try capture(fixture)
        let result = try await LegacyMigrationMapper.prepare(snapshotAt: fixture.snapshot, destination: fixture.destination)
        #expect(result.books.isEmpty); #expect(result.tables["chapters"]?.needsReview == 1)
        #expect(result.tables["books"]?.needsReview == 1); #expect(result.annotations.first?.anchor == nil)
        #expect(result.cacheFilesRetained == 2)
        let other = try await self.fixture()
        try FileManager.default.copyItem(at: other.cache.appendingPathComponent("chapter-0.json"), to: other.cache.appendingPathComponent("duplicate.json"))
        let foreign = CachedChapterContent(bookURL: other.book.bookUrl, chapterURL: other.chapters[1].url, content: "foreign", sourceID: "https://other.invalid")
        try SourceCoding.encode(foreign).write(to: other.cache.appendingPathComponent("chapter-1.json"))
        try capture(other)
        let duplicates = try await LegacyMigrationMapper.prepare(snapshotAt: other.snapshot, destination: other.destination)
        #expect(duplicates.cacheFilesMapped == 0); #expect(duplicates.cacheFilesRetained == 3)
        #expect(duplicates.records.filter { $0.reason == .ambiguousCache }.count == 2)
        #expect(duplicates.records.contains { $0.reason == .foreignCache })
        #expect(duplicates.books.first?.progressMapped == false)
    }
    @Test func corruptDraftAndAlteredSnapshotAreRejectedBeforePreview() async throws {
        let fixture = try await fixture(); try capture(fixture)
        let report = try await LegacyMigrationMapper.prepare(snapshotAt: fixture.snapshot, destination: fixture.destination)
        let archive = LegacyMigrationMapper.archiveURL(at: fixture.destination, report: report)
        let file = try FileHandle(forWritingTo: archive); try file.seekToEnd(); try file.write(contentsOf: Data("corrupt".utf8)); try file.close()
        #expect(throws: SourceDomainError.self) { try LegacyMigrationMapper.makePreview(at: fixture.destination, snapshotAt: fixture.snapshot) }
        let other = try await self.fixture(); try capture(other)
        _ = try await LegacyMigrationMapper.prepare(snapshotAt: other.snapshot, destination: other.destination)
        let snapshot = try LegacyMigrationSnapshot.verify(at: other.snapshot)
        try Data("altered".utf8).write(to: other.snapshot.appendingPathComponent(snapshot.attempt).appendingPathComponent("external/chapters/chapter-0.json"))
        await #expect(throws: SourceDomainError.self) { try await LegacyMigrationMapper.prepare(snapshotAt: other.snapshot, destination: other.destination) }
    }
}
