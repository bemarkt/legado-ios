import Foundation
import Testing
@testable import LegadoCore

private actor ReaderAccessProvider: SourceProvider {
    nonisolated let descriptor: SourceProviderDescriptor
    private(set) var calls = 0
    private var pauseNext = false
    private var suspended: CheckedContinuation<Void, Never>?
    private var body: SourceWire.ChapterContent?
    private var revision = "directory-1"

    init(identity: SourceExecutionIdentity, gate: SourceCommitGate? = nil) {
        descriptor = .init(identity: identity, name: "Reader fixture", commitGate: gate)
    }
    func pause() { pauseNext = true }
    func waitUntilPaused() async { while suspended == nil { await Task.yield() } }
    func release() { suspended?.resume(); suspended = nil }
    func setBody(_ value: SourceWire.ChapterContent) { body = value }
    func changeDirectory() { revision = "directory-2" }
    func search(_ input: SourceWire.SearchInput) async throws -> SourceWire.SearchPage { .init(items: [], nextCursor: .null) }
    func book(_ input: SourceWire.BookInput) async throws -> SourceWire.BookDetails { .init(ref: input.ref, title: "Reader fixture") }
    func chapters(_ input: SourceWire.ChaptersInput) async throws -> SourceWire.ChapterPage {
        .init(items: ["one", "two"].map { .init(ref: .init(id: $0), title: "Title \($0)") }, nextCursor: .null, revision: revision)
    }
    func content(_ input: SourceWire.ContentInput) async throws -> SourceWire.ChapterContent {
        calls += 1
        let captured = body ?? .init(revision: "body-\(calls)", body: .text(.init(text: "Body \(calls)")))
        if pauseNext {
            pauseNext = false
            // Deliberately ignores cancellation, like a late callback from an external engine.
            await withCheckedContinuation { suspended = $0 }
        }
        return captured
    }
}

private actor ReaderProviderFactory {
    let provider: ReaderAccessProvider
    private(set) var calls = 0
    init(_ provider: ReaderAccessProvider) { self.provider = provider }
    func make() -> any SourceProvider { calls += 1; return provider }
}

@Suite("Source reader chapter access", .timeLimit(.minutes(1)))
struct ReaderChapterAccessTests {
    private struct Fixture: Sendable {
        let directory: URL
        let archive: SourceArchive
        let service: SourceLibraryService
        let provider: ReaderAccessProvider
        let factory: ReaderProviderFactory
        let catalog: SourceCatalog
        func access(offline: Bool = false, catalog replacement: SourceCatalog? = nil) -> SourceReaderChapterAccess {
            SourceReaderChapterAccess(catalog: replacement ?? catalog, archive: archive, offlineOnly: offline) { await factory.make() }
        }
        func key(_ id: String = "one") throws -> SourceChapterKey {
            try .init(book: .init(scope: catalog.identity.libraryScope, bookID: catalog.book.id), chapterID: id)
        }
        func clean() { try? FileManager.default.removeItem(at: directory) }
    }

