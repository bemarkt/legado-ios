import Foundation
import SQLite3
import Testing
@testable import LegadoCore

private actor ChapterCacheProvider: SourceProvider {
    nonisolated let descriptor: SourceProviderDescriptor
    private var items = [SourceWire.Chapter(ref: .init(id: "one"), title: "One")]
    private var catalogRevision: String? = "catalog-1"
    private var body = SourceWire.ChapterContent(revision: "content-1", body: .text(.init(text: "Original body")))
    private var failing = false
    private var pauseNext = false
    private var pending: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private(set) var contentCalls = 0
    private(set) var lastInput: SourceWire.ContentInput?
    init(scope: SourceScope, digest: String = String(repeating: "a", count: 64)) throws {
        descriptor = .init(identity: try .init(scope: scope, sourceDigest: digest, configuration: .object([:])), name: "Cache fixture")
    }
    func setCatalog(_ items: [SourceWire.Chapter], revision: String?) { self.items = items; catalogRevision = revision }
    func setBody(_ text: String, revision: String? = "content-2") { body = .init(revision: revision, body: .text(.init(text: text))) }
    func setFailing(_ value: Bool) { failing = value }
    func pauseNextContent() { pauseNext = true }
    func waitUntilPaused() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func resume() { pending?.resume(); pending = nil }
    private func check() throws { if failing { throw SourceDomainError(.unavailable, "Synthetic failure") } }
    func search(_ input: SourceWire.SearchInput) async throws -> SourceWire.SearchPage { .init(items: [], nextCursor: .null) }
    func book(_ input: SourceWire.BookInput) async throws -> SourceWire.BookDetails { .init(ref: input.ref, title: "Cache book") }
    func chapters(_ input: SourceWire.ChaptersInput) async throws -> SourceWire.ChapterPage {
        try check(); return .init(items: items, nextCursor: .null, revision: catalogRevision)
    }
    func content(_ input: SourceWire.ContentInput) async throws -> SourceWire.ChapterContent {
        try check(); contentCalls += 1; lastInput = input
        let captured = body
        if pauseNext {
            pauseNext = false
            await withCheckedContinuation { continuation in
                pending = continuation
                started?.resume(); started = nil
            }
        }
        return captured
    }
}

@Suite("Chapter cache revision consistency")
struct SourceChapterCacheTests {
    private let book = SourceWire.SourceRef(id: "book")
    private let chapter = SourceWire.SourceRef(id: "one")
    private struct Fixture {
        let url: URL
        let archive: SourceArchive
        let service: SourceLibraryService
        let provider: ChapterCacheProvider
    }
    private func fixture() throws -> Fixture {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("source-cache-\(UUID().uuidString)/native.sqlite3")
        let archive = try SourceArchive(url: url)
        return Fixture(url: url, archive: archive, service: .init(archive: archive),
                       provider: try .init(scope: .init(installationID: UUID())))
    }

    @Test func changedRevisionRevalidatesSameCountAndPreservesOfflineCopy() async throws {
        let f = try fixture()
        let firstCatalog = try await f.service.refreshCatalog(provider: f.provider, book: book)
        let first = try await f.service.chapter(provider: f.provider, book: book, chapter: chapter, catalog: firstCatalog)
        await f.provider.setCatalog(firstCatalog.chapters, revision: "catalog-2")
        await f.provider.setBody("Corrected body", revision: "unrelated-content-revision")
        let secondCatalog = try await f.service.refreshCatalog(provider: f.provider, book: book)
        #expect(secondCatalog.chapters.count == firstCatalog.chapters.count)
        #expect(try await f.archive.chapter(first.key, identity: first.identity) == nil)
        #expect(try await f.service.chapter(provider: f.provider, book: book, chapter: chapter, policy: .offline) == first)
        let current = try await f.service.chapter(provider: f.provider, book: book, chapter: chapter, catalog: secondCatalog)
        #expect(current.document.plainText == "Corrected body")
        #expect(current.document.revision == "unrelated-content-revision")
        #expect(await f.provider.contentCalls == 2)
    }

    @Test func identicalExplicitRevisionReusesCacheAfterRefreshAndRestart() async throws {
        let f = try fixture()
        _ = try await f.service.refreshCatalog(provider: f.provider, book: book)
        let cached = try await f.service.chapter(provider: f.provider, book: book, chapter: chapter)
        let refreshed = try await f.service.refreshCatalog(provider: f.provider, book: book)
        await f.provider.setFailing(true)
        let reopened = SourceLibraryService(archive: try SourceArchive(url: f.url))
        #expect(try await reopened.chapter(provider: f.provider, book: book, chapter: chapter, catalog: refreshed) == cached)
        #expect(await f.provider.contentCalls == 1)
    }

