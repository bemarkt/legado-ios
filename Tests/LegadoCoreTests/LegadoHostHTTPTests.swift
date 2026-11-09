import Foundation
import Testing
@testable import LegadoCore

struct LegadoHostHTTPTests {
    private func archive() throws -> SourceArchive {
        try .init(url: FileManager.default.temporaryDirectory.appendingPathComponent("legacy-http-\(UUID().uuidString)/archive.sqlite"))
    }
    private func installation(origin: String, search: String = "/search") throws -> SourceInstallation {
        var source = BookSource(bookSourceUrl: origin, bookSourceName: "HTML fixture")
        source.searchUrl = search
        source.ruleSearch = .init(bookList: "@css:.book", name: "@css:a@text", author: "@css:.author@text", bookUrl: "@css:a@href")
        var detail = BookInfoRule(); detail.name = "@css:h1@text"; detail.tocUrl = "@css:.toc@href"; source.ruleBookInfo = detail
        var toc = TocRule(); toc.chapterList = "@css:.chapter"; toc.chapterName = "@css:a@text"; toc.chapterUrl = "@css:a@href"
        toc.nextTocUrl = "@css:.next@href"; source.ruleToc = toc
        var content = ContentRule(); content.content = "@css:#content@text"; content.nextContentUrl = "@css:.next@href"; source.ruleContent = content
        return try .init(publisherID: "fixture.html", name: source.bookSourceName, version: "1",
                         source: String(decoding: SourceCoding.encode(source), as: UTF8.self), origins: [origin], format: .legado)
    }
    private func wait(_ condition: @escaping @Sendable () async -> Bool) async throws {
        for _ in 0..<300 { if await condition() { return }; try await Task.sleep(for: .milliseconds(10)) }
        Issue.record("Timed out waiting for the HTTP fixture")
    }

    @Test func actualHTTPHTMLProviderReadsTwoCatalogPagesAndJoinedContent() async throws {
        let server = try NativeHTTPFixture { request in
            let html: String
            switch request.target {
            case "/search": return .init(status: 302, headers: ["Location": "/results", "Set-Cookie": "session=guest; Path=/"], body: Data())
            case "/results":
                guard request.headers["cookie"] == "session=guest" else { return .init(status: 403) }
                html = "<div class='book'><a href='/book'>山海</a><span class='author'>作者</span></div>"
            case "/book": html = "<h1>山海</h1><a class='toc' href='/toc/1'>目录</a>"
            case "/toc/1": html = "<div class='chapter'><a href='/one'>第一章</a></div><a class='next' href='/toc/2'>下一页</a>"
            case "/toc/2": html = "<div class='chapter'><a href='/two'>第二章</a></div>"
            case "/one": html = "<div id='content'>上半段</div><a class='next' href='/one-2'>下一页</a>"
            case "/one-2": html = "<div id='content'>下半段</div>"
            case "/two": html = "<div id='content'>另一章</div>"
            default: return .init(status: 404)
            }
            return .init(headers: ["Content-Type": "text/html; charset=utf-8"], body: Data(html.utf8))
        }
        let origin = try await server.start(); defer { server.stop() }
        let archive = try archive(), installation = try installation(origin: origin)
        try await archive.saveInstallation(installation)
        let provider = try LegadoProviderHost.makeProvider(installation: installation,
            scope: .init(installationID: installation.id), archive: archive, allowLoopbackHTTP: true)
        let search = try await provider.search(.init(query: "山海"))
        #expect(search.items.map(\.title) == ["山海"])
        let service = SourceLibraryService(archive: archive)
        let book = try await service.addBook(provider: provider, ref: search.items[0].ref)
        let catalog = try await service.refreshCatalog(provider: provider, book: book.details.ref)
        #expect(catalog.chapters.map(\.title) == ["第一章", "第二章"])
        #expect(try await service.download(provider: provider, catalog: catalog) == 2)
        let content = try await service.chapter(provider: provider, book: book.details.ref, chapter: catalog.chapters[0].ref)
        #expect(content.document.plainText.contains("上半段")); #expect(content.document.plainText.contains("下半段"))
        #expect(await server.statistics().requests.count == 8)
    }

    @Test func redirectsStripExplicitCookiesAndLoadEachOriginsCredentials() async throws {
        let destination = try NativeHTTPFixture { request in .init(body: Data((request.headers["cookie"] ?? "empty").utf8)) }
        let b = try await destination.start(); defer { destination.stop() }
        let first = try NativeHTTPFixture { _ in .init(status: 302, headers: ["Location": b + "/final", "Set-Cookie": "rotated=a; Path=/"], body: Data("redirect-body".utf8)) }
        let a = try await first.start(); defer { first.stop() }
        let scope = try SourceScope(installationID: UUID(), accountID: "alice")
        let vault = SourceCredentialVault(persistence: MemorySourceCredentials())
        let session = try await vault.session(scope: scope, allowedOrigins: [a,b])
        try await session.receive([.init(origin: a, name: "session", value: "a", secure: false),
                                   .init(origin: b, name: "session", value: "b", secure: false)])
        let control = JavaScriptExecutionControl(gate: session.commitGate)
        let policy = SourceHostHTTPPolicy(origins: [a,b], allowLoopbackHTTP: true, maximumAttempts: 1)
        let cookies = LegadoScopedCookies(jar: try .init(scope: scope, origins: [a,b], credentials: session), policy: policy, control: control)
        var request = URLRequest(url: URL(string: a + "/start")!); request.setValue("explicit=private", forHTTPHeaderField: "Cookie")
        let client = SourceHostHTTPClient()
        let response = try await client.fetchCompatibility(request, followRedirects: true, policy: policy, deadline: control.deadline,
                                                           budget: .init(maximumRequests: 3), credentials: cookies)
        #expect(response.decodedText == "session=b")
        #expect(await first.statistics().requests.first?.headers["cookie"] == "session=a; explicit=private")
        #expect(try await session.headers(for: URL(string: a)!)["Cookie"]?.contains("rotated=a") == true)
        let manual = try await client.fetchCompatibility(request, followRedirects: false, policy: policy, deadline: control.deadline,
                                                         budget: .init(maximumRequests: 1), credentials: cookies)
        #expect(manual.statusCode == 302); #expect(manual.decodedText == "redirect-body")
        #expect(manual.headers["set-cookie"] == "rotated=a; Path=/")
        #expect(await destination.statistics().requests.count == 1)
    }

