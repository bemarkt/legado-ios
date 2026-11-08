import Foundation
import SQLite3
import Testing
@testable import LegadoCore

@Suite("Bounded catalog indexes and migration")
struct SourceCatalogIndexTests {
    private struct Fixture {
        let url: URL
        let archive: SourceArchive
        let identity: SourceExecutionIdentity
        func key(_ id: String = "book") throws -> SourceBookKey { try .init(scope: identity.scope, bookID: id) }
        func catalog(_ id: String = "book", count: Int = 3, revision: String = "r1") -> SourceCatalog {
            .init(identity: identity, book: .init(id: id),
                  chapters: (0..<count).map { .init(ref: .init(id: "c\($0)"), title: "Chapter \($0)") }, revision: revision)
        }
    }
    private func fixture(limits: SourceCatalogCacheLimits = .init()) throws -> Fixture {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-index-\(UUID().uuidString)/native.sqlite3")
        let archive = try SourceArchive(url: url, catalogCacheLimits: limits)
        let identity = try SourceExecutionIdentity(scope: .init(installationID: UUID()), sourceDigest: String(repeating: "a", count: 64), configuration: .object([:]))
        return Fixture(url: url, archive: archive, identity: identity)
    }
    private func prepare(_ f: Fixture, catalog: SourceCatalog, chapter: Int = 0) async throws -> SourceChapterRequest {
        let prepared = try await f.archive.prepareChapter(identity: f.identity, book: catalog.book,
            chapter: catalog.chapters[chapter].ref, expectedCatalog: catalog, reload: true, gate: .init())
        guard case .fetch(let request) = prepared else { throw SourceDomainError(.invalidData, "Expected content request") }
        return request
    }
    private func content(_ request: SourceChapterRequest) throws -> SourceCachedChapter {
        let body = SourceWire.ChapterContent(body: .text(.init(text: "Offline text")))
        return SourceCachedChapter(key: request.key, identity: request.identity, content: body,
            document: try ChapterNormalizer.normalize(body), provenance: request.provenance)
    }

    @Test func hundredReadsInTenThousandChapterCatalogReuseOneDecode() async throws {
        let f = try fixture()
        let catalog = try await f.archive.saveCatalog(f.catalog(count: 10_000))
        for chapter in stride(from: 0, to: 10_000, by: 100) {
            let request = try await prepare(f, catalog: catalog, chapter: chapter)
            try await f.archive.saveChapter(content(request), request: request, gate: .init())
        }
        let metrics = await f.archive.catalogCacheStatistics()
        #expect(metrics.decodes == 1)
        #expect(metrics.catalogs == 1 && metrics.chapters == 10_000)
        #expect(try await f.archive.catalog(book: f.key()) == catalog)
        let json = try #require(JSONSerialization.jsonObject(with: SourceCoding.encode(catalog)) as? [String: Any])
        #expect(json["archiveDigest"] == nil)
        #expect(try SourceCoding.decode(SourceCatalog.self, from: SourceCoding.encode(catalog)) == catalog)
    }

    @Test func otherConnectionWritesOnlyInvalidateTheChangedCatalog() async throws {
        let f = try fixture()
        let original = try await f.archive.saveCatalog(f.catalog())
        let other = try SourceArchive(url: f.url)
        for n in 0..<10 {
            try await other.saveBook(.init(key: f.key("other\(n)"), details: .init(ref: .init(id: "other\(n)"), title: "Other")))
            _ = try await prepare(f, catalog: original)
        }
        #expect(await f.archive.catalogCacheStatistics().decodes == 1)
        let changed = try await other.saveCatalog(f.catalog(count: 4, revision: "r2"))
        await #expect(throws: SourceDomainError.self) { try await prepare(f, catalog: original) }
        #expect(try await f.archive.catalog(book: f.key()) == changed)
        #expect(await f.archive.catalogCacheStatistics().decodes == 2)
        _ = try await prepare(f, catalog: changed, chapter: 3)
    }