    @Test func missingRevisionMakesEverySuccessfulRefreshRevalidate() async throws {
        let f = try fixture()
        let items = [SourceWire.Chapter(ref: chapter, title: "One")]
        await f.provider.setCatalog(items, revision: nil)
        _ = try await f.service.refreshCatalog(provider: f.provider, book: book)
        let first = try await f.service.chapter(provider: f.provider, book: book, chapter: chapter)
        await f.provider.setBody("Changed without revision", revision: nil)
        _ = try await f.service.refreshCatalog(provider: f.provider, book: book)
        #expect(try await f.archive.chapter(first.key, identity: first.identity) == nil)
        let second = try await f.service.chapter(provider: f.provider, book: book, chapter: chapter)
        #expect(second.document.plainText == "Changed without revision")
        #expect(await f.provider.contentCalls == 2)
    }

    @Test func changedRefsRejectOldCatalogAndBindNewRequest() async throws {
        let f = try fixture()
        let oldCatalog = try await f.service.refreshCatalog(provider: f.provider, book: book)
        _ = try await f.service.chapter(provider: f.provider, book: book, chapter: chapter)
        let updatedRef = SourceWire.SourceRef(id: chapter.id, state: .object(["route": .string("v2")]))
        let updatedBook = SourceWire.SourceRef(id: book.id, state: .string("new book locator"))
        await f.provider.setCatalog([.init(ref: updatedRef, title: "Updated")], revision: oldCatalog.revision)
        let fresh = try await f.service.refreshCatalog(provider: f.provider, book: updatedBook)
        await #expect(throws: SourceDomainError.self) {
            try await f.service.chapter(provider: f.provider, book: book, chapter: chapter, catalog: oldCatalog)
        }
        await #expect(throws: SourceDomainError.self) {
            try await f.service.chapter(provider: f.provider, book: book, chapter: updatedRef, catalog: fresh)
        }
        _ = try await f.service.chapter(provider: f.provider, book: updatedBook, chapter: updatedRef, catalog: fresh)
        #expect(await f.provider.lastInput == SourceWire.ContentInput(book: updatedBook, chapter: updatedRef))
        #expect(await f.provider.contentCalls == 2)
    }

    @Test func changedRequestWithoutCatalogCannotReuseSameIDCache() async throws {
        let f = try fixture()
        _ = try await f.service.chapter(provider: f.provider, book: book, chapter: chapter)
        await f.provider.setBody("New locator body")
        let ref = SourceWire.SourceRef(id: chapter.id, state: .string("new locator"))
        let result = try await f.service.chapter(provider: f.provider, book: book, chapter: ref)
        #expect(result.document.plainText == "New locator body")
        #expect(await f.provider.contentCalls == 2)
    }

    @Test func removedChapterIsOfflineOnlyAndRevisionReuseDoesNotReviveOldCache() async throws {
        let f = try fixture()
        let initial = try await f.service.refreshCatalog(provider: f.provider, book: book)
        let cached = try await f.service.chapter(provider: f.provider, book: book, chapter: chapter)
        await f.provider.setCatalog([], revision: "catalog-2")
        _ = try await f.service.refreshCatalog(provider: f.provider, book: book)
        await #expect(throws: SourceDomainError.self) { try await f.service.chapter(provider: f.provider, book: book, chapter: chapter) }
        #expect(try await f.service.chapter(provider: f.provider, book: book, chapter: chapter, policy: .offline) == cached)
        await f.provider.setCatalog(initial.chapters, revision: initial.revision)
        _ = try await f.service.refreshCatalog(provider: f.provider, book: book)
        await f.provider.setBody("Restored chapter has new content")
        let restored = try await f.service.chapter(provider: f.provider, book: book, chapter: chapter)
        #expect(restored.document.plainText == "Restored chapter has new content")
    }

    @Test func reorderWithUnchangedRevisionStillInvalidatesAndOldDownloadStops() async throws {
        let f = try fixture()
        let items = [SourceWire.Chapter(ref: chapter, title: "One"), .init(ref: .init(id: "two"), title: "Two")]
        await f.provider.setCatalog(items, revision: "same")
        let first = try await f.service.refreshCatalog(provider: f.provider, book: book)
        let cached = try await f.service.chapter(provider: f.provider, book: book, chapter: chapter)
        await f.provider.setCatalog(Array(items.reversed()), revision: "same")
        _ = try await f.service.refreshCatalog(provider: f.provider, book: book)
        #expect(try await f.archive.chapter(cached.key, identity: cached.identity) == nil)
        await #expect(throws: SourceDomainError.self) { try await f.service.download(provider: f.provider, catalog: first) }
        #expect(await f.provider.contentCalls == 1)
    }

    @Test func explicitReloadFetchesNewBodyAndFailedRefreshKeepsDownload() async throws {
        let f = try fixture()
        _ = try await f.service.refreshCatalog(provider: f.provider, book: book)
        let first = try await f.service.chapter(provider: f.provider, book: book, chapter: chapter)
        await f.provider.setBody("Updated silently", revision: nil)
        #expect(try await f.service.chapter(provider: f.provider, book: book, chapter: chapter) == first)
        let updated = try await f.service.chapter(provider: f.provider, book: book, chapter: chapter, policy: .reload)
        #expect(updated.document.plainText == "Updated silently")
        await f.provider.setFailing(true)
        await #expect(throws: SourceDomainError.self) { try await f.service.chapter(provider: f.provider, book: book, chapter: chapter, policy: .reload) }
        await #expect(throws: SourceDomainError.self) { try await f.service.refreshCatalog(provider: f.provider, book: book) }
        let reopened = SourceLibraryService(archive: try SourceArchive(url: f.url))
        #expect(try await reopened.chapter(provider: f.provider, book: book, chapter: chapter, policy: .offline) == updated)
    }

    @Test(.timeLimit(.minutes(1))) func inFlightContentCannotCommitAfterCatalogChangesOnAnotherConnection() async throws {
        let f = try fixture()
        _ = try await f.service.refreshCatalog(provider: f.provider, book: book)
        await f.provider.pauseNextContent()
        let old = Task { try await f.service.chapter(provider: f.provider, book: book, chapter: chapter) }
        await f.provider.waitUntilPaused()
        let other = SourceLibraryService(archive: try SourceArchive(url: f.url))
        await f.provider.setCatalog([.init(ref: chapter, title: "Changed")], revision: "new")
        _ = try await other.refreshCatalog(provider: f.provider, book: book)
        await f.provider.resume()
        await #expect(throws: SourceDomainError.self) { try await old.value }
        await #expect(throws: SourceDomainError.self) { try await other.chapter(provider: f.provider, book: book, chapter: chapter, policy: .offline) }
    }

    @Test(.timeLimit(.minutes(1))) func inFlightContentCannotOverwriteAcceptedContentOnAnotherConnection() async throws {
        let f = try fixture()
        _ = try await f.service.refreshCatalog(provider: f.provider, book: book)
        await f.provider.pauseNextContent()
        let old = Task { try await f.service.chapter(provider: f.provider, book: book, chapter: chapter) }
        await f.provider.waitUntilPaused()
        let other = SourceLibraryService(archive: try SourceArchive(url: f.url))
        await f.provider.setBody("New response wins")
        let newer = try await other.chapter(provider: f.provider, book: book, chapter: chapter)
        await f.provider.resume()
        await #expect(throws: SourceDomainError.self) { try await old.value }
        #expect(try await other.chapter(provider: f.provider, book: book, chapter: chapter, policy: .offline) == newer)
    }

    @Test(.timeLimit(.minutes(1))) func cancelledFetchCannotReplaceOfflineCopy() async throws {
        let f = try fixture()
        let cached = try await f.service.chapter(provider: f.provider, book: book, chapter: chapter)
        await f.provider.setBody("Cancelled response")
        await f.provider.pauseNextContent()
        let pending = Task { try await f.service.chapter(provider: f.provider, book: book, chapter: chapter, policy: .reload) }
        await f.provider.waitUntilPaused()
        pending.cancel()
        await f.provider.resume()
        await #expect(throws: CancellationError.self) { try await pending.value }
        #expect(try await f.service.chapter(provider: f.provider, book: book, chapter: chapter, policy: .offline) == cached)
    }

    @Test func oldSourceCatalogMustRefreshAndOfflineCopyNeverCrossesAccount() async throws {
        let f = try fixture()
        _ = try await f.service.refreshCatalog(provider: f.provider, book: book)
        let cached = try await f.service.chapter(provider: f.provider, book: book, chapter: chapter)
        let updated = try ChapterCacheProvider(scope: cached.identity.scope, digest: String(repeating: "b", count: 64))
        await #expect(throws: SourceDomainError.self) { try await f.service.chapter(provider: updated, book: book, chapter: chapter) }
        #expect(try await f.service.chapter(provider: updated, book: book, chapter: chapter, policy: .offline) == cached)
        let another = try ChapterCacheProvider(scope: .init(installationID: cached.identity.scope.installationID, accountID: "another"))
        await #expect(throws: SourceDomainError.self) { try await f.service.chapter(provider: another, book: book, chapter: chapter, policy: .offline) }
    }

    @Test func legacyArchiveDecodesOfflineAndRevalidatesOnline() async throws {
        let f = try fixture()
        let catalog = try await f.service.refreshCatalog(provider: f.provider, book: book)
        let cached = try await f.service.chapter(provider: f.provider, book: book, chapter: chapter)
        var legacyCatalog = try #require(JSONSerialization.jsonObject(with: SourceCoding.encode(catalog)) as? [String: Any])
        legacyCatalog.removeValue(forKey: "cacheEpoch")
        var legacyCache = try #require(JSONSerialization.jsonObject(with: SourceCoding.encode(cached)) as? [String: Any])
        legacyCache.removeValue(forKey: "provenance")
        try replaceRecord(f.url, namespace: "catalog", scope: cached.identity.scope, key: book.id, json: legacyCatalog)
        try replaceRecord(f.url, namespace: "chapter", scope: cached.identity.scope, key: SourceCoding.digest(SourceCoding.encode(cached.key)), json: legacyCache)
        let reopened = SourceLibraryService(archive: try SourceArchive(url: f.url))
        let offline = try await reopened.chapter(provider: f.provider, book: book, chapter: chapter, policy: .offline)
        #expect(offline.document == cached.document && offline.provenance == nil)
        let fresh = try await reopened.chapter(provider: f.provider, book: book, chapter: chapter)
        #expect(fresh.provenance != nil)
        #expect(await f.provider.contentCalls == 2)
    }

    @Test func normalizationVersionRebuildsFromRawContentWithoutNetwork() async throws {
        let f = try fixture()
        let cached = try await f.service.chapter(provider: f.provider, book: book, chapter: chapter)
        var json = try #require(JSONSerialization.jsonObject(with: SourceCoding.encode(cached)) as? [String: Any])
        var document = try #require(json["document"] as? [String: Any])
        document["normalizationVersion"] = 0
        document["blocks"] = [["kind": "paragraph", "text": "Obsolete normalization", "marks": []]]
        json["document"] = document
        try replaceRecord(f.url, namespace: "chapter", scope: cached.identity.scope, key: SourceCoding.digest(SourceCoding.encode(cached.key)), json: json)
        await f.provider.setFailing(true)
        let normalized = try await f.service.chapter(provider: f.provider, book: book, chapter: chapter, policy: .offline)
        #expect(normalized.document == cached.document)
        #expect(normalized.storedAt == cached.storedAt && normalized.provenance == cached.provenance)
        let reopened = try SourceArchive(url: f.url)
        #expect(try await reopened.chapter(cached.key, identity: cached.identity) == normalized)
        #expect(await f.provider.contentCalls == 1)
    }

    /// Write the historical on-disk shape, without passing it through the current cache API.
    private func replaceRecord(_ url: URL, namespace: String, scope: SourceScope, key: String, json: [String: Any]) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let handle else {
            throw SourceDomainError(.unavailable, "Cannot open fixture archive")
        }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "UPDATE records SET payload=? WHERE namespace=? AND scope=? AND key=?", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw SourceDomainError(.unavailable, "Cannot prepare fixture record") }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        let payload = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        let bound = payload.withUnsafeBytes { sqlite3_bind_blob(statement, 1, $0.baseAddress, Int32($0.count), transient) }
        guard bound == SQLITE_OK else { throw SourceDomainError(.unavailable, "Cannot bind fixture payload") }
        let fields = [namespace, SourceCoding.digest(try SourceCoding.encode(scope)), key]
        for (index, value) in fields.enumerated() {
            let status = value.withCString { sqlite3_bind_text(statement, Int32(index + 2), $0, -1, transient) }
            guard status == SQLITE_OK else { throw SourceDomainError(.unavailable, "Cannot bind fixture identity") }
        }
        guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(handle) == 1 else {
            throw SourceDomainError(.unavailable, "Fixture record did not exist")
        }
    }
}
