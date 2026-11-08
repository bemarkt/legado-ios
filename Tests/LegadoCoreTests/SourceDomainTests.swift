import Foundation
import Testing
@testable import LegadoCore

private actor DomainFixtureProvider: SourceProvider {
    nonisolated let descriptor: SourceProviderDescriptor
    let pages: [SourceWire.ChapterPage]
    private var offline = false
    private(set) var contentCalls = 0
    init(scope: SourceScope, digest: String = String(repeating: "a", count: 64), configuration: SourceJSON = .object([:]), pages: [SourceWire.ChapterPage]? = nil) throws {
        descriptor = .init(identity: try .init(scope: scope, sourceDigest: digest, configuration: configuration), name: "Synthetic")
        self.pages = pages ?? [.init(items: [.init(ref: .init(id: "c1"), title: "Repeated")], nextCursor: .number(1), revision: "r1"),
                               .init(items: [.init(ref: .init(id: "c2"), title: "Repeated")], nextCursor: .null, revision: "r1")]
    }
    func setOffline() { offline = true }
    func check() throws { if offline { throw SourceDomainError(.unavailable, "Synthetic offline") } }
    func search(_ input: SourceWire.SearchInput) async throws -> SourceWire.SearchPage {
        try check(); return .init(items: [.init(ref: .init(id: "book"), title: input.query)], nextCursor: .null)
    }
    func book(_ input: SourceWire.BookInput) async throws -> SourceWire.BookDetails {
        try check(); return .init(ref: input.ref, title: "Synthetic book")
    }
    func chapters(_ input: SourceWire.ChaptersInput) async throws -> SourceWire.ChapterPage {
        try check()
        let index: Int
        if case .some(.number(let value)) = input.cursor { index = Int(value) } else { index = 0 }
        guard pages.indices.contains(index) else { throw SourceDomainError(.invalidInput, "Unknown fixture cursor") }
        return pages[index]
    }
    func content(_ input: SourceWire.ContentInput) async throws -> SourceWire.ChapterContent {
        try check(); contentCalls += 1
        return .init(title: input.chapter.id, revision: "r1", body: .text(.init(text: "First paragraph.\n\nSecond paragraph 😀.")))
    }
}

/// First result is deliberately held after the newer result has committed.
private actor DelayedDomainProvider: SourceProvider {
    nonisolated let descriptor: SourceProviderDescriptor
    private var calls = 0
    private var pending: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    init(scope: SourceScope) throws {
        descriptor = .init(identity: try .init(scope: scope, sourceDigest: String(repeating: "a", count: 64), configuration: .object([:])), name: "Delayed")
    }
    func waitForFirstCall() async {
        if calls > 0 { return }
        await withCheckedContinuation { started = $0 }
    }
    func release() { pending?.resume(); pending = nil }
    private func resultLabel() async -> String {
        calls += 1
        guard calls == 1 else { return "new" }
        await withCheckedContinuation { continuation in
            pending = continuation
            started?.resume(); started = nil
        }
        return "old"
    }
    func search(_ input: SourceWire.SearchInput) async throws -> SourceWire.SearchPage { .init(items: [], nextCursor: .null) }
    func book(_ input: SourceWire.BookInput) async throws -> SourceWire.BookDetails { .init(ref: input.ref, title: "Book") }
    func chapters(_ input: SourceWire.ChaptersInput) async throws -> SourceWire.ChapterPage {
        .init(items: [.init(ref: .init(id: "chapter"), title: await resultLabel())], nextCursor: .null)
    }
    func content(_ input: SourceWire.ContentInput) async throws -> SourceWire.ChapterContent {
        .init(body: .text(.init(text: await resultLabel())))
    }
}

