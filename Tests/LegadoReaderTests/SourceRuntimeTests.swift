import XCTest
import WebKit
@testable import Legado

@MainActor
final class SourceRuntimeTests: XCTestCase {
    private let origin = "http://127.0.0.1:18764"

    private func fixture(_ file: String) throws -> Data {
        let bundle = Bundle(for: Self.self)
        let url = try XCTUnwrap(bundle.url(forResource: file, withExtension: nil, subdirectory: "fixtures"))
        return try Data(contentsOf: url)
    }
    private func json(_ value: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }
    private func object(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }
    private func source(_ operationBody: String, topLevel: String = "") async throws -> SourceSnapshot {
        let source = """
        export const metadata = {apiVersion:1,id:'org.example.runtime',name:'Runtime test',version:'1.0.0',origins:['\(origin)']};
        \(topLevel)
        export async function search(ctx, input) { \(operationBody) }
        export async function book() { return {ref:{id:'b'},title:'Book'}; }
        export async function chapters() { return {items:[],nextCursor:null}; }
        export async function content() { return {body:{kind:'text',text:'Text'}}; }
        """
        return try await SourceInspector().inspect(Data(source.utf8))
    }
    private func run(_ snapshot: SourceSnapshot, timeoutMs: Int? = nil) async throws -> String {
        try await SourceRuntime().run(.search, inputJSON: #"{"query":"fixture"}"#, snapshot: snapshot,
                                      allowLoopbackHTTP: true, timeoutMs: timeoutMs)
    }
    private func expectFailure(_ code: String, _ operation: () async throws -> String,
                               file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await operation(); XCTFail("Expected \(code)", file: file, line: line) }
        catch let failure as SourceFailure { XCTAssertEqual(failure.code, code, failure.localizedDescription, file: file, line: line) }
        catch { XCTFail("Unexpected error: \(error)", file: file, line: line) }
    }

    func testStaticCorpusOnActualWebKitNeverExecutesInput() async throws {
        struct Sample: Decodable { let name: String; let source: String; let valid: Bool?; let code: String?; let unsupported: [String]? }
        let cases = try JSONDecoder().decode([Sample].self, from: fixture("static-cases.json"))
        XCTAssertEqual(cases.count, 25)
        for sample in cases {
            do {
                let snapshot = try await SourceInspector().inspect(Data(sample.source.utf8))
                XCTAssertEqual(sample.valid, true, sample.name)
                XCTAssertEqual(snapshot.inspection.unsupportedRequirements, sample.unsupported ?? [], sample.name)
                XCTAssertEqual(snapshot.sha256.count, 64)
            } catch let failure as SourceFailure {
                XCTAssertEqual(failure.code, sample.code, sample.name + ": " + failure.localizedDescription)
                XCTAssertNotNil(failure.line, sample.name)
            }
        }
    }

    func testHTMLAndJSONFullFlowWithFreshPagePerOperation() async throws {
        for name in ["html.source.js", "json.source.js"] {
            let snapshot = try await SourceInspector().inspect(fixture(name))
            let runtime = try SourceRuntime()
            let search = try object(await runtime.run(.search, inputJSON: #"{"query":"fixture"}"#, snapshot: snapshot, allowLoopbackHTTP: true))
            let books = try XCTUnwrap(search["items"] as? [[String: Any]])
            XCTAssertEqual(books.first?["title"] as? String, "Fixture Book")
            let ref = try XCTUnwrap(books.first?["ref"] as? [String: Any])
            let book = try object(await runtime.run(.book, inputJSON: json(["ref": ref]), snapshot: snapshot, allowLoopbackHTTP: true))
            XCTAssertEqual(book["title"] as? String, "Fixture Book")
            let first = try object(await runtime.run(.chapters, inputJSON: json(["book": ref]), snapshot: snapshot, allowLoopbackHTTP: true))
            let firstItems = try XCTUnwrap(first["items"] as? [[String: Any]])
            let cursor = try XCTUnwrap(first["nextCursor"] as? [String: Any])
            let second = try object(await runtime.run(.chapters, inputJSON: json(["book": ref, "cursor": cursor]), snapshot: snapshot, allowLoopbackHTTP: true))
            XCTAssertTrue(second["nextCursor"] is NSNull)
            let secondItems = try XCTUnwrap(second["items"] as? [[String: Any]])
            let chapters = firstItems + secondItems
            XCTAssertEqual(chapters.count, 2)
            XCTAssertEqual(first["revision"] as? String, "r1")
            for (index, chapter) in chapters.enumerated() {
                let chapterRef = try XCTUnwrap(chapter["ref"] as? [String: Any])
                XCTAssertEqual(chapterRef["id"] as? String, "ch-\(index + 1)")
                // Re-create the host as well: persisted JSON references require no previous VM.
                let content = try object(await SourceRuntime().run(.content, inputJSON: json(["book": ref, "chapter": chapterRef]), snapshot: snapshot, allowLoopbackHTTP: true))
                XCTAssertEqual(content["title"] as? String, "Chapter \(index + 1)")
                let body = try XCTUnwrap(content["body"] as? [String: Any])
                XCTAssertEqual(body["kind"] as? String, name.hasPrefix("html") ? "html" : "text")
                if name.hasPrefix("html") { XCTAssertFalse((body["html"] as? String ?? "").contains("<script")) }
                else { XCTAssertFalse((body["text"] as? String ?? "").isEmpty) }
            }
        }
    }

    func testOutputValidationCannotBeReplacedBySource() async throws {
        let invalid = try await source("return {items:[{ref:{id:'b'},title:' '}],nextCursor:null};",
                                       topLevel: "globalThis.SourceInspector = {validate: () => ({value:true})};")
        await expectFailure("INVALID_DATA") { try await self.run(invalid) }
    }

    func testHTTPResponseConsumptionStatusBodyAndEncoding() async throws {
        let snapshot = try await source("""
        const echo = await ctx.http.fetch('\(origin)/api/echo', {method:'POST',headers:{'Content-Type':'text/plain'},body:'中文 body'});
        const value = await echo.json();
        if (value.body !== '中文 body' || !echo.bodyUsed) throw Error('POST/bodyUsed failed');
        try { await echo.text(); throw Error('second consumption succeeded'); } catch (e) { if(e.code !== 'INVALID_INPUT') throw e; }
        const limited = await ctx.http.fetch('\(origin)/failure/rate-limited');
        if(limited.status !== 429 || limited.ok || limited.headers['retry-after'] !== '3') throw Error('HTTP status failed');
        const encoding = await ctx.http.fetch('\(origin)/encoding/utf16le');
        if(await encoding.text() !== '中文 fixture') throw Error('UTF16 failed');
        const invalid = await ctx.http.fetch('\(origin)/encoding/invalid-utf8');
        try { await invalid.text(); throw Error('bad UTF8 accepted'); } catch(e) { if(e.code !== 'PARSE') throw e; }
        return {items:[],nextCursor:null};
        """)
        _ = try await run(snapshot)
    }

    func testOriginsHeadersRedirectsAndBodyLimits() async throws {
        for (path, code) in [("/redirect/forbidden", "PERMISSION_DENIED"), ("/redirect/loop", "RESOURCE_LIMIT"),
                             ("/failure/oversized", "RESOURCE_LIMIT"), ("/failure/chunked-oversized", "RESOURCE_LIMIT")] {
            let snapshot = try await source("await ctx.http.fetch('\(origin)\(path)'); return {items:[],nextCursor:null};")
            await expectFailure(code) { try await self.run(snapshot) }
        }
        let allowed = try await source("const r = await ctx.http.fetch('\(origin)/redirect/allowed'); if(!r.url.endsWith('/health')) throw Error('redirect failed'); return {items:[],nextCursor:null};")
        _ = try await run(allowed)
        let denied = try await source("await ctx.http.fetch('\(origin)/redirect/allowed', {redirect:'error'}); return {items:[],nextCursor:null};")
        await expectFailure("NETWORK") { try await self.run(denied) }
        let header = try await source("await ctx.http.fetch('\(origin)/health', {headers:{Cookie:'secret'}}); return {items:[],nextCursor:null};")
        await expectFailure("INVALID_INPUT") { try await self.run(header) }
        let outside = try await source("await ctx.http.fetch('https://example.com/'); return {items:[],nextCursor:null};")
        await expectFailure("PERMISSION_DENIED") { try await self.run(outside) }
    }

    func testCookieDoesNotPersistOrLeakThroughResponse() async throws {
        let snapshot = try await source("""
        const login = await ctx.http.fetch('\(origin)/state/login');
        if('set-cookie' in login.headers) throw Error('Cookie leaked');
        const account = await ctx.http.fetch('\(origin)/state/account');
        if(account.status !== 401) throw Error('Unexpected persistent credential');
        return {items:[],nextCursor:null};
        """)
        _ = try await run(snapshot)
    }

    func testNeverSettlingOperationTimesOutAndNextPageRecovers() async throws {
        let bad = try await source("await new Promise(() => {});")
        await expectFailure("TIMEOUT") { try await self.run(bad, timeoutMs: 150) }
        let good = try await source("return {items:[],nextCursor:null};")
        _ = try await run(good)
    }

    func testCancellationAndUnawaitedHTTPLeaveNoActiveRequests() async throws {
        let bad = try await source("await ctx.http.fetch('\(origin)/failure/slow?ms=2000'); return {items:[],nextCursor:null};")
        let pending = Task { try await self.run(bad) }
        // Wait for actual native network entry; no assumption about WebContent cold startup duration.
        var observed = false
        for _ in 0..<100 {
            let (data, _) = try await URLSession.shared.data(from: URL(string: origin + "/diagnostics")!)
            let info = try object(String(decoding: data, as: UTF8.self))
            if (info["activeRequests"] as? Int ?? 0) > 0 { observed = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(observed, "Never observed native HTTP request")
        pending.cancel()
        await expectFailure("CANCELLED") { try await pending.value }
        let detached = try await source("ctx.http.fetch('\(origin)/failure/slow?ms=2000').catch(() => {}); return {items:[],nextCursor:null};")
        _ = try await run(detached)
        try await Task.sleep(for: .milliseconds(200))
        let (data, _) = try await URLSession.shared.data(from: URL(string: origin + "/diagnostics")!)
        let info = try object(String(decoding: data, as: UTF8.self))
        XCTAssertEqual(info["activeRequests"] as? Int, 0)
    }

    func testDirectWebAPIsAndSubresourcesCannotContactFixtureServer() async throws {
        let marker = UUID().uuidString
        let snapshot = try await source("""
        for(const key of ['fetch','XMLHttpRequest','WebSocket','EventSource','Worker','SharedWorker','RTCPeerConnection','WebTransport']) {
          if(globalThis[key] !== undefined) throw Error('Unrestricted API: ' + key);
        }
        try { new Function('return 1')(); throw Error('eval allowed'); } catch(e) { if(e.message === 'eval allowed') throw e; }
        const image = document.createElement('img'); image.src='\(origin)/blocked-\(marker)'; document.body.append(image);
        const frame = document.createElement('iframe'); frame.src='\(origin)/blocked-\(marker)'; document.body.append(frame);
        const script = document.createElement('script'); script.src='\(origin)/blocked-\(marker)'; document.head.append(script);
        await new Promise(resolve => setTimeout(resolve, 150));
        return {items:[{ref:{id:'apis'},title:typeof DOMParser + ':' + typeof TextDecoder + ':' + typeof AbortController}],nextCursor:null};
        """)
        let result = try object(await run(snapshot))
        let items = try XCTUnwrap(result["items"] as? [[String: Any]])
        XCTAssertEqual(items.first?["title"] as? String, "function:function:function")
        let (data, _) = try await URLSession.shared.data(from: URL(string: origin + "/diagnostics")!)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(marker))
    }

    func testBridgeRejectsForeignIdentityAndBoundsRequestCount() async throws {
        let snapshot = try await source("""
        const forged = await window.webkit.messageHandlers.sourceHost.postMessage(JSON.stringify({session:'other',operation:'other',id:'forged',method:'http',request:{url:'\(origin)/health',method:'GET',headers:{},redirect:'follow'}}));
        if(JSON.parse(forged).error?.code !== 'INVALID_INPUT') throw Error('Foreign bridge identity accepted');
        for(let n=0;n<64;n++) await ctx.http.fetch('\(origin)/health');
        try { await ctx.http.fetch('\(origin)/health'); throw Error('Request budget ignored'); }
        catch(e) { if(e.code !== 'RESOURCE_LIMIT') throw e; }
        return {items:[],nextCursor:null};
        """)
        _ = try await run(snapshot)
    }

    func testRequestAbortSignalDoesNotCancelOtherWork() async throws {
        let snapshot = try await source("""
        const abort = new AbortController();
        const pending = ctx.http.fetch('\(origin)/failure/slow?ms=2000', {signal:abort.signal});
        setTimeout(() => abort.abort(), 100);
        try { await pending; throw Error('Abort ignored'); } catch(e) { if(e.code !== 'CANCELLED') throw e; }
        const good = await ctx.http.fetch('\(origin)/health');
        if(!good.ok) throw Error('Operation did not recover');
        return {items:[],nextCursor:null};
        """)
        _ = try await run(snapshot)
    }

    func testGlobalsDoNotSurviveIntoNextOperation() async throws {
        let snapshot = try await source("globalThis.count=(globalThis.count ?? 0)+1; return {items:[{ref:{id:'n'},title:String(globalThis.count)}],nextCursor:null};")
        for _ in 0..<2 {
            let result = try object(await run(snapshot))
            let items = try XCTUnwrap(result["items"] as? [[String: Any]])
            XCTAssertEqual(items.first?["title"] as? String, "1")
        }
    }
}
