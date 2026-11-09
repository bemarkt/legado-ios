import Foundation
import Testing
@testable import LegadoCore

private final class LegadoStateFixture: JavaScriptSourceState, JavaScriptCookieState, @unchecked Sendable {
    private let lock = NSLock()
    private var state: [String: String] = [:]
    func get(sourceID: String, key: String) throws -> String { lock.withLock { state[key] ?? "" } }
    func put(sourceID: String, key: String, value: String) throws { lock.withLock { state[key] = value } }
    func loginHeaders(sourceID: String) throws -> [String: String] { [:] }
    func cookieHeader(for value: String) throws -> String { "" }
    func cookie(for value: String, key: String) throws -> String { "" }
    func setCookie(_ cookie: String, for value: String) throws { }
    func removeCookies(for value: String) throws { }
}
private actor LegadoFlowFixture {
    var requests: [URLRequest] = []
    var cancelled = false
    private var slowStarted = false
    private var waiter: CheckedContinuation<Void, Never>?
    var offline = false
    var failSecondContentPage = false
    var loopCatalog = false
    var loopContent = false
    var changedTitles = false
    var emptyResponse = false
    var htmlExtraction = false
    func useHTMLExtraction() { htmlExtraction = true }
    func useEmptyResponse(_ enabled: Bool) { emptyResponse = enabled }
    func setOffline() { offline = true }
    func failPage() { failSecondContentPage = true }
    func setCatalogLoop() { loopCatalog = true }
    func setContentLoop() { loopContent = true }
    func rename() { changedTitles = true }
    func waitForSlowRequest() async {
        if slowStarted { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func fetch(_ request: URLRequest, follow: Bool) async throws -> HTTPResponse {
        let url = try #require(request.url)
        #expect(!request.httpShouldHandleCookies)
        requests.append(request)
        if offline { throw URLError(.notConnectedToInternet) }
        if emptyResponse { return .init(data: Data("<html><body><script src='/verification.js'></script></body></html>".utf8), statusCode: 202, headers: ["Content-Type": "text/html"], finalURL: url) }
        if htmlExtraction && (url.path.hasPrefix("/toc/") || url.path.hasPrefix("/chapter/")) {
            let html = url.path.hasPrefix("/toc/") ? "<ul><li class='chapter'><a href='/chapter/a'>First chapter</a></li></ul>" : "<article><p>Saved chapter text.</p></article>"
            return .init(data: Data(html.utf8), statusCode: 200, headers: ["Content-Type": "text/html"], finalURL: url)
        }
        if url.path == "/slow" {
            slowStarted = true; waiter?.resume(); waiter = nil
            do { try await Task.sleep(for: .seconds(10)) }
            catch { cancelled = true; throw error }
        }
        let text: String
        switch url.path {
        case "/search":
            let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "page" }?.value
            #expect(page == "1" || page == "2")
            text = page == "2" ? #"{"items":[]}"# : #"{"items":[{"title":"同名书","author":"作者","url":"/book/a"}]}"#
        case "/book/a": text = #"{"title":"详情书名","author":"作者","toc":"/toc/1"}"#
        case "/toc/1": text = #"{"items":[{"name":"同名章","url":"/chapter/a"}],"next":["/toc/2"]}"#
        case "/toc/2":
            text = loopCatalog ? #"{"items":[],"next":["/toc/1"]}"# : #"{"items":[{"name":"同名章","url":"/chapter/b"}],"next":[]}"#
        case "/chapter/a": text = #"{"text":"第一段 😀","next":["/chapter/a-2"]}"#
        case "/chapter/a-2":
            if failSecondContentPage { throw URLError(.networkConnectionLost) }
            text = loopContent ? #"{"text":"第二段","next":["/chapter/a"]}"# : #"{"text":"第二段","next":[]}"#
        case "/chapter/b": text = #"{"text":"另一章正文","next":[]}"#
        case "/status": return .init(data: Data("failure".utf8), statusCode: 503, headers: [:], finalURL: url)
        default: throw URLError(.badURL)
        }
        return .init(data: Data((changedTitles ? text.replacingOccurrences(of: "同名章", with: "改名章") : text).utf8),
                     statusCode: 200, headers: ["Content-Type": "application/json; charset=utf-8"], finalURL: url)
    }
}

struct LegadoSourceProviderTests {
    @Test func emptyWebsitePagesPreserveCatalogAndOfflineTextAndReportExtractionFacts() async throws {
        let fixture = LegadoFlowFixture()
        await fixture.useHTMLExtraction()
        var source = self.source()
        var toc = TocRule(); toc.chapterList = "@css:.chapter"; toc.chapterName = "@css:a@text"; toc.chapterUrl = "@css:a@href"
        source.ruleToc = toc
        var content = ContentRule(); content.content = "@css:article@text"; source.ruleContent = content
        let provider = try self.provider(fixture, source: source)
        let archive = try SourceArchive(url: FileManager.default.temporaryDirectory.appendingPathComponent("empty-website-\(UUID().uuidString)/library.sqlite"))
        let library = SourceLibraryService(archive: archive)
        let search = try await provider.search(.init(query: "fixture"))
        let book = try await library.addBook(provider: provider, ref: search.items[0].ref)
        let catalog = try await library.refreshCatalog(provider: provider, book: book.details.ref)
        let cached = try await library.chapter(provider: provider, book: book.details.ref, chapter: catalog.chapters[0].ref, catalog: catalog, retainOffline: true)
        await fixture.useEmptyResponse(true)
        do {
            _ = try await library.refreshCatalog(provider: provider, book: book.details.ref)
            Issue.record("Blank website replaced the catalog")
        } catch let error as SourceExtractionFailure {
            #expect(error.context.field == .catalog && error.context.httpStatus == 202)
            #expect(error.context.responseBytes! > 0)
        }
        do {
            _ = try await library.chapter(provider: provider, book: book.details.ref, chapter: catalog.chapters[0].ref, policy: .reload)
            Issue.record("Blank website replaced the saved chapter")
        } catch let error as SourceExtractionFailure {
            #expect(error.issue.code == "EMPTY_CONTENT")
        }
        #expect(try await archive.catalog(book: book.key) == catalog)
        #expect(try await library.chapter(provider: provider, book: book.details.ref, chapter: catalog.chapters[0].ref, policy: .offline) == cached)
        let records = await SourceDiagnostics.shared.records().filter { $0.sourceDigest == provider.descriptor.identity.sourceDigest && $0.extraction != nil }
        #expect(records.contains { $0.code == "EMPTY_CATALOG" && $0.extraction?.httpStatus == 202 })
        #expect(records.contains { $0.code == "EMPTY_CONTENT" && $0.extraction?.field == .content })
    }
    private func source() -> BookSource {
        var source = BookSource(bookSourceUrl: "https://fixture.invalid", bookSourceName: "Synthetic legacy source")
        source.searchUrl = "/search?q={{key}}&page={{page}}"
        source.ruleSearch = .init(bookList: "$.items[*]", name: "$.title", author: "$.author",
                                  bookUrl: "$.url@js:java.put('seed','carry');result")
        var info = BookInfoRule(); info.name = "$.title"; info.author = "$.author"
        info.tocUrl = "$.toc@js:if(java.get('seed')!=='carry')throw new Error('lost reference variables');result"
        source.ruleBookInfo = info
        var toc = TocRule(); toc.chapterList = "$.items[*]"; toc.chapterName = "$.name"
        toc.chapterUrl = "$.url"; toc.nextTocUrl = "$.next[*]"; source.ruleToc = toc
        var content = ContentRule(); content.content = "$.text"; content.nextContentUrl = "$.next[*]"; source.ruleContent = content
        return source
    }
    private func provider(_ fixture: LegadoFlowFixture, scope: SourceScope = try! .init(installationID: UUID()),
                          gate: SourceCommitGate? = nil, source: BookSource? = nil) throws -> LegadoSourceProvider {
        let state = LegadoStateFixture(), source = source ?? self.source()
        let descriptor = SourceProviderDescriptor(identity: try .init(scope: scope,
            sourceDigest: SourceCoding.digest(try SourceCoding.encode(source)), configuration: .object([:])), name: source.bookSourceName, commitGate: gate)
        return try .init(source: source, descriptor: descriptor) { control, _ in
            let loader = LegadoAsyncNetworkLoader(control: control) { request, follow in try await fixture.fetch(request, follow: follow) }
            return .init(sourceState: state, cookies: state, control: control, network: loader,
                         userAgent: "LegadoFixture", identifier: { scope.installationID.uuidString + scope.accountID })
        }
    }

    @Test func completeFlowPersistsReferencesCatalogContentAndProgressWithoutTheSearchVM() async throws {
        let fixture = LegadoFlowFixture(), scope = try SourceScope(installationID: UUID())
        let initial = try provider(fixture, scope: scope)
        let search = try await initial.search(.init(query: "山海"))
        #expect(search.items.count == 1)
        #expect(try await initial.search(.init(query: "山海", cursor: search.nextCursor)).items.isEmpty)
        let encoded = try SourceCoding.encode(search.items[0].ref)
        let restoredRef = try SourceCoding.decode(SourceWire.SourceRef.self, from: encoded)
        let restarted = try provider(fixture, scope: scope)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-provider-\(UUID().uuidString)/library.sqlite")
        let archive = try SourceArchive(url: url), service = SourceLibraryService(archive: archive)
        let book = try await service.addBook(provider: restarted, ref: restoredRef)
        #expect(book.details.title == "详情书名")
        #expect(book.details.ref.id == restoredRef.id)
        let catalog = try await service.refreshCatalog(provider: restarted, book: book.details.ref)
        #expect(catalog.chapters.map(\.title) == ["同名章", "同名章"])
        #expect(Set(catalog.chapters.map { $0.ref.id }).count == 2)
        #expect(try await service.download(provider: restarted, catalog: catalog) == 2)
        let cached = try await service.chapter(provider: restarted, book: book.details.ref, chapter: catalog.chapters[0].ref)
        #expect(cached.document.plainText.contains("第一段 😀"))
        #expect(cached.document.plainText.contains("第二段"))
        let anchor = SourceReadingAnchor(chapter: cached.key, document: cached.document, offsetUTF16: 3)
        try await archive.saveAnchor(anchor)
        let count = await fixture.requests.count
        await fixture.setOffline()
        let reopened = try SourceArchive(url: url), resumed = SourceLibraryService(archive: reopened)
        #expect(try await reopened.books(scope: scope) == [book])
        #expect(try await reopened.anchor(book: book.key) == anchor)
        let offline = try await resumed.chapter(provider: restarted, book: book.details.ref, chapter: catalog.chapters[0].ref, policy: .offline)
        #expect(offline == cached)
        #expect(await fixture.requests.count == count)
    }

    @Test func installationReferencesCursorsAndQueryBindingsCannotCrossScopes() async throws {
        let fixture = LegadoFlowFixture(), scope = try SourceScope(installationID: UUID(), accountID: "alice")
        let alice = try provider(fixture, scope: scope)
        let search = try await alice.search(.init(query: "q"))
        let bob = try provider(fixture, scope: .init(installationID: UUID(), accountID: "bob"))
        await #expect(throws: SourceDomainError.self) { try await bob.book(.init(ref: search.items[0].ref)) }
        await #expect(throws: SourceDomainError.self) { try await bob.search(.init(query: "q", cursor: search.nextCursor)) }
        await #expect(throws: SourceDomainError.self) { try await alice.search(.init(query: "other", cursor: search.nextCursor)) }
        let changed = SourceWire.SourceRef(id: search.items[0].ref.id, url: "https://fixture.invalid/book/b", state: search.items[0].ref.state)
        await #expect(throws: SourceDomainError.self) { try await alice.book(.init(ref: changed)) }
        #expect(await fixture.requests.count == 1)
    }

    @Test func chapterIdentitySurvivesTitleChangesAndPaginationLoopsFail() async throws {
        let fixture = LegadoFlowFixture(), provider = try self.provider(fixture)
        let search = try await provider.search(.init(query: "q"))
        let book = try await provider.book(.init(ref: search.items[0].ref))
        let before = try await SourceCatalogLoader().load(provider: provider, book: book.ref)
        await fixture.rename()
        let after = try await SourceCatalogLoader().load(provider: provider, book: book.ref)
        #expect(before.chapters.map { $0.ref.id } == after.chapters.map { $0.ref.id })
        #expect(before.chapters.map(\.title) != after.chapters.map(\.title))
        await fixture.setCatalogLoop()
        await #expect(throws: SourceDomainError.self) { try await SourceCatalogLoader().load(provider: provider, book: book.ref) }
    }

    @Test func failedOrLoopingContentNeverReturnsPartialChapterSuccess() async throws {
        let fixture = LegadoFlowFixture(), provider = try self.provider(fixture)
        let search = try await provider.search(.init(query: "q"))
        let book = try await provider.book(.init(ref: search.items[0].ref))
        let catalog = try await SourceCatalogLoader().load(provider: provider, book: book.ref)
        await fixture.setContentLoop()
        await #expect(throws: SourceDomainError.self) { try await provider.content(.init(book: book.ref, chapter: catalog.chapters[0].ref)) }
        await fixture.failPage()
        await #expect(throws: URLError.self) { try await provider.content(.init(book: book.ref, chapter: catalog.chapters[0].ref)) }
    }

    @Test func cancellationReachesActiveAsyncNetworkAndNewOperationStillWorks() async throws {
        let fixture = LegadoFlowFixture()
        var source = self.source(); source.searchUrl = "/slow"
        let provider = try self.provider(fixture, source: source)
        let task = Task { try await provider.search(.init(query: "q")) }
        await fixture.waitForSlowRequest()
        let start = ContinuousClock.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(start.duration(to: .now) < .seconds(2))
        // Give the async child its cancellation turn; do not require a particular executor order.
        for _ in 0..<100 {
            if await fixture.cancelled { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await fixture.cancelled)
        let fresh = try self.provider(fixture)
        #expect(try await fresh.search(.init(query: "q")).items.count == 1)
    }

    @Test func scopeRevocationCancelsBlockedNetworkAndRejectsLateResult() async throws {
        let fixture = LegadoFlowFixture(), gate = SourceCommitGate()
        var source = self.source(); source.searchUrl = "/slow"
        let provider = try self.provider(fixture, gate: gate, source: source)
        let task = Task { try await provider.search(.init(query: "q")) }
        await fixture.waitForSlowRequest(); gate.invalidate()
        await #expect(throws: SourceDomainError.self) { try await task.value }
        let count = await fixture.requests.count
        await #expect(throws: SourceDomainError.self) { try await provider.search(.init(query: "q")) }
        #expect(await fixture.requests.count == count)
    }

    @Test func sourceRetryCannotExceedHostOperationRequestBudget() async throws {
        let fixture = LegadoFlowFixture()
        var source = self.source(); source.searchUrl = #"/status,{"retry":999999}"#
        let provider = try self.provider(fixture, source: source)
        await #expect(throws: SourceDomainError.self) { try await provider.search(.init(query: "q")) }
        #expect(await fixture.requests.count == 64)
    }
}