    private func fixture(gate: SourceCommitGate? = nil) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("reader-access-\(UUID())")
        let archive = try SourceArchive(url: directory.appendingPathComponent("native.sqlite3"))
        let identity = try SourceExecutionIdentity(scope: .init(installationID: UUID()), sourceDigest: String(repeating: "a", count: 64), configuration: .object([:]))
        let provider = ReaderAccessProvider(identity: identity, gate: gate)
        let service = SourceLibraryService(archive: archive)
        let catalog = try await service.refreshCatalog(provider: provider, book: .init(id: "book"))
        return .init(directory: directory, archive: archive, service: service, provider: provider, factory: .init(provider), catalog: catalog)
    }

    private func waitForConsumers(_ count: Int, in access: SourceReaderChapterAccess) async {
        while await access.pendingRead(for: "one")?.consumers != count { await Task.yield() }
    }

    @Test func networkCacheAndReloadPreserveNormalizedDocumentAndReportTheirOrigin() async throws {
        let f = try await fixture(); defer { f.clean() }
        await f.provider.setBody(.init(title: "Resolved", body: .html(.init(html: "<h2>Heading</h2><p>A <strong>bold</strong> word.</p>", baseURL: "https://fixture.invalid/chapter"))))
        let access = f.access()
        let fresh = try await access.load(chapterID: "one")
        #expect(fresh.title == "Resolved")
        #expect(!fresh.loadedFromCache)
        #expect(fresh.text == "Heading\n\nA bold word.")
        #expect(fresh.document?.blocks.first?.headingLevel == 2)
        #expect(fresh.document?.blocks.last?.marks.first?.kind == .strong)
        let cached = try await access.load(chapterID: "one")
        #expect(cached.loadedFromCache)
        #expect(cached.document == fresh.document)
        #expect(await f.provider.calls == 1)
        let reloaded = try await access.load(chapterID: "one", reload: true)
        #expect(!reloaded.loadedFromCache)
        #expect(await f.provider.calls == 2)
    }

    @Test func offlineReadingUsesLocalIdentityWithoutCreatingAWebsiteProvider() async throws {
        let f = try await fixture(); defer { f.clean() }
        _ = try await f.access().load(chapterID: "one")
        let before = await f.factory.calls
        let identity = try SourceExecutionIdentity(scope: .init(installationID: f.catalog.identity.scope.installationID, accountID: "other-login"),
            sourceDigest: String(repeating: "b", count: 64), configuration: .object([:]), libraryScope: f.catalog.identity.libraryScope)
        let offlineCatalog = SourceCatalog(identity: identity, book: f.catalog.book, chapters: f.catalog.chapters, revision: f.catalog.revision)
        let access = f.access(offline: true, catalog: offlineCatalog)
        let cached = try await access.load(chapterID: "one", reload: true)
        #expect(cached.loadedFromCache)
        #expect(cached.text == "Body 1")
        #expect(await f.factory.calls == before)
        await #expect(throws: SourceDomainError.self) { try await access.load(chapterID: "two") }
        await #expect(throws: SourceDomainError.self) { try await access.load(chapterID: "outside-directory") }
        #expect(await f.factory.calls == before)
    }

    @Test func aChangedExecutionIdentityIsRejectedBeforeReadingContent() async throws {
        let f = try await fixture(); defer { f.clean() }
        let variants = [
            try SourceExecutionIdentity(scope: f.catalog.identity.scope, sourceDigest: String(repeating: "b", count: 64), configuration: .object([:])),
            try SourceExecutionIdentity(scope: f.catalog.identity.scope, sourceDigest: f.catalog.identity.sourceDigest, configuration: .object([:]), credentialRevision: "changed-login"),
            try SourceExecutionIdentity(scope: .init(installationID: UUID()), sourceDigest: f.catalog.identity.sourceDigest, configuration: .object([:]))
        ]
        for identity in variants {
            let catalog = SourceCatalog(identity: identity, book: f.catalog.book, chapters: f.catalog.chapters, revision: f.catalog.revision)
            await #expect(throws: SourceDomainError.self) { try await f.access(catalog: catalog).load(chapterID: "one") }
        }
        #expect(await f.provider.calls == 0)
    }

    @Test func identicalBookAndChapterIDsInDifferentInstallationsDoNotShareOfflineText() async throws {
        let f = try await fixture(); defer { f.clean() }
        _ = try await f.access().load(chapterID: "one")
        let identity = try SourceExecutionIdentity(scope: .init(installationID: UUID()), sourceDigest: f.catalog.identity.sourceDigest, configuration: .object([:]))
        let catalog = SourceCatalog(identity: identity, book: f.catalog.book, chapters: f.catalog.chapters, revision: f.catalog.revision)
        await #expect(throws: SourceDomainError.self) { try await f.access(offline: true, catalog: catalog).load(chapterID: "one") }
    }

    @Test func cancellingOneOfTwoReadersKeepsTheSharedRequestAlive() async throws {
        let f = try await fixture(); defer { f.clean() }
        await f.provider.pause()
        let access = f.access()
        let first = Task { try await access.load(chapterID: "one") }
        await f.provider.waitUntilPaused()
        let second = Task { try await access.load(chapterID: "one") }
        await waitForConsumers(2, in: access)
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        await f.provider.release()
        #expect(try await second.value.text == "Body 1")
        #expect(await f.provider.calls == 1)
        #expect(await f.factory.calls == 1)
    }

    @Test func cancellingTheLastReaderDoesNotCommitALateProviderResponse() async throws {
        let f = try await fixture(); defer { f.clean() }
        await f.provider.pause()
        let access = f.access()
        let read = Task { try await access.load(chapterID: "one") }
        await f.provider.waitUntilPaused()
        let work = try #require(await access.pendingRead(for: "one")?.task)
        read.cancel()
        await #expect(throws: CancellationError.self) { try await read.value }
        await f.provider.release()
        await work.value
        #expect(try await f.archive.chapter(f.key(), identity: f.catalog.identity) == nil)
        #expect(try await access.load(chapterID: "one").text == "Body 2")
    }

    @Test func reloadSupersedesOrdinaryReadAndOldCompletionCannotReplaceIt() async throws {
        let f = try await fixture(); defer { f.clean() }
        await f.provider.pause()
        let access = f.access()
        let first = Task { try await access.load(chapterID: "one") }
        await f.provider.waitUntilPaused()
        let oldWork = try #require(await access.pendingRead(for: "one")?.task)
        let fresh = try await access.load(chapterID: "one", reload: true)
        #expect(fresh.text == "Body 2")
        await #expect(throws: SourceDomainError.self) { try await first.value }
        await f.provider.release()
        await oldWork.value
        #expect(try await f.archive.chapter(f.key(), identity: f.catalog.identity)?.document.plainText == "Body 2")
    }

    @Test func anOrdinaryReadJoinsAnInFlightReload() async throws {
        let f = try await fixture(); defer { f.clean() }
        await f.provider.pause()
        let access = f.access()
        let reload = Task { try await access.load(chapterID: "one", reload: true) }
        await f.provider.waitUntilPaused()
        let ordinary = Task { try await access.load(chapterID: "one") }
        await waitForConsumers(2, in: access)
        await f.provider.release()
        #expect(try await reload.value.text == ordinary.value.text)
        #expect(await f.provider.calls == 1)
    }

    @Test func closingTheSessionReleasesConsumersRejectsFutureReadsAndDropsLateContent() async throws {
        let f = try await fixture(); defer { f.clean() }
        await f.provider.pause()
        let access = f.access()
        let read = Task { try await access.load(chapterID: "one") }
        await f.provider.waitUntilPaused()
        let work = try #require(await access.pendingRead(for: "one")?.task)
        await access.close()
        await #expect(throws: CancellationError.self) { try await read.value }
        await #expect(throws: SourceDomainError.self) { try await access.load(chapterID: "one") }
        await f.provider.release()
        await work.value
        #expect(try await f.archive.chapter(f.key(), identity: f.catalog.identity) == nil)
    }

    @Test func changingTheCatalogDuringAReadCannotSaveTextFromTheOldDirectory() async throws {
        let f = try await fixture(); defer { f.clean() }
        await f.provider.pause()
        let access = f.access()
        let read = Task { try await access.load(chapterID: "one") }
        await f.provider.waitUntilPaused()
        await f.provider.changeDirectory()
        _ = try await f.service.refreshCatalog(provider: f.provider, book: f.catalog.book)
        await f.provider.release()
        await #expect(throws: SourceDomainError.self) { try await read.value }
        #expect(try await f.archive.chapter(f.key(), identity: f.catalog.identity, allowPreviousExtraction: true) == nil)
    }

    @Test func revokingWebsiteCredentialsPreventsTheInflightReadFromCommitting() async throws {
        let gate = SourceCommitGate()
        let f = try await fixture(gate: gate); defer { f.clean() }
        await f.provider.pause()
        let access = f.access()
        let read = Task { try await access.load(chapterID: "one") }
        await f.provider.waitUntilPaused()
        gate.invalidate()
        await f.provider.release()
        await #expect(throws: SourceDomainError.self) { try await read.value }
        #expect(try await f.archive.chapter(f.key(), identity: f.catalog.identity, allowPreviousExtraction: true) == nil)
    }
}