    @Test func sameWebsiteCookiesPersistForOneAccountAndNeverReachAnother() async throws {
        let server = try NativeHTTPFixture { request in
            if request.target == "/login" { return .init(headers: ["Set-Cookie": "session=alice; Path=/"], body: Data()) }
            return .init(body: Data((request.headers["cookie"] ?? "guest").utf8))
        }
        let origin = try await server.start(); defer { server.stop() }
        let persistence = MemorySourceCredentials(), vault = SourceCredentialVault(persistence: persistence)
        let alice = try SourceScope(installationID: UUID(), accountID: "alice")
        let session = try await vault.session(scope: alice, allowedOrigins: [origin])
        let control = JavaScriptExecutionControl(gate: session.commitGate)
        let policy = SourceHostHTTPPolicy(origins: [origin], allowLoopbackHTTP: true, maximumAttempts: 1)
        let jar = try LegadoCookieJar(scope: alice, origins: [origin], credentials: session)
        let cookies = LegadoScopedCookies(jar: jar, policy: policy, control: control), client = SourceHostHTTPClient()
        _ = try await client.fetchCompatibility(.init(url: URL(string: origin + "/login")!), followRedirects: true,
            policy: policy, deadline: control.deadline, budget: .init(maximumRequests: 4), credentials: cookies)
        let reopened = SourceCredentialVault(persistence: persistence)
        let restored = try await reopened.session(scope: alice, allowedOrigins: [origin])
        #expect(try await restored.headers(for: URL(string: origin)!)["Cookie"] == "session=alice")
        let bob = try await vault.session(scope: .init(installationID: alice.installationID, accountID: "bob"), allowedOrigins: [origin])
        #expect(try await bob.headers(for: URL(string: origin)!).isEmpty)
        try await RuleExecutionWorker.run { try cookies.removeCookies(for: origin) }
        #expect(try await session.headers(for: URL(string: origin)!).isEmpty)
        control.cancel()
        await #expect(throws: CancellationError.self) { try await cookies.receive([.init(origin: origin, name: "late", value: "x", secure: false)]) }
        #expect(try await session.headers(for: URL(string: origin)!).isEmpty)
    }

    @Test func realProviderCancellationClosesTheNetworkAndDoesNotSaveLateCookies() async throws {
        let server = try NativeHTTPFixture { _ in .init(headers: ["Set-Cookie": "late=forbidden; Path=/"], delay: 1) }
        let origin = try await server.start(); defer { server.stop() }
        let archive = try archive(), installation = try installation(origin: origin)
        try await archive.saveInstallation(installation)
        let account = try await archive.addAccount(name: "Alice", installationID: installation.id)
        try await archive.selectAccount(account.id, installationID: installation.id)
        let scope = try SourceScope(installationID: installation.id, accountID: account.id)
        let vault = SourceCredentialVault(persistence: MemorySourceCredentials())
        let session = try await vault.session(scope: scope, allowedOrigins: [origin])
        let scheduler = SourceWorkScheduler(globalLimit: 1, perOriginLimit: 1)
        let provider = try LegadoProviderHost.makeProvider(installation: installation, scope: scope, archive: archive,
            credentials: session, client: .init(scheduler: scheduler), allowLoopbackHTTP: true)
        let task = Task { try await provider.search(.init(query: "q")) }
        try await wait { await server.statistics().requests.count == 1 }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        try await wait {
            let active = await server.statistics().active
            let slots = await scheduler.counts.active
            return active == 0 && slots == 0
        }
        #expect(try await session.headers(for: URL(string: origin)!).isEmpty)
    }

    @Test func realRedirectAttemptsShareTheOperationBudget() async throws {
        let server = try NativeHTTPFixture { request in .init(status: 302, headers: ["Location": "/next-\(request.occurrence)"], body: Data()) }
        let origin = try await server.start(); defer { server.stop() }
        let scope = try SourceScope(installationID: UUID()), control = JavaScriptExecutionControl()
        let policy = SourceHostHTTPPolicy(origins: [origin], allowLoopbackHTTP: true, maximumAttempts: 1)
        let cookies = LegadoScopedCookies(jar: try .init(scope: scope, origins: [origin], credentials: nil), policy: policy, control: control)
        await #expect(throws: SourceHostHTTPFailure.self) {
            try await SourceHostHTTPClient().fetchCompatibility(.init(url: URL(string: origin + "/start")!), followRedirects: true,
                policy: policy, deadline: control.deadline, budget: .init(maximumRequests: 2), credentials: cookies)
        }
        #expect(await server.statistics().requests.count == 2)
    }
}
