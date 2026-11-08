import Foundation
import SQLite3
import Testing
@testable import LegadoCore

@Suite("Chapter storage retention and capacity")
struct SourceChapterStorageTests {
    private struct Fixture {
        let url: URL
        let archive: SourceArchive
        let identity: SourceExecutionIdentity
        let book = SourceWire.SourceRef(id: "book")
    }
    private func fixture() throws -> Fixture {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("chapter-storage-\(UUID().uuidString)/native.sqlite3")
        return Fixture(url: url, archive: try SourceArchive(url: url), identity: try .init(scope: .init(installationID: UUID()),
            sourceDigest: String(repeating: "a", count: 64), configuration: .object([:])))
    }
    private func request(_ f: Fixture, _ id: String = "c0", retain: Bool = false, archive: SourceArchive? = nil) async throws -> SourceChapterRequest {
        let value = try await (archive ?? f.archive).prepareChapter(identity: f.identity, book: f.book, chapter: .init(id: id),
            expectedCatalog: nil, reload: true, retainOffline: retain, gate: .init())
        guard case .fetch(let request) = value else { throw SourceDomainError(.invalidData, "Expected fetch") }
        return request
    }
    private func chapter(_ request: SourceChapterRequest, text: String = "Stored text") throws -> SourceCachedChapter {
        let content = SourceWire.ChapterContent(body: .text(.init(text: text)))
        return .init(key: request.key, identity: request.identity, content: content, document: try ChapterNormalizer.normalize(content),
                     storedAt: Date(timeIntervalSince1970: 1_700_000_000), provenance: request.provenance)
    }
    @discardableResult
    private func save(_ f: Fixture, _ id: String = "c0", retain: Bool = false, text: String = "Stored text") async throws -> SourceCachedChapter {
        let request = try await request(f, id, retain: retain)
        let value = try chapter(request, text: text)
        try await f.archive.saveChapter(value, request: request, gate: .init())
        return value
    }
    private func exists(_ f: Fixture, _ id: String) async throws -> Bool {
        let key = try SourceChapterKey(book: .init(scope: f.identity.scope, bookID: f.book.id), chapterID: id)
        return try await f.archive.chapter(key, identity: f.identity, allowPreviousExtraction: true) != nil
    }

    @Test func readingCacheEvictsLeastRecentlyUsedAndKeepsCurrentChapter() async throws {
        let f = try fixture()
        let first = try await save(f)
        let bytes = try SourceCoding.encode(first).count
        try await f.archive.setChapterStorageLimits(.init(readingCacheBytes: bytes * 2 + 8))
        _ = try await save(f, "c1")
        #expect(try await exists(f, "c0")) // c0 is now more recent than c1.
        _ = try await save(f, "c2")
        #expect(!(try await exists(f, "c1")))
        #expect(try await exists(f, "c0"))
        #expect(try await exists(f, "c2"))
        let usage = try await f.archive.chapterStorageUsage()
        #expect(usage.readingCacheCount == 2 && usage.offlineCount == 0)
        #expect(usage.readingCacheBytes <= usage.limits.readingCacheBytes)
    }

    @Test func cachedChapterCanBeRetainedWithoutFetchingItAgain() async throws {
        let f = try fixture()
        let saved = try await save(f)
        let result = try await f.archive.prepareChapter(identity: f.identity, book: f.book, chapter: .init(id: "c0"),
            expectedCatalog: nil, reload: false, retainOffline: true, gate: .init())
        guard case .cached(let retained) = result else { Issue.record("Downloaded cache was not reused"); return }
        #expect(retained == saved)
        let usage = try await f.archive.chapterStorageUsage()
        #expect(usage.readingCacheCount == 0 && usage.offlineCount == 1)
        #expect(usage.offlineBytes == (try SourceCoding.encode(saved).count))
        _ = try await f.archive.removeChapterStorage(.readingCache)
        #expect(try await exists(f, "c0"))
    }

    @Test func retainedChaptersSurviveEvictionAndOrdinaryRefreshes() async throws {
        let f = try fixture()
        let retained = try await save(f, retain: true)
        let bytes = try SourceCoding.encode(retained).count
        try await f.archive.setChapterStorageLimits(.init(readingCacheBytes: bytes + 8))
        _ = try await save(f, "c1")
        _ = try await save(f, "c2")
        #expect(try await exists(f, "c0"))
        #expect(!(try await exists(f, "c1")))
        _ = try await save(f, "c0", text: "Corrected retained text")
        _ = try await f.archive.removeChapterStorage(.readingCache)
        #expect(try await exists(f, "c0"))
        #expect(try await f.archive.chapterStorageUsage().offlineCount == 1)
    }