@Suite("Native source domain")
struct SourceDomainTests {
    private func scope(_ account: String = "guest", id: UUID = UUID()) throws -> SourceScope { try .init(installationID: id, accountID: account) }
    private func database() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("source-domain-\(UUID().uuidString)/native.sqlite3") }
    private func chapter(_ id: String, title: String = "Repeated") -> SourceWire.Chapter { .init(ref: .init(id: id), title: title) }
    private func document(_ text: String) throws -> ChapterDocument { try ChapterNormalizer.normalize(.init(body: .text(.init(text: text)))) }

    @Test func jsonCanonicalIdentityAndInvalidValues() throws {
        let a = SourceJSON.object(["b": .number(2), "a": .string("😀")])
        let b = SourceJSON.object(["a": .string("😀"), "b": .number(2)])
        #expect(try a.validatedData() == b.validatedData())
        #expect(try SourceCoding.decode(SourceJSON.self, from: a.validatedData()) == a)
        #expect(throws: SourceDomainError.self) { try SourceJSON.number(.infinity).validatedData() }
        #expect(throws: SourceDomainError.self) { try SourceJSON.object(["__proto__": .null]).validatedData() }
        var deep = SourceJSON.null
        for _ in 0..<34 { deep = .array([deep]) }
        #expect(throws: SourceDomainError.self) { try deep.validatedData() }
        #expect(throws: SourceDomainError.self) { try SourceJSON.string(String(repeating: "😀", count: 5000)).validatedData() }
    }

    @Test func wireBodiesRoundTripWithoutEngineObjects() throws {
        let ref = SourceWire.SourceRef(id: "book", state: .null)
        #expect(try SourceCoding.decode(SourceWire.SourceRef.self, from: SourceCoding.encode(ref)).state == .null)
        let bodies: [SourceWire.Body] = [.text(.init(text: "Text")), .html(.init(html: "<p>text</p>", baseURL: "https://example.org"))]
        for body in bodies {
            let value = SourceWire.ChapterContent(body: body)
            #expect(try SourceCoding.decode(SourceWire.ChapterContent.self, from: SourceCoding.encode(value)) == value)
        }
        #expect(throws: (any Error).self) { try SourceCoding.decode(SourceWire.Body.self, from: Data(#"{"kind":"script"}"#.utf8)) }
    }

    @Test func cursorRejectsDifferentSourceAccountConfigAndQuery() throws {
        let scope = try scope()
        let identity = try SourceExecutionIdentity(scope: scope, sourceDigest: String(repeating: "a", count: 64), configuration: .object([:]))
        let input = SourceJSON.object(["query": .string("Book")])
        let cursor = try SourceCursorEnvelope(identity: identity, input: input, value: .object(["page": .number(2)]))
        #expect(try cursor.unwrap(identity: identity, input: input) == .object(["page": .number(2)]))
        let changed = try [SourceExecutionIdentity(scope: self.scope("other", id: scope.installationID), sourceDigest: identity.sourceDigest, configuration: .object([:])),
                           SourceExecutionIdentity(scope: scope, sourceDigest: String(repeating: "b", count: 64), configuration: .object([:])),
                           SourceExecutionIdentity(scope: scope, sourceDigest: identity.sourceDigest, configuration: .object(["x": .bool(true)]))]
        for value in changed { #expect(throws: SourceDomainError.self) { try cursor.unwrap(identity: value, input: input) } }
        #expect(throws: SourceDomainError.self) { try cursor.unwrap(identity: identity, input: .object(["query": .string("Other")])) }
    }

    @Test func catalogDeduplicatesOnlyIdenticalCrossPageItems() async throws {
        let first = chapter("one")
        let provider = try DomainFixtureProvider(scope: scope(), pages: [
            .init(items: [], nextCursor: .number(1), revision: "r1"),
            .init(items: [first], nextCursor: .number(2), revision: "r1"),
            .init(items: [first, chapter("two")], nextCursor: .null, revision: "r1")])
        let result = try await SourceCatalogLoader().load(provider: provider, book: .init(id: "book"))
        #expect(result.chapters.map(\.ref.id) == ["one", "two"])
        #expect(result.revision == "r1")
    }

    @Test func catalogRejectsConflictsRepeatedCursorsAndRevisionLoss() async throws {
        let first = chapter("one")
        let scenarios: [[SourceWire.ChapterPage]] = [
            [.init(items: [first, first], nextCursor: .null)],
            [.init(items: [first], nextCursor: .number(1)), .init(items: [chapter("one", title: "Changed")], nextCursor: .null)],
            [.init(items: [], nextCursor: .number(1)), .init(items: [], nextCursor: .number(1))],
            [.init(items: [], nextCursor: .number(1), revision: "r1"), .init(items: [], nextCursor: .null, revision: "r2")],
            [.init(items: [], nextCursor: .number(1), revision: "r1"), .init(items: [], nextCursor: .null)]
        ]
        for pages in scenarios {
            let provider = try DomainFixtureProvider(scope: scope(), pages: pages)
            await #expect(throws: SourceDomainError.self) { try await SourceCatalogLoader().load(provider: provider, book: .init(id: "book")) }
        }
        let provider = try DomainFixtureProvider(scope: scope())
        await #expect(throws: SourceDomainError.self) { try await SourceCatalogLoader(maximumPages: 1).load(provider: provider, book: .init(id: "book")) }
    }

    @Test func catalogDetectsSameCountReplacementAndReordering() throws {
        let identity = try SourceExecutionIdentity(scope: scope(), sourceDigest: String(repeating: "a", count: 64), configuration: .object([:]))
        let old = SourceCatalog(identity: identity, book: .init(id: "book"), chapters: [chapter("one"), chapter("two"), chapter("three")], revision: "r1")
        let new = SourceCatalog(identity: identity, book: .init(id: "book"), chapters: [chapter("three"), chapter("one", title: "Changed"), chapter("four")], revision: "r2")
        let changes = try new.changes(from: old)
        #expect(changes.inserted == ["four"])
        #expect(changes.removed == ["two"])
        #expect(changes.updated == ["one"])
        #expect(changes.reordered)
    }

    @Test func sharedTextNormalizationCorpus() throws {
        struct Sample: Decodable { let input: String; let expected: String }
        let url = try #require(Bundle.module.url(forResource: "text-normalization", withExtension: "json", subdirectory: "Fixtures/SourceProtocol"))
        for sample in try JSONDecoder().decode([Sample].self, from: Data(contentsOf: url)) {
            #expect(ChapterNormalizer.text(sample.input) == sample.expected)
        }
        #expect(throws: SourceDomainError.self) { try document("\n \t") }
    }

    @Test func sharedHTMLNormalizationCorpus() throws {
        struct Expected: Decodable { let kind: String; let text: String; let marks: [ChapterDocument.Mark]? }
        struct Sample: Decodable { let html: String; let blocks: [Expected] }
        struct Samples: Decodable { let fixtures: [Sample] }
        let url = try #require(Bundle.module.url(forResource: "html-normalization.expected", withExtension: "json", subdirectory: "Fixtures/SourceProtocol"))
        for sample in try JSONDecoder().decode(Samples.self, from: Data(contentsOf: url)).fixtures {
            let output = try ChapterNormalizer.normalize(.init(body: .html(.init(html: sample.html, baseURL: "https://example.org"))))
            #expect(output.blocks.count == sample.blocks.count)
            for (actual, expected) in zip(output.blocks, sample.blocks) {
                #expect(actual.kind.rawValue == expected.kind)
                #expect(actual.text == expected.text)
                #expect(actual.marks == expected.marks ?? [])
            }
        }
    }

    @Test func htmlUsesUTF16MarksAndDropsActiveSubtrees() throws {
        let html = "<h2>Title</h2><p>😀<b>粗<i>体</i></b><iframe>bad</iframe><a href='javascript:x()'>link</a></p>"
        let doc = try ChapterNormalizer.normalize(.init(body: .html(.init(html: html, baseURL: "https://example.org"))))
        #expect(doc.blocks[0].headingLevel == 2)
        #expect(doc.blocks[1].text == "😀粗体link")
        #expect(doc.blocks[1].marks.contains(.init(kind: .strong, startUTF16: 2, endUTF16: 4)))
        #expect(doc.blocks[1].marks.contains(.init(kind: .emphasis, startUTF16: 3, endUTF16: 4)))
        #expect(!doc.plainText.contains("bad"))
        #expect(throws: SourceDomainError.self) { try ChapterNormalizer.normalize(.init(body: .html(.init(html: "<script>bad</script><img src='https://example.org'>", baseURL: "https://example.org")))) }
    }

    @Test func readingAnchorsSurviveReflowAndInsertionWithoutSplittingEmoji() throws {
        let key = try SourceChapterKey(book: .init(scope: scope(), bookID: "book"), chapterID: "one")
        let original = try document("😀 Hello stable phrase. End.")
        let anchor = SourceReadingAnchor(chapter: key, document: original, offsetUTF16: 1)
        #expect(anchor.offsetUTF16 == 0)
        #expect(try anchor.resolve(chapter: key, document: original).method == .exact)
        let phrase = SourceReadingAnchor(chapter: key, document: original, offsetUTF16: 9)
        let changed = try document("New paragraph.\n\n😀 Hello stable phrase. End.")
        let resolution = try phrase.resolve(chapter: key, document: changed)
        #expect(resolution.method == .quote)
        #expect(resolution.offsetUTF16 > phrase.offsetUTF16)
        #expect(try phrase.resolve(chapter: key, document: document("Short")).method == .nearest)
        let foreign = try SourceChapterKey(book: key.book, chapterID: "two")
        #expect(throws: SourceDomainError.self) { try phrase.resolve(chapter: foreign, document: changed) }
    }

    @Test func stateSurvivesReopenAndSeparatesAccountsInstallationsAndNull() async throws {
        let url = database(), owner = try scope()
        let first = try SourceArchive(url: url)
        let written = try await first.setState(scope: owner, key: "key", value: .null, condition: .missing)
        let reopened = try SourceArchive(url: url)
        #expect(try await reopened.state(scope: owner, key: "key") == written)
        #expect(try await reopened.state(scope: self.scope("other", id: owner.installationID), key: "key") == nil)
        #expect(try await reopened.state(scope: scope(), key: "key") == nil)
        #expect(try await reopened.state(scope: owner, key: "missing") == nil)
    }

    @Test func stateRevisionConflictAndDeleteRecreateAvoidABA() async throws {
        let archive = try SourceArchive(url: database()), scope = try scope()
        let first = try await archive.setState(scope: scope, key: "key", value: .string("one"), condition: .missing)
        await #expect(throws: SourceDomainError.self) { try await archive.setState(scope: scope, key: "key", value: .null, condition: .missing) }
        try await archive.removeState(scope: scope, key: "key", condition: .revision(first.revision))
        let second = try await archive.setState(scope: scope, key: "key", value: .string("two"), condition: .missing)
        #expect(first.revision != second.revision)
        await #expect(throws: SourceDomainError.self) { try await archive.removeState(scope: scope, key: "key", condition: .revision(first.revision)) }
        #expect(try await archive.state(scope: scope, key: "key") == second)
    }

    @Test func stateCompareAndSetHasOneWinnerAcrossConnections() async throws {
        let url = database(), scope = try scope()
        let a = try SourceArchive(url: url), b = try SourceArchive(url: url)
        let initial = try await a.setState(scope: scope, key: "key", value: .number(0))
        let wins = await withTaskGroup(of: Bool.self) { group in
            for archive in [a,b] { group.addTask {
                do { _ = try await archive.setState(scope: scope, key: "key", value: .number(1), condition: .revision(initial.revision)); return true }
                catch { return false }
            } }
            var count = 0
            for await success in group where success { count += 1 }
            return count
        }
        #expect(wins == 1)
    }

    @Test func quotaFailureLeavesPreviousStateIntact() async throws {
        let archive = try SourceArchive(url: database(), stateLimit: 20), scope = try scope()
        let first = try await archive.setState(scope: scope, key: "a", value: .string("1234567890"))
        await #expect(throws: SourceDomainError.self) { try await archive.setState(scope: scope, key: "b", value: .string("1234567890")) }
        #expect(try await archive.state(scope: scope, key: "a") == first)
        #expect(try await archive.state(scope: scope, key: "b") == nil)
        try await archive.removeState(scope: scope, key: "a")
        _ = try await archive.setState(scope: scope, key: "b", value: .string("1234567890"))
    }

    @Test func installationIdentityDoesNotMergePublisherIDsAndUpdatesUseCAS() async throws {
        let archive = try SourceArchive(url: database())
        let one = try SourceInstallation(publisherID: "org.example", name: "One", version: "1.0.0", source: "one", origins: ["https://example.org"])
        let two = try SourceInstallation(publisherID: "org.example", name: "Two", version: "1.0.0", source: "two", origins: ["https://example.org"])
        try await archive.saveInstallation(one)
        try await archive.saveInstallation(two)
        #expect(try await archive.installations().count == 2)
        let update = try SourceInstallation(id: one.id, publisherID: one.publisherID, name: one.name, version: "2.0.0", source: "updated", origins: one.origins)
        await #expect(throws: SourceDomainError.self) { try await archive.saveInstallation(update) }
        try await archive.saveInstallation(update, replacing: one.digest)
        #expect(try await archive.installation(one.id)?.digest == update.digest)
    }

    @Test func searchLibraryDownloadRestartOfflineAndPosition() async throws {
        let url = database(), scope = try scope()
        let archive = try SourceArchive(url: url)
        let service = SourceLibraryService(archive: archive)
        let provider = try DomainFixtureProvider(scope: scope)
        let search = try await provider.search(.init(query: "Synthetic"))
        let book = try await service.addBook(provider: provider, ref: search.items[0].ref)
        let catalog = try await service.refreshCatalog(provider: provider, book: book.details.ref)
        #expect(try await service.download(provider: provider, catalog: catalog) == 2)
        let first = try await service.chapter(provider: provider, book: book.details.ref, chapter: catalog.chapters[0].ref)
        let anchor = SourceReadingAnchor(chapter: first.key, document: first.document, offsetUTF16: 5)
        try await archive.saveAnchor(anchor)
        await provider.setOffline()
        let reopened = try SourceArchive(url: url)
        let resumed = SourceLibraryService(archive: reopened)
        #expect(try await reopened.books(scope: scope) == [book])
        #expect(try await reopened.catalog(book: book.key)?.chapters.count == 2)
        #expect(try await reopened.anchor(book: book.key) == anchor)
        let cached = try await resumed.chapter(provider: provider, book: book.details.ref, chapter: catalog.chapters[0].ref, policy: .offline)
        #expect(cached == first)
        #expect(await provider.contentCalls == 2)
        await #expect(throws: SourceDomainError.self) { try await resumed.chapter(provider: provider, book: book.details.ref, chapter: .init(id: "not-downloaded"), policy: .offline) }
    }

    @Test func extractionChangesMissCurrentCacheButPreserveExplicitOfflineCopy() async throws {
        let scope = try scope(), archive = try SourceArchive(url: database())
        let original = try DomainFixtureProvider(scope: scope)
        let service = SourceLibraryService(archive: archive)
        let cached = try await service.chapter(provider: original, book: .init(id: "book"), chapter: .init(id: "one"))
        let updated = try DomainFixtureProvider(scope: scope, digest: String(repeating: "b", count: 64))
        #expect(try await archive.chapter(cached.key, identity: updated.descriptor.identity) == nil)
        #expect(try await archive.chapter(cached.key, identity: updated.descriptor.identity, allowPreviousExtraction: true) == cached)
        let changedConfig = try DomainFixtureProvider(scope: scope, configuration: .object(["edition": .string("other")]))
        #expect(try await archive.chapter(cached.key, identity: changedConfig.descriptor.identity) == nil)
    }

    @Test func searchYieldsHealthySourceEvenWhenAnotherFails() async throws {
        let good = try DomainFixtureProvider(scope: scope()), bad = try DomainFixtureProvider(scope: scope())
        await bad.setOffline()
        var updates: [SourceSearchService.Update] = []
        for await update in SourceSearchService.search("Synthetic", providers: [bad,good]) { updates.append(update) }
        #expect(updates.count == 2)
        #expect(updates.filter { $0.page != nil }.count == 1)
        #expect(updates.filter { $0.error != nil }.count == 1)
    }
    @Test func completedOperationCannotCommitStateOrCache() async throws {
        let archive = try SourceArchive(url: database()), scope = try scope()
        let gate = SourceCommitGate()
        _ = try await archive.setState(scope: scope, key: "saved", value: .string("before"), gate: gate)
        gate.invalidate()
        await #expect(throws: SourceDomainError.self) { try await archive.setState(scope: scope, key: "saved", value: .string("late"), gate: gate) }
        await #expect(throws: SourceDomainError.self) { try await archive.removeState(scope: scope, key: "saved", gate: gate) }
        #expect(try await archive.state(scope: scope, key: "saved")?.value == .string("before"))
        let provider = try DomainFixtureProvider(scope: scope)
        let catalog = try await SourceCatalogLoader().load(provider: provider, book: .init(id: "book"))
        await #expect(throws: SourceDomainError.self) { try await archive.saveCatalog(catalog, gate: gate) }
        #expect(try await archive.catalog(book: .init(scope: scope, bookID: "book")) == nil)
    }

    @Test func supersededCatalogCannotReplaceNewerCatalog() async throws {
        let archive = try SourceArchive(url: database()), provider = try DelayedDomainProvider(scope: scope())
        let library = SourceLibraryService(archive: archive)
        let old = Task { try await library.refreshCatalog(provider: provider, book: .init(id: "book")) }
        await provider.waitForFirstCall()
        let new = try await library.refreshCatalog(provider: provider, book: .init(id: "book"))
        await provider.release()
        await #expect(throws: SourceDomainError.self) { try await old.value }
        let key = try SourceBookKey(scope: provider.descriptor.identity.scope, bookID: "book")
        #expect(new.chapters.first?.title == "new")
        #expect(try await archive.catalog(book: key) == new)
    }

    @Test func supersededChapterCannotReplaceNewerChapter() async throws {
        let archive = try SourceArchive(url: database()), provider = try DelayedDomainProvider(scope: scope())
        let library = SourceLibraryService(archive: archive)
        let old = Task { try await library.chapter(provider: provider, book: .init(id: "book"), chapter: .init(id: "chapter")) }
        await provider.waitForFirstCall()
        let new = try await library.chapter(provider: provider, book: .init(id: "book"), chapter: .init(id: "chapter"))
        await provider.release()
        await #expect(throws: SourceDomainError.self) { try await old.value }
        #expect(new.document.plainText == "new")
        #expect(try await archive.chapter(new.key, identity: provider.descriptor.identity) == new)
    }

    @Test func sourceHistoryConfigurationResetAndConflictRemainAtomic() async throws {
        let url = database(), archive = try SourceArchive(url: url)
        let original = try SourceInstallation(publisherID: "org.example", name: "Original", version: "1", source: "original",
            origins: ["https://example.org"], originURL: "https://example.org/source.js")
        let scope = try SourceScope(installationID: original.id)
        try await archive.saveInstallation(original)
        try await archive.saveConfiguration(.object(["theme": .string("dark")]), scope: scope)
        let state = try await archive.setState(scope: scope, key: "keep", value: .number(1))
        let updated = try SourceInstallation(id: original.id, publisherID: original.publisherID, name: "Updated", version: "2", source: "updated",
            origins: original.origins, locallyModified: true)
        try await archive.saveInstallation(updated, replacing: original.digest, resetConfigurationFor: scope)
        #expect(try await archive.configuration(scope: scope) == .object([:]))
        #expect(try await archive.installationHistory(original.id) == [original])
        await #expect(throws: SourceDomainError.self) {
            try await archive.saveInstallation(original, replacing: original.digest, resetConfigurationFor: scope)
        }
        await #expect(throws: SourceDomainError.self) {
            try await archive.saveConfiguration(.object(["obsolete": .bool(true)]), scope: scope, expectedSourceDigest: original.digest)
        }
        #expect(try await archive.installationHistory(original.id) == [original])
        #expect(try await archive.configuration(scope: scope) == .object([:]))
        try await archive.saveInstallation(original, replacing: updated.digest)
        let reopened = try SourceArchive(url: url)
        #expect(try await reopened.installation(original.id) == original)
        #expect(try await reopened.installationHistory(original.id).first == updated)
        #expect(try await reopened.state(scope: scope, key: "keep") == state)
    }

    @Test func replacementCannotChangePublisherAndLegacyInstallationsDecode() async throws {
        let archive = try SourceArchive(url: database())
        let original = try SourceInstallation(publisherID: "org.example", name: "Original", version: "1", source: "original", origins: ["https://example.org"])
        try await archive.saveInstallation(original)
        let foreign = try SourceInstallation(id: original.id, publisherID: "org.other", name: "Other", version: "2", source: "other", origins: original.origins)
        await #expect(throws: SourceDomainError.self) { try await archive.saveInstallation(foreign, replacing: original.digest) }
        #expect(try await archive.installationHistory(original.id).isEmpty)
        var json = try #require(JSONSerialization.jsonObject(with: SourceCoding.encode(original)) as? [String: Any])
        json.removeValue(forKey: "originURL"); json.removeValue(forKey: "locallyModified")
        let restored = try SourceCoding.decode(SourceInstallation.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(restored.id == original.id)
        #expect(restored.locallyModified == nil && restored.originURL == nil)
    }

}