    @Test func rawPayloadUpdatesInvalidateTheIndexAndRejectLateContent() async throws {
        let f = try fixture()
        let original = try await f.archive.saveCatalog(f.catalog())
        let pending = try await prepare(f, catalog: original)
        let changed = f.catalog(count: 2, revision: "raw-r2")
        try raw(f.url, "UPDATE records SET payload=? WHERE namespace='catalog'", payload: SourceCoding.encode(changed))
        #expect(try await f.archive.catalog(book: f.key())?.revision == "raw-r2")
        await #expect(throws: SourceDomainError.self) {
            try await f.archive.saveChapter(content(pending), request: pending, gate: .init())
        }
        #expect(try await f.archive.chapter(pending.key, identity: f.identity, allowPreviousExtraction: true) == nil)
    }

    @Test func rolledBackCatalogDoesNotPoisonTheMemoryIndex() async throws {
        let f = try fixture()
        let original = try await f.archive.saveCatalog(f.catalog())
        let pending = try await prepare(f, catalog: original)
        let gate = SourceCommitGate(); gate.invalidate()
        await #expect(throws: SourceDomainError.self) { try await f.archive.saveCatalog(f.catalog(revision: "uncommitted"), gate: gate) }
        #expect(try await f.archive.catalog(book: f.key()) == original)
        try await f.archive.saveChapter(content(pending), request: pending, gate: .init())
        #expect(try await f.archive.chapter(pending.key, identity: f.identity)?.document.plainText == "Offline text")
    }

    @Test func deletionAndRecreationNeverReuseAnOldIndex() async throws {
        let f = try fixture()
        let original = try await f.archive.saveCatalog(f.catalog())
        try raw(f.url, "DELETE FROM records WHERE namespace='catalog'")
        #expect(try await f.archive.catalog(book: f.key()) == nil)
        #expect(await f.archive.catalogCacheStatistics().catalogs == 0)
        let other = try SourceArchive(url: f.url)
        let replacement = try await other.saveCatalog(f.catalog(count: 2))
        await #expect(throws: SourceDomainError.self) { try await prepare(f, catalog: original) }
        #expect(try await f.archive.catalog(book: f.key()) == replacement)
    }

    @Test func leastRecentlyUsedCatalogIsEvictedAndReloadable() async throws {
        let f = try fixture(limits: .init(maximumCatalogs: 2))
        _ = try await f.archive.saveCatalog(f.catalog("one"))
        _ = try await f.archive.saveCatalog(f.catalog("two"))
        _ = try await f.archive.catalog(book: f.key("one"))
        _ = try await f.archive.saveCatalog(f.catalog("three"))
        #expect(await f.archive.catalogCacheStatistics().decodes == 3)
        _ = try await f.archive.catalog(book: f.key("one"))
        #expect(await f.archive.catalogCacheStatistics().decodes == 3)
        #expect(try await f.archive.catalog(book: f.key("two"))?.book.id == "two")
        #expect(await f.archive.catalogCacheStatistics().decodes == 4)
        #expect(await f.archive.catalogCacheStatistics().catalogs == 2)
    }

    @Test func chapterAndByteBudgetsBoundRetentionWithoutRejectingReads() async throws {
        let f = try fixture(limits: .init(maximumCatalogs: 10, maximumChapters: 5))
        _ = try await f.archive.saveCatalog(f.catalog("one"))
        _ = try await f.archive.saveCatalog(f.catalog("two"))
        #expect(await f.archive.catalogCacheStatistics().chapters == 3)
        let oversized = try await f.archive.saveCatalog(f.catalog("large", count: 6))
        _ = try await prepare(f, catalog: oversized)
        #expect(await f.archive.catalogCacheStatistics().catalogs == 1)
        #expect(await f.archive.catalogCacheStatistics().chapters <= 5)
        let bytes = try fixture(limits: .init(maximumEncodedBytes: 1))
        let readable = try await bytes.archive.saveCatalog(bytes.catalog())
        _ = try await prepare(bytes, catalog: readable)
        #expect(await bytes.archive.catalogCacheStatistics().encodedBytes == 0)
        #expect(try await bytes.archive.catalog(book: bytes.key()) == readable)
    }

    @Test func clearingMemoryRetainsOfflineChaptersAndRebuildsTheIndex() async throws {
        let f = try fixture()
        let catalog = try await f.archive.saveCatalog(f.catalog())
        let request = try await prepare(f, catalog: catalog)
        let saved = try content(request)
        try await f.archive.saveChapter(saved, request: request, gate: .init())
        await f.archive.clearCatalogMemoryCache()
        #expect(await f.archive.catalogCacheStatistics().catalogs == 0)
        #expect(try await f.archive.chapter(saved.key, identity: f.identity, allowPreviousExtraction: true) == saved)
        _ = try await prepare(f, catalog: catalog)
        #expect(await f.archive.catalogCacheStatistics().decodes == 2)
    }

    @Test func versionOneMigrationPreservesRecordsAndAddsInvalidation() async throws {
        let f = try fixture()
        let url = f.url.deletingLastPathComponent().appendingPathComponent("legacy.sqlite3")
        try raw(url, """
            CREATE TABLE records(namespace TEXT NOT NULL,scope TEXT NOT NULL,key TEXT NOT NULL,payload BLOB NOT NULL,PRIMARY KEY(namespace,scope,key));
            CREATE TABLE source_state(scope TEXT NOT NULL,key TEXT NOT NULL,payload BLOB NOT NULL,revision TEXT NOT NULL,PRIMARY KEY(scope,key));
            PRAGMA user_version=1;
            """)
        let scope = SourceCoding.digest(try SourceCoding.encode(f.identity.scope))
        try raw(url, "INSERT INTO records(namespace,scope,key,payload) VALUES('catalog','\(scope)','book',?)", payload: SourceCoding.encode(f.catalog()))
        let migrated = try SourceArchive(url: url)
        let first = try #require(try await migrated.catalog(book: f.key()))
        #expect(first.revision == "r1" && first.cacheEpoch == nil)
        try raw(url, "UPDATE records SET payload=? WHERE namespace='catalog'", payload: SourceCoding.encode(f.catalog(revision: "r2")))
        #expect(try await migrated.catalog(book: f.key())?.revision == "r2")
        let reopened = try SourceArchive(url: url)
        #expect(try await reopened.catalog(book: f.key())?.revision == "r2")
    }

    @Test func duplicateChapterIdentityRollsBackWithoutLosingValidCatalog() async throws {
        let f = try fixture()
        let good = try await f.archive.saveCatalog(f.catalog())
        let invalid = SourceCatalog(identity: f.identity, book: good.book, chapters: [good.chapters[0], good.chapters[0]], revision: "bad")
        await #expect(throws: SourceDomainError.self) { try await f.archive.saveCatalog(invalid) }
        #expect(try await f.archive.catalog(book: f.key()) == good)
    }

    /// Independent SQLite writes exercise invalidation beyond SourceArchive's own setters.
    private func raw(_ url: URL, _ sql: String, payload: Data? = nil) throws {
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(url.path, &pointer, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let pointer else {
            throw SourceDomainError(.unavailable, "Cannot open fixture")
        }
        defer { sqlite3_close(pointer) }
        sqlite3_busy_timeout(pointer, 5000)
        guard let payload else {
            guard sqlite3_exec(pointer, sql, nil, nil, nil) == SQLITE_OK else { throw SourceDomainError(.unavailable, "Fixture SQL failed") }
            return
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(pointer, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SourceDomainError(.unavailable, "Cannot prepare fixture")
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let bound = payload.withUnsafeBytes { sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32($0.count), transient) }
        guard bound == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else { throw SourceDomainError(.unavailable, "Fixture write failed") }
    }
}