    @Test func offlineQuotaRejectsGrowthWithoutLosingThePriorDownload() async throws {
        let f = try fixture()
        let original = try await save(f, retain: true)
        let before = try await f.archive.chapterStorageUsage()
        try await f.archive.setChapterStorageLimits(.init(offlineBytes: before.offlineBytes))
        await #expect(throws: SourceDomainError.self) { try await save(f, "c1", retain: true) }
        await #expect(throws: SourceDomainError.self) { try await save(f, retain: true, text: String(repeating: "Large", count: 100)) }
        #expect(try await f.archive.chapter(original.key, identity: f.identity, allowPreviousExtraction: true) == original)
        let after = try await f.archive.chapterStorageUsage()
        #expect(after.offlineBytes == before.offlineBytes && after.offlineCount == 1)
    }

    @Test func rejectedPromotionLeavesTheReadingCacheAvailable() async throws {
        let f = try fixture()
        let cached = try await save(f)
        try await f.archive.setChapterStorageLimits(.init(offlineBytes: 1))
        await #expect(throws: SourceDomainError.self) {
            try await f.archive.prepareChapter(identity: f.identity, book: f.book, chapter: .init(id: "c0"),
                expectedCatalog: nil, reload: false, retainOffline: true, gate: .init())
        }
        #expect(try await f.archive.chapter(cached.key, identity: f.identity, allowPreviousExtraction: true) == cached)
        #expect(try await f.archive.chapterStorageUsage().readingCacheCount == 1)
        #expect(try await f.archive.chapterStorageUsage().offlineCount == 0)
    }

    @Test func limitChangesAreAtomicAndPreservedAcrossConnections() async throws {
        let f = try fixture()
        let retained = try await save(f, retain: true)
        _ = try await save(f, "c1")
        let before = try await f.archive.chapterStorageUsage()
        await #expect(throws: SourceDomainError.self) { try await f.archive.setChapterStorageLimits(.init(readingCacheBytes: 1, offlineBytes: 1)) }
        #expect(try await f.archive.chapterStorageUsage() == before)
        try await f.archive.setChapterStorageLimits(.init(readingCacheBytes: 1, offlineBytes: before.offlineBytes))
        #expect(!(try await exists(f, "c1")))
        #expect(try await exists(f, "c0"))
        let other = try SourceArchive(url: f.url, initialChapterStorageLimits: .init(offlineBytes: 9_999_999))
        #expect(try await other.chapterStorageUsage().limits.offlineBytes == SourceCoding.encode(retained).count)
    }

    @Test func concurrentArchivesShareOneOfflineBudget() async throws {
        let f = try fixture()
        let sample = try await save(f)
        let bytes = try SourceCoding.encode(sample).count
        try await f.archive.setChapterStorageLimits(.init(offlineBytes: bytes + 8))
        let other = try SourceArchive(url: f.url)
        let first = try await request(f, "c1", retain: true)
        let second = try await request(f, "c2", retain: true, archive: other)
        func attempt(_ archive: SourceArchive, _ request: SourceChapterRequest) async throws -> Bool {
            do { try await archive.saveChapter(chapter(request), request: request, gate: .init()); return true }
            catch let error as SourceDomainError where error.code == .resourceLimit { return false }
        }
        async let a = attempt(f.archive, first)
        async let b = attempt(other, second)
        let results = try await [a, b]
        #expect(results.filter { $0 }.count == 1)
        let usage = try await f.archive.chapterStorageUsage()
        #expect(usage.offlineCount == 1 && usage.offlineBytes <= usage.limits.offlineBytes)
    }

    @Test func clearingInvalidatesEvenAnInitiallyEmptyPendingFetch() async throws {
        let f = try fixture()
        let pending = try await request(f)
        let other = try SourceArchive(url: f.url)
        #expect(try await other.removeChapterStorage(.readingCache) == 0)
        await #expect(throws: SourceDomainError.self) { try await f.archive.saveChapter(chapter(pending), request: pending, gate: .init()) }
        #expect(!(try await exists(f, "c0")))
        _ = try await save(f)
        #expect(try await exists(f, "c0"))
    }

    @Test func manualRemovalSeparatesCacheAndDownloadsAndKeepsBooks() async throws {
        let f = try fixture()
        let key = try SourceBookKey(scope: f.identity.scope, bookID: f.book.id)
        let book = SourceSavedBook(key: key, details: .init(ref: f.book, title: "Preserved book"))
        try await f.archive.saveBook(book)
        _ = try await save(f, retain: true)
        _ = try await save(f, "c1")
        #expect(try await f.archive.removeChapterStorage(.offlineDownloads) == 1)
        #expect(!(try await exists(f, "c0")))
        #expect(try await exists(f, "c1"))
        #expect(try await f.archive.books(scope: f.identity.scope) == [book])
        #expect(try await f.archive.removeChapterStorage(.readingCache) == 1)
        let usage = try await f.archive.chapterStorageUsage()
        #expect(usage.readingCacheCount == 0 && usage.offlineCount == 0)
        #expect(usage.readingCacheBytes == 0 && usage.offlineBytes == 0)
    }

    @Test func rolledBackWritesRestoreAccountingAndEvictedChapters() async throws {
        let f = try fixture()
        let original = try await save(f)
        let bytes = try SourceCoding.encode(original).count
        try await f.archive.setChapterStorageLimits(.init(readingCacheBytes: bytes + 8))
        let before = try await f.archive.chapterStorageUsage()
        let pending = try await request(f, "c1")
        let gate = SourceCommitGate(); gate.invalidate()
        await #expect(throws: SourceDomainError.self) { try await f.archive.saveChapter(chapter(pending), request: pending, gate: gate) }
        #expect(try await f.archive.chapterStorageUsage() == before)
        #expect(try await exists(f, "c0"))
        #expect(!(try await exists(f, "c1")))
    }

    @Test func versionTwoUpgradeRetainsAllExistingOfflineContent() async throws {
        let f = try fixture()
        let saved = try await save(f)
        try raw(f.url, """
            DROP TRIGGER chapter_record_insert;
            DROP TRIGGER chapter_record_update;
            DROP TRIGGER chapter_record_delete;
            DROP TABLE chapter_storage;
            DROP TABLE chapter_usage;
            PRAGMA user_version=2;
            """)
        let upgraded = try SourceArchive(url: f.url)
        let usage = try await upgraded.chapterStorageUsage()
        #expect(usage.offlineCount == 1 && usage.readingCacheCount == 0)
        #expect(usage.offlineBytes == (try SourceCoding.encode(saved).count))
        #expect(try await upgraded.removeChapterStorage(.readingCache) == 0)
        #expect(try await upgraded.chapter(saved.key, identity: f.identity, allowPreviousExtraction: true) == saved)
    }

    @Test func normalizationStillReadsPreservedRawContentWhenQuotaIsFull() async throws {
        let f = try fixture()
        let saved = try await save(f, retain: true, text: String(repeating: "Readable content. ", count: 200))
        var json = try #require(JSONSerialization.jsonObject(with: SourceCoding.encode(saved)) as? [String: Any])
        var document = try #require(json["document"] as? [String: Any])
        document["normalizationVersion"] = 0
        document["blocks"] = [["kind": "paragraph", "text": "Old", "marks": []]]
        json["document"] = document
        try raw(f.url, "UPDATE records SET payload=? WHERE namespace='chapter'", payload: JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]))
        let before = try await f.archive.chapterStorageUsage()
        try await f.archive.setChapterStorageLimits(.init(offlineBytes: before.offlineBytes))
        let restored = try await f.archive.chapter(saved.key, identity: f.identity, allowPreviousExtraction: true)
        #expect(restored?.document == saved.document)
        #expect(try await f.archive.chapterStorageUsage().offlineBytes == before.offlineBytes)
    }

    private func raw(_ url: URL, _ sql: String, payload: Data? = nil) throws {
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(url.path, &pointer, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let pointer else {
            throw SourceDomainError(.unavailable, "Cannot open fixture")
        }
        defer { sqlite3_close(pointer) }
        guard let payload else {
            guard sqlite3_exec(pointer, sql, nil, nil, nil) == SQLITE_OK else { throw SourceDomainError(.unavailable, "Fixture SQL failed") }
            return
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(pointer, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw SourceDomainError(.unavailable, "Fixture preparation failed") }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let bound = payload.withUnsafeBytes { sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32($0.count), transient) }
        guard bound == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else { throw SourceDomainError(.unavailable, "Fixture write failed") }
    }
}
