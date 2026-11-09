import XCTest
import WebKit
import SwiftUI
import UIKit
import Security
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
    private func source(_ operationBody: String, topLevel: String = "", settings: String = "{}") async throws -> SourceSnapshot {
        let source = """
        export const metadata = {apiVersion:1,id:'org.example.runtime',name:'Runtime test',version:'1.0.0',origins:['\(origin)'],settings:\(settings)};
        \(topLevel)
        export async function search(ctx, input) { \(operationBody) }
        export async function book() { return {ref:{id:'b'},title:'Book'}; }
        export async function chapters() { return {items:[],nextCursor:null}; }
        export async function content() { return {body:{kind:'text',text:'Text'}}; }
        """
        return try await SourceInspector().inspect(Data(source.utf8))
    }
    private func run(_ snapshot: SourceSnapshot, timeoutMs: Int? = nil) async throws -> String {
        try await SourceRuntime().run(.search, inputJSON: #"{"query":"demo"}"#, snapshot: snapshot,
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
            let search = try object(await runtime.run(.search, inputJSON: #"{"query":"demo"}"#, snapshot: snapshot, allowLoopbackHTTP: true))
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

    func testBridgeCountsRedirectHopsInsideOperationRequestBudget() async throws {
        let snapshot = try await source("""
        for(let n=0;n<32;n++) await ctx.http.fetch('\(origin)/redirect/allowed');
        try { await ctx.http.fetch('\(origin)/health'); throw Error('Redirect attempts were not counted'); }
        catch(error) { if(error.code !== 'RESOURCE_LIMIT') throw error; }
        return {items:[],nextCursor:null};
        """)
        _ = try await run(snapshot)
    }

    func testHTTPRetryPreservesResponseAndNeverReplaysPOST() async throws {
        func serverErrors() async throws -> Int {
            let (data, _) = try await URLSession.shared.data(from: URL(string: origin + "/diagnostics")!)
            let info = try object(String(decoding: data, as: UTF8.self))
            return (info["requests"] as? [[String: Any]] ?? []).filter { $0["path"] as? String == "/failure/server-error" }.count
        }
        let before = try await serverErrors()
        let snapshot = try await source("""
        for(const method of ['GET','POST']) {
          const response = await ctx.http.fetch('\(origin)/failure/server-error',{method});
          if(response.status !== 503 || response.ok) throw Error('HTTP failure status was lost');
          if((await response.json()).error !== 'unavailable') throw Error('HTTP failure body was lost');
        }
        return {items:[],nextCursor:null};
        """)
        _ = try await run(snapshot)
        let after = try await serverErrors()
        XCTAssertEqual(after - before, 3, "GET may retry once; POST must be sent only once")
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

    func testBridgeRejectsReplayMalformedMessagesAndCallsAfterFinish() async throws {
        let snapshot = try await source("return {items:[],nextCursor:null};")
        let profile = try SourceProfile.load()
        let bridge = SourceHostBridge(snapshot: snapshot, profile: profile, allowLoopbackHTTP: true, timeoutMs: 15000)
        let page = try SourceWebPage(script: "", bridge: bridge)
        bridge.page = page
        defer { bridge.finish() }
        let marker = UUID().uuidString
        let arguments: [String: Any] = ["session": bridge.session, "operation": bridge.operation, "origin": origin, "marker": marker]
        let result = try await page.perform("""
        const post = value => window.webkit.messageHandlers.sourceHost.postMessage(value).then(JSON.parse);
        const message = (method, id, extra={}) => ({session, operation, method, id, ...extra});
        const request = {url:origin+'/health?marker='+marker,method:'GET',headers:{},redirect:'follow'};
        const expect = async (value, code='INVALID_INPUT') => {
          const result = await post(typeof value === 'string' ? value : JSON.stringify(value));
          if(result.error?.code !== code) throw Error('Expected '+code+', got '+JSON.stringify(result));
        };
        await expect('not JSON');
        await expect(message('http','early',{request}));
        await expect(message('ready','wrong'));
        await expect(message('ready','ready',{request}));
        if((await post(JSON.stringify(message('ready','ready')))).error) throw Error('Ready rejected');
        await expect(message('ready','ready'));
        await expect(message('http','foreign-session',{session:'foreign',request}));
        await expect(message('http','foreign-operation',{operation:'foreign',request}));
        await expect(message('http','unknown-field',{request,extra:true}));
        await expect(message('http','unknown-request-field',{request:{...request,extra:true}}));
        await expect(message('http','malformed',{request:{...request,headers:[]}}));
        await expect(message('http','x'.repeat(129),{request}));
        await expect(message('abortHTTP','unknown'));
        const first = await post(JSON.stringify(message('http','once',{request})));
        if(first.status !== 200) throw Error('Initial request failed');
        await expect(message('http','once',{request}));
        await expect(message('abortHTTP','once',{request}));
        if((await post(JSON.stringify(message('abortHTTP','once')))).error) throw Error('Completed request cancellation rejected');
        const denied = {...request,url:'http://127.0.0.1:18765/denied'};
        await expect(message('http','denied',{request:denied}),'PERMISSION_DENIED');
        await expect(message('http','denied',{request:denied}));
        return 'passed';
        """, arguments: arguments, timeoutMs: 15000)
        XCTAssertEqual(result, "passed")
        bridge.finish()
        // Even if an old message reaches a page with a still-held bridge reference, the native operation has ended.
        let latePage = try SourceWebPage(script: "", bridge: bridge)
        bridge.page = latePage
        let late = try await latePage.perform("""
        const value = await window.webkit.messageHandlers.sourceHost.postMessage(JSON.stringify({session,operation,id:'late',method:'http',
          request:{url:origin+'/health?marker='+marker,method:'GET',headers:{},redirect:'follow'}}));
        return JSON.parse(value).error.code;
        """, arguments: arguments, timeoutMs: 2000)
        XCTAssertEqual(late, "INVALID_INPUT")
        let (data, _) = try await URLSession.shared.data(from: URL(string: origin + "/diagnostics")!)
        let diagnostics = try object(String(decoding: data, as: UTF8.self))
        let requests = try XCTUnwrap(diagnostics["requests"] as? [[String: Any]])
        XCTAssertEqual(requests.filter { ($0["path"] as? String ?? "").contains(marker) }.count, 1)
    }

    func testFailedRequestsConsumeBudgetAndNextOperationStartsFresh() async throws {
        let snapshot = try await source("""
        for(let index=0;index<64;index++) {
          try { await ctx.http.fetch('http://127.0.0.1:18765/denied'); throw Error('Denied origin accepted'); }
          catch(e) { if(e.code !== 'PERMISSION_DENIED') throw e; }
        }
        try { await ctx.http.fetch('\(origin)/health'); throw Error('Failed requests did not consume budget'); }
        catch(e) { if(e.code !== 'RESOURCE_LIMIT') throw e; }
        return {items:[],nextCursor:null};
        """)
        _ = try await run(snapshot)
        let good = try await source("const r=await ctx.http.fetch('\(origin)/health'); if(!r.ok) throw Error('Fresh budget failed'); return {items:[],nextCursor:null};")
        _ = try await run(good)
    }

    func testConfigurationDefaultsRemainTypedFrozenAndFresh() async throws {
        let snapshot = try await source("""
        if(!Object.isFrozen(ctx.config)) throw Error('Mutable config');
        if(ctx.config.label !== '' || ctx.config.enabled !== false || ctx.config.count !== 0 || ctx.config.mode !== 'slow') throw Error('Default values changed');
        try { ctx.config.count=99; } catch {}
        if(ctx.config.count !== 0) throw Error('Configuration mutation leaked');
        for(const work of [()=>ctx.storage.get('x'),()=>ctx.storage.set('x','y'),()=>ctx.storage.remove('x')]) {
          try { await work(); throw Error('Storage unexpectedly available'); } catch(e) { if(e.code !== 'UNSUPPORTED') throw e; }
        }
        return {items:[],nextCursor:null};
        """, settings: """
        {label:{type:'text',label:'Label',default:'',maxLength:20},enabled:{type:'boolean',label:'Enabled',default:false},
         count:{type:'number',label:'Count',default:0,minimum:0,maximum:10},
         mode:{type:'enum',label:'Mode',default:'slow',options:[{value:'fast',label:'Fast'},{value:'slow',label:'Slow'}]}}
        """)
        for _ in 0..<2 { _ = try await run(snapshot) }
    }

    func testErrorHelpersAndRetryDelaySurviveNativeBoundary() async throws {
        let snapshot = try await source("""
        for(const [status,code] of [[401,'AUTH_REQUIRED'],[403,'HTTP'],[429,'RATE_LIMITED'],[503,'HTTP']]) {
          if(ctx.errors.http({status}).code !== code) throw Error('Wrong status mapping');
        }
        for(const details of [{status:0},{status:600},{status:429,retryAfterMs:-1},{status:429,retryAfterMs:1.5},{status:429,retryAfterMs:86400001}]) {
          if(ctx.errors.http(details).code !== 'INVALID_INPUT') throw Error('Invalid error metadata accepted');
        }
        if(ctx.errors.parse({field:'body',message:'Missing'}).message !== 'body: Missing') throw Error('Lost parse field');
        if(ctx.errors.authRequired().code !== 'AUTH_REQUIRED') throw Error('Wrong authentication code');
        const response=await ctx.http.fetch('\(origin)/failure/rate-limited');
        throw ctx.errors.http({status:response.status,retryAfterMs:Number(response.headers['retry-after'])*1000});
        """)
        do { _ = try await run(snapshot); XCTFail("Expected rate limit") }
        catch let error as SourceFailure {
            XCTAssertEqual(error.code, "RATE_LIMITED")
            XCTAssertEqual(error.message, "HTTP 429")
            XCTAssertEqual(error.retryAfterMs, 3000)
        }
    }

    func testMalformedThrownValuesBecomeBoundedScriptErrors() async throws {
        let snapshot = try await source("""
        if(input.query === 'unknown') throw {code:'AUTHOR_CUSTOM',message:'Unknown error',retryAfterMs:Infinity};
        if(input.query === 'getter') throw {get code(){throw Error('getter')},toString(){throw Error('toString')}};
        throw {code:'PARSE',message:'x'.repeat(3000),retryAfterMs:-1};
        """)
        for query in ["unknown", "getter", "long"] {
            do {
                _ = try await SourceRuntime().run(.search, inputJSON: json(["query":query]), snapshot: snapshot)
                XCTFail("Expected error")
            } catch let error as SourceFailure {
                XCTAssertEqual(error.code, query == "long" ? "PARSE" : "SCRIPT_ERROR")
                XCTAssertFalse(error.message.isEmpty)
                XCTAssertLessThanOrEqual(error.message.utf16.count, 2048)
                XCTAssertNil(error.retryAfterMs)
            }
        }
    }

    func testNativeTransportTimeoutRemainsDistinctFromNetworkFailure() async throws {
        for (path, method, timeout, code) in [("/failure/slow?ms=2000", "GET", 0.1, "TIMEOUT"),
                                              ("/failure/disconnect", "POST", 5.0, "NETWORK")] {
            // Give a connection failure time to arrive; a 100 ms deadline races URLSession's error delivery.
            // POST and one host attempt avoid GET reconnect/retry behavior obscuring the socket failure.
            let policy = SourceHTTPPolicy(origins: [origin], allowLoopbackHTTP: true, maximumBytes: 1024,
                                          maximumRedirects: 0, timeout: timeout, maximumAttempts: 1)
            do {
                _ = try await SourceHTTP.fetch(.init(url: origin + path, method: method, headers: [:], body: nil, redirect: "error"), policy: policy)
                XCTFail("Expected \(code)")
            } catch let error as SourceFailure { XCTAssertEqual(error.code, code) }
        }
        let recovered = try await SourceHTTP.fetch(.init(url: origin + "/health", method: "GET", headers: [:], body: nil, redirect: "error"),
                                                   policy: .init(origins: [origin], allowLoopbackHTTP: true, maximumBytes: 1024, maximumRedirects: 0, timeout: 5))
        XCTAssertEqual(recovered.status, 200)
    }

    func testInstalledStoragePersistsAcrossPagesAndSeparatesAccounts() async throws {
        let databaseURL = FileManager.default.temporaryDirectory.appendingPathComponent("source-webkit-\(UUID().uuidString)/native.sqlite3")
        let archive = try SourceArchive(url: databaseURL)
        let snapshot = try await source("""
        const entry = await ctx.storage.get('counter');
        const next = (entry?.value ?? 0) + 1;
        const written = await ctx.storage.set('counter', next, {ifRevision:entry?.revision ?? null});
        if(written.value !== next || !written.revision) throw Error('Write response lost');
        return {items:[{ref:{id:'counter'},title:String(next)}],nextCursor:null};
        """)
        let install = try SourceInstallation(publisherID: snapshot.inspection.metadata.id, name: "Storage fixture", version: "1.0.0",
                                            source: snapshot.source, origins: snapshot.inspection.metadata.origins)
        try await archive.saveInstallation(install)
        for expected in [1,2] {
            let provider = try WebKitSourceProvider(snapshot: snapshot, installation: install, archive: SourceArchive(url: databaseURL))
            let page = try await provider.search(.init(query: "counter"))
            XCTAssertEqual(page.items.first?.title, String(expected))
        }
        let other = try WebKitSourceProvider(snapshot: snapshot, installation: install, accountID: "other", archive: archive)
        let separate = try await other.search(.init(query: "counter"))
        XCTAssertEqual(separate.items.first?.title, "1")
    }

    func testStorageNullRevisionConflictsAndInvalidObjectsOnWebKit() async throws {
        let archive = try SourceArchive(url: FileManager.default.temporaryDirectory.appendingPathComponent("source-webkit-\(UUID().uuidString)/native.sqlite3"))
        let snapshot = try await source("""
        const original=await ctx.storage.set('value',null,{ifRevision:null});
        const read=await ctx.storage.get('value');
        if(read === null || read.value !== null || read.revision !== original.revision) throw Error('Null is not missing');
        try { await ctx.storage.set('value',1,{ifRevision:null}); throw Error('Conflict accepted'); }
        catch(e) { if(e.code !== 'STORAGE_CONFLICT') throw e; }
        await ctx.storage.remove('value',{ifRevision:original.revision});
        if(await ctx.storage.get('value') !== null) throw Error('Remove failed');
        const next=await ctx.storage.set('value',2,{ifRevision:null});
        if(next.revision === original.revision) throw Error('Revision reused');
        for(const value of [undefined,NaN,Infinity,new Date(),{get x(){throw Error('Getter executed')}},[,,]]) {
          try { await ctx.storage.set('invalid',value); throw Error('Invalid storage accepted'); }
          catch(e) { if(e.code !== 'INVALID_INPUT') throw e; }
        }
        try { await ctx.storage.set('large','x'.repeat(65537)); throw Error('Oversize storage accepted'); }
        catch(e) { if(e.code !== 'RESOURCE_LIMIT') throw e; }
        return {items:[],nextCursor:null};
        """)
        let scope = try SourceScope(installationID: UUID())
        _ = try await SourceRuntime().run(.search, inputJSON: #"{"query":"test"}"#, snapshot: snapshot,
                                          state: SourceStateBinding(archive: archive, scope: scope))
        let invalid = try await archive.state(scope: scope, key: "invalid")
        XCTAssertNil(invalid)
    }

    func testConfigurationOverridesAreValidatedAndBoundToProviderIdentity() async throws {
        let snapshot = try await source("return {items:[{ref:{id:'config'},title:ctx.config.mode+':'+ctx.config.count+':'+ctx.config.enabled}],nextCursor:null};",
            settings: """
            {mode:{type:'enum',label:'Mode',default:'a',options:[{value:'a',label:'A'},{value:'b',label:'B'}]},
             count:{type:'number',label:'Count',default:0,minimum:0,maximum:5},enabled:{type:'boolean',label:'Enabled',default:false}}
            """)
        let archive = try SourceArchive(url: FileManager.default.temporaryDirectory.appendingPathComponent("source-config-\(UUID().uuidString)/native.sqlite3"))
        let installation = try SourceInstallation(publisherID: snapshot.inspection.metadata.id, name: "Config", version: "1.0.0", source: snapshot.source, origins: snapshot.inspection.metadata.origins)
        let initial = try WebKitSourceProvider(snapshot: snapshot, installation: installation, archive: archive)
        let configured = try WebKitSourceProvider(snapshot: snapshot, installation: installation, configuration: .object(["mode":.string("b"),"count":.number(2),"enabled":.bool(true)]), archive: archive)
        XCTAssertNotEqual(initial.descriptor.identity, configured.descriptor.identity)
        let page = try await configured.search(.init(query: "config"))
        XCTAssertEqual(page.items.first?.title, "b:2:true")
        let invalidConfigs: [SourceJSON] = [.object(["mode":.string("unknown")]),.object(["count":.number(6)]),.object(["unknown":.bool(true)])]
        for config in invalidConfigs {
            XCTAssertThrowsError(try snapshot.configuration(overrides: config))
        }
    }

    func testTypedLibraryFlowPersistsCatalogContentAndReadingAnchorOnWebKit() async throws {
        let databaseURL = FileManager.default.temporaryDirectory.appendingPathComponent("source-library-\(UUID().uuidString)/native.sqlite3")
        let archive = try SourceArchive(url: databaseURL)
        let snapshot = try await SourceInspector().inspect(fixture("html.source.js"))
        let installation = try SourceInstallation(publisherID: snapshot.inspection.metadata.id, name: "HTML fixture", version: "1.0.0", source: snapshot.source, origins: snapshot.inspection.metadata.origins)
        try await archive.saveInstallation(installation)
        let provider = try WebKitSourceProvider(snapshot: snapshot, installation: installation, archive: archive, allowLoopbackHTTP: true)
        let library = SourceLibraryService(archive: archive)
        let page = try await provider.search(.init(query: "demo"))
        let book = try await library.addBook(provider: provider, ref: XCTUnwrap(page.items.first?.ref))
        let catalog = try await library.refreshCatalog(provider: provider, book: book.details.ref)
        XCTAssertEqual(catalog.chapters.count, 2)
        let downloaded = try await library.download(provider: provider, catalog: catalog)
        XCTAssertEqual(downloaded, 2)
        let content = try await library.chapter(provider: provider, book: book.details.ref, chapter: catalog.chapters[0].ref)
        XCTAssertFalse(content.document.plainText.contains("throw new Error"))
        let anchor = SourceReadingAnchor(chapter: content.key, document: content.document, offsetUTF16: 5)
        try await archive.saveAnchor(anchor)
        let reopened = try SourceArchive(url: databaseURL)
        let storage = try await reopened.chapterStorageUsage()
        XCTAssertEqual(storage.offlineCount, 2)
        XCTAssertEqual(storage.readingCacheCount, 0)
        let removed = try await reopened.removeChapterStorage(.readingCache)
        XCTAssertEqual(removed, 0, "Clearing reading cache must preserve explicit downloads")
        let saved = try await reopened.books(scope: provider.descriptor.identity.scope)
        XCTAssertEqual(saved.count, 1)
        let savedAnchor = try await reopened.anchor(book: book.key)
        XCTAssertEqual(savedAnchor, anchor)
        let offline = try await SourceLibraryService(archive: reopened).chapter(provider: provider, book: book.details.ref, chapter: catalog.chapters[0].ref, policy: .offline)
        XCTAssertEqual(offline.document, content.document)
    }

    func testLegadoJSONImportUsesIndependentProviderAndReopensOfflineLibrary() async throws {
        let databaseURL = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-app-\(UUID().uuidString)/archive.sqlite")
        let model = NativeSourceLibrary(databaseURL: databaseURL, allowLoopbackHTTP: true)
        var source = BookSource(bookSourceUrl: origin, bookSourceName: "Legado HTML fixture")
        source.searchUrl = "/html/search?q={{key}}&page={{page}}"
        source.ruleSearch = .init(bookList: "@css:.book", name: "@css:.title@text", author: "@css:.author@text", bookUrl: "@css:.title@href")
        var detail = BookInfoRule(); detail.name = "@css:h1@text"; detail.author = "@css:.author@text"
        detail.tocUrl = "@js:book.bookUrl + '/chapters?page=1'"; source.ruleBookInfo = detail
        var toc = TocRule(); toc.chapterList = "@css:.chapter"; toc.chapterName = "@css:a@text"; toc.chapterUrl = "@css:a@href"
        toc.nextTocUrl = "@css:.next@href"; source.ruleToc = toc
        var content = ContentRule(); content.content = "@css:article@text"; content.title = "@css:h1@text"; source.ruleContent = content
        source.additionalFields["futureField"] = .object(["keep": .string("unknown-field")])
        let text = String(decoding: try SourceCoding.encode(source), as: UTF8.self)
        let candidates = try await model.inspectCandidates(text)
        XCTAssertEqual(candidates.count, 1); XCTAssertEqual(candidates[0].format, .legado)
        try await model.install(candidates)
        let installation = try XCTUnwrap(model.installations.first)
        XCTAssertEqual(installation.format, .legado); XCTAssertEqual(installation.source, text)
        let provider = try await model.provider(installation)
        let search = try await provider.search(.init(query: "demo"))
        let service = try model.services().1
        let book = try await service.addBook(provider: provider, ref: XCTUnwrap(search.items.first?.ref))
        let catalog = try await service.refreshCatalog(provider: provider, book: book.details.ref)
        XCTAssertEqual(catalog.chapters.count, 2)
        let downloaded = try await service.download(provider: provider.prioritized(.background), catalog: catalog)
        XCTAssertEqual(downloaded, 2)
        let chapter = try await service.chapter(provider: provider, book: book.details.ref, chapter: catalog.chapters[0].ref)
        XCTAssertTrue(chapter.document.plainText.contains("First paragraph."))
        XCTAssertFalse(chapter.document.plainText.contains("fixture script"))
        let anchor = SourceReadingAnchor(chapter: chapter.key, document: chapter.document, offsetUTF16: 5)
        try await model.services().0.saveAnchor(anchor)
        let reopened = NativeSourceLibrary(databaseURL: databaseURL, allowLoopbackHTTP: true)
        await reopened.reload()
        XCTAssertEqual(reopened.shelf.count, 1)
        let resumed = try await reopened.provider(installation)
        let offline = try await reopened.services().1.chapter(provider: resumed, book: book.details.ref, chapter: catalog.chapters[0].ref, policy: .offline)
        XCTAssertEqual(offline.document, chapter.document)
        let restoredAnchor = try await reopened.services().0.anchor(book: book.key)
        XCTAssertEqual(restoredAnchor, anchor)
        let diagnostic = await SourceDiagnostics.shared.records()
        XCTAssertTrue(diagnostic.contains { $0.sourceDigest == installation.digest && $0.operation == .content && $0.code == "OK" })
        // Native modules continue to use their WebKit provider in the same library.
        let native = try await reopened.inspect(SourceAssets.script("OfflineExample.source"))
        try await reopened.install(native)
        XCTAssertEqual(Set(reopened.installations.map(\.format)), [.nativeModule, .legado])
    }

    func testLegadoGuestSessionSurvivesNewProviderAndPermissionEditsRevokeIt() async throws {
        let model = NativeSourceLibrary(databaseURL: FileManager.default.temporaryDirectory.appendingPathComponent("legacy-guest-\(UUID().uuidString)/archive.sqlite"), allowLoopbackHTTP: true)
        var source = BookSource(bookSourceUrl: origin, bookSourceName: "Guest session")
        source.searchUrl = "/state/login"
        source.ruleSearch = .init(bookList: #"@js:[{name:'Account',url:'/state/account'}]"#, name: "$.name", bookUrl: "$.url")
        var info = BookInfoRule(); info.name = "$.account"; source.ruleBookInfo = info
        let text = String(decoding: try SourceCoding.encode(source), as: UTF8.self)
        let imported = try await model.inspectCandidates(text)
        try await model.install(imported)
        let installation = try XCTUnwrap(model.installations.first)
        let first = try await model.provider(installation)
        let search = try await first.search(.init(query: "q"))
        let second = try await model.provider(installation)
        let details = try await second.book(.init(ref: XCTUnwrap(search.items.first?.ref)))
        XCTAssertEqual(details.title, "fixture-a")
        let cover = try await model.cover(.init(url: origin + "/covers/private.png"), installation: installation, scope: second.descriptor.identity.libraryScope)
        XCTAssertNotNil(UIImage(data: cover), "The default website session must also authenticate covers")
        let candidates = try await model.inspectCandidates(text, additionalOrigins: "https://unused.example", expectedFormat: .legado)
        try await model.replace(installation, with: candidates[0], resetConfiguration: false, originURL: nil, locallyModified: false)
        let updated = try XCTUnwrap(model.installations.first)
        XCTAssertEqual(updated.digest, installation.digest)
        let after = try await model.provider(updated)
        XCTAssertNotEqual(after.descriptor.identity, first.descriptor.identity)
        do { _ = try await second.book(.init(ref: details.ref)); XCTFail("Permissions changed but old provider survived") }
        catch let error as SourceDomainError { XCTAssertEqual(error.code, .stale) }
        let history = try await model.services().0.installationHistory(installation.id)
        XCTAssertEqual(history.first?.origins, installation.origins)
    }

    func testLegadoSourceEditingPreservesFormatAndUnknownJSONAndRendersSettings() async throws {
        let model = NativeSourceLibrary(databaseURL: FileManager.default.temporaryDirectory.appendingPathComponent("legacy-editor-\(UUID().uuidString)/archive.sqlite"), allowLoopbackHTTP: true)
        let text = #"{"bookSourceUrl":"https://fixture.example","bookSourceName":"兼容 JSON 示例","futureField":{"keep":true},"ruleBookInfo":{"futureRule":42}}"#
        let imported = try await model.inspectCandidates(text)
        try await model.install(imported)
        let installation = try XCTUnwrap(model.installations.first)
        let edited = text.replacingOccurrences(of: "兼容 JSON 示例", with: "已编辑的兼容书源")
        let editedCandidates = try await model.inspectCandidates(edited, expectedFormat: .legado)
        let candidate = try XCTUnwrap(editedCandidates.first)
        try await model.replace(installation, with: candidate, resetConfiguration: false, originURL: nil, locallyModified: true)
        let updated = try XCTUnwrap(model.installations.first)
        XCTAssertEqual(updated.format, .legado); XCTAssertEqual(updated.source, edited)
        XCTAssertTrue(updated.source.contains("futureRule"))
        do {
            _ = try await model.inspectCandidates(SourceAssets.script("OfflineExample.source"), expectedFormat: .legado)
            XCTFail("Format change silently accepted")
        } catch let error as SourceDomainError { XCTAssertEqual(error.code, .invalidInput) }
        let size = CGSize(width: 393, height: 852)
        let controller = UIHostingController(rootView: NavigationStack { NativeSourceSettingsView(model: model, initialInstallation: updated) })
        let window = UIWindow(frame: CGRect(origin: .zero, size: size)); window.rootViewController = controller; window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.view.frame = window.bounds
        try await Task.sleep(for: .milliseconds(300)); controller.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(size: size).image { _ in controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image); attachment.name = "legado-json-source-settings"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testSourceEditorSheetReceivesCurrentAndHistoricalTextOnEveryPresentation() async throws {
        let model = NativeSourceLibrary(databaseURL: FileManager.default.temporaryDirectory.appendingPathComponent("editor-sheet-\(UUID())/archive.sqlite"))
        let text = #"{"bookSourceUrl":"https://fixture.invalid","bookSourceName":"Editor payload","ruleToc":{"chapterList":".chapter"}}"#
        try await model.install(model.inspectCandidates(text))
        let installation = try XCTUnwrap(model.installations.first)
        let presentation = NativeSourceEditorPresentation()
        let host = UIHostingController(rootView: NavigationStack {
            NativeSourceSettingsView(model: model, initialInstallation: installation, editor: presentation)
        })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene); window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        try await Task.sleep(for: .milliseconds(300))
        for expected in [installation.source, text.replacingOccurrences(of: "Editor payload", with: "Historical payload"), installation.source] {
            // Same action as the settings buttons, exercising the real SwiftUI sheet and TextEditor.
            presentation.edit(installation, text: expected)
            var editor: UITextView?
            for _ in 0..<100 {
                window.layoutIfNeeded()
                editor = descendants(window).compactMap { $0 as? UITextView }.first { $0.text == expected }
                if editor != nil { break }
                try await Task.sleep(for: .milliseconds(30))
            }
            XCTAssertEqual(try XCTUnwrap(editor, "Presented editor is blank or contains a stale draft").text, expected)
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image); attachment.name = "source-editor-presented-text"; attachment.lifetime = .keepAlways; add(attachment)
            presentation.request = nil
            for _ in 0..<100 {
                if host.presentedViewController == nil { break }
                try await Task.sleep(for: .milliseconds(30))
            }
        }
    }

    func testOfflineBookWithoutCatalogDoesNotStartAutomaticSourceOperation() async throws {
        let model = NativeSourceLibrary(databaseURL: FileManager.default.temporaryDirectory.appendingPathComponent("offline-details-\(UUID())/archive.sqlite"), allowLoopbackHTTP: true)
        let snapshot = try await source("return {items:[],nextCursor:null};", topLevel: "const offlineDetailsFixture = true;")
        try await model.install(snapshot)
        let installation = try XCTUnwrap(model.installations.first)
        let provider = try await model.provider(installation)
        let book = try await model.services().1.addBook(provider: provider, ref: .init(id: "b"))
        let host = UIHostingController(rootView: NavigationStack {
            NativeSourceBookView(model: model, item: .init(installation: installation, book: book), initiallyOffline: true)
        })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene); window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        for _ in 0..<100 {
            if descendants(window).compactMap({ $0 as? UISwitch }).contains(where: { $0.isEnabled && $0.isOn }) { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        try await Task.sleep(for: .milliseconds(300))
        let toggle = try XCTUnwrap(descendants(window).compactMap { $0 as? UISwitch }.first)
        XCTAssertTrue(toggle.isOn && toggle.isEnabled)
        let records = await SourceDiagnostics.shared.records()
        XCTAssertFalse(records.contains { $0.sourceDigest == installation.digest && $0.operation == .chapters })
    }

    func testLegacyMigrationReviewAdoptionAndOfflineReaderOnIOS() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("migration-ios-" + UUID().uuidString)
        let databaseURL = directory.appendingPathComponent("original.sqlite3")
        let database = try LegadoDatabase(url: databaseURL)
        let source = BookSource(bookSourceUrl: "https://migration.invalid", bookSourceName: "迁移离线示例")
        try await database.replaceBookSources([source])
        var book = Book(bookUrl: "https://migration.invalid/book?id=1", name: "副本中的书", author: "示例作者", origin: source.id)
        book.durChapterIndex = 1; book.durChapterPos = 4; book.durChapterTime = 1000
        var config = BookReadConfig(); config.useReplaceRule = false; book.readConfig = config
        try await database.replaceBooks([book])
        let chapters = (0..<2).map { BookChapter(url: "https://migration.invalid/chapter/\($0)", title: "相同标题", bookUrl: book.id, index: $0) }
        try await database.replaceChapters(chapters, bookURL: book.id)
        var bookmark = Bookmark(time: 1000, bookName: book.name, bookAuthor: book.author)
        bookmark.chapterIndex = 1; bookmark.chapterPosition = 4; bookmark.chapterName = "相同标题"; bookmark.content = "迁移后的笔记"; bookmark.bookText = "可离线阅读"
        try await database.replaceBookmarks([bookmark])
        let cache = directory.appendingPathComponent("chapters")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        for chapter in chapters {
            let entry = CachedChapterContent(bookURL: book.id, chapterURL: chapter.url,
                content: "本章内容可离线阅读。\n这是第 \(chapter.index + 1) 章，验证同标题章节的阅读位置。", sourceID: source.id)
            try SourceCoding.encode(entry).write(to: cache.appendingPathComponent("\(chapter.index).json"))
        }
        let migrationDirectory = directory.appendingPathComponent("migration")
        let snapshot = migrationDirectory.appendingPathComponent("snapshot"), mapping = migrationDirectory.appendingPathComponent("mapping")
        _ = try await Task.detached {
            try LegacyMigrationSnapshot.capture(databaseURL: databaseURL, externalDirectories: ["chapters": cache], destination: snapshot)
        }.value
        let report = try await LegacyMigrationMapper.prepare(snapshotAt: snapshot, destination: mapping)
        XCTAssertEqual(report.books.count, 1); XCTAssertEqual(report.cacheFilesMapped, 2)
        let activeURL = directory.appendingPathComponent("active.sqlite3")
        let model = NativeSourceLibrary(databaseURL: activeURL, credentials: SourceCredentialVault(persistence: SourceEphemeralCredentials()))
        _ = try await LegacyMigrationMapper.adopt(at: mapping, snapshotAt: snapshot, into: model.services().0)
        await model.reload()
        let item = try XCTUnwrap(model.shelf.first)
        let archive = try model.services().0
        let initialOffline = try await model.offlineOnly(book: item.book.key)
        XCTAssertTrue(initialOffline, "Imported books must initially open offline")
        model.saveOfflineOnly(true, book: item.book.key)
        model.saveOfflineOnly(false, book: item.book.key)
        let chosenOffline = try await model.offlineOnly(book: item.book.key, defaultValue: true)
        XCTAssertFalse(chosenOffline, "Explicit choice must override the migration default and pending earlier writes")
        let detailHost = UIHostingController(rootView: NavigationStack { NativeSourceBookView(model: model, item: item, initiallyOffline: true) })
        let detailScene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousDetailWindow = detailScene.windows.first(where: \.isKeyWindow)
        let detailWindow = UIWindow(windowScene: detailScene); detailWindow.rootViewController = detailHost; detailWindow.makeKeyAndVisible()
        defer { detailWindow.isHidden = true; previousDetailWindow?.makeKeyAndVisible() }
        var offlineToggle: UISwitch?
        for _ in 0..<100 {
            offlineToggle = descendants(detailWindow).compactMap { $0 as? UISwitch }.first
            if let offlineToggle, offlineToggle.isEnabled, !offlineToggle.isOn { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertFalse(try XCTUnwrap(offlineToggle).isOn, "Opening imported book details must not force offline mode back on")
        detailWindow.isHidden = true; previousDetailWindow?.makeKeyAndVisible()
        let savedCatalog = try await archive.catalog(book: item.book.key)
        let catalog = try XCTUnwrap(savedCatalog)
        let notes = try await archive.importedAnnotations(book: item.book.key)
        XCTAssertEqual(notes.count, 1); XCTAssertEqual(notes[0].note, "迁移后的笔记")
        XCTAssertEqual(notes[0].anchor.chapter.chapterID, catalog.chapters[1].ref.id)
        let provider = try await model.provider(item.installation, scope: item.book.key.scope)
        let stored = try await model.services().1.chapter(provider: provider, book: catalog.book, chapter: catalog.chapters[1].ref, policy: .offline)
        XCTAssertTrue(stored.document.plainText.contains("第 2 章"))
        let migrationModel = LegacyMigrationModel(directory: migrationDirectory, legacyDatabase: databaseURL)
        migrationModel.restore(library: model)
        for _ in 0..<100 {
            if !migrationModel.busy { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        XCTAssertNotNil(migrationModel.report); XCTAssertTrue(migrationModel.adopted); XCTAssertNil(migrationModel.failure)
        for (name, size, accessibility) in [("phone", CGSize(width: 393, height: 852), false), ("accessibility", CGSize(width: 393, height: 852), true), ("tablet-width", CGSize(width: 1024, height: 768), false)] {
            let host = UIHostingController(rootView: NavigationStack { LegacyMigrationView(library: model, model: migrationModel) }
                .environment(\.dynamicTypeSize, accessibility ? .accessibility3 : .large))
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previous = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene), container = UIViewController()
            window.rootViewController = container; window.makeKeyAndVisible(); container.addChild(host)
            host.view.frame = CGRect(origin: .zero, size: size); container.view.addSubview(host.view); host.didMove(toParent: container)
            defer { window.isHidden = true; previous?.makeKeyAndVisible() }
            try await Task.sleep(for: .milliseconds(300)); host.view.layoutIfNeeded()
            var rendered = false
            let image = UIGraphicsImageRenderer(size: size).image { _ in rendered = host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
            XCTAssertTrue(rendered)
            let attachment = XCTAttachment(image: image); attachment.name = "legacy-migration-review-" + name; attachment.lifetime = .keepAlways; add(attachment)
            for scroll in descendants(host.view).compactMap({ $0 as? UIScrollView }) where scroll.bounds.width > 100 {
                XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
            }
        }
        let reopened = NativeSourceLibrary(databaseURL: activeURL, credentials: SourceCredentialVault(persistence: SourceEphemeralCredentials()))
        await reopened.reload(); XCTAssertEqual(reopened.shelf.count, 1)
        let reopenedOffline = try await reopened.offlineOnly(book: item.book.key, defaultValue: true)
        XCTAssertFalse(reopenedOffline, "Offline choice must survive app restart")
        let preserved = try await database.loadBooks()
        XCTAssertEqual(preserved[0], book)
        XCTAssertEqual(try LegacyMigrationMapper.verify(at: mapping, snapshotAt: snapshot), report)
    }

    func testOperationCompletionRejectsLaterStorageWrites() async throws {
        let archive = try SourceArchive(url: FileManager.default.temporaryDirectory.appendingPathComponent("source-late-\(UUID().uuidString)/native.sqlite3"))
        let scope = try SourceScope(installationID: UUID())
        let snapshot = try await source("""
        await ctx.storage.set('finished','saved');
        setTimeout(()=>ctx.storage.set('late','must not persist').catch(()=>{}),500);
        return {items:[],nextCursor:null};
        """)
        _ = try await SourceRuntime().run(.search, inputJSON: #"{"query":"test"}"#, snapshot: snapshot, state: .init(archive: archive, scope: scope))
        try await Task.sleep(for: .milliseconds(600))
        let late = try await archive.state(scope: scope, key: "late")
        let finished = try await archive.state(scope: scope, key: "finished")
        XCTAssertNil(late)
        XCTAssertEqual(finished?.value, .string("saved"))
    }
    func testInstalledSourceEditRollbackAndPinnedProviderRemainIndependent() async throws {
        let model = NativeSourceLibrary(databaseURL: FileManager.default.temporaryDirectory.appendingPathComponent("source-editor-\(UUID().uuidString)/native.sqlite3"))
        let original = try await model.inspect(SourceAssets.script("OfflineExample.source"))
        try await model.install(original)
        let installation = try XCTUnwrap(model.installations.first)
        let oldProvider = try await model.provider(installation)
        let candidate = try await model.inspect(original.source.replacingOccurrences(of: "离线示例", with: "Edited fixture"))
        try await model.replace(installation, with: candidate, resetConfiguration: false, originURL: nil, locallyModified: true)
        let current = try XCTUnwrap(model.installations.first)
        XCTAssertEqual(current.id, installation.id)
        XCTAssertEqual(current.locallyModified, true)
        let oldPage = try await oldProvider.search(.init(query: "test"))
        let newProvider = try await model.provider(installation)
        let newPage = try await newProvider.search(.init(query: "test"))
        XCTAssertEqual(oldPage.items.first?.title, "离线示例")
        XCTAssertEqual(newPage.items.first?.title, "Edited fixture")
        let history = try await model.services().0.installationHistory(installation.id)
        XCTAssertEqual(history.first?.source, original.source)
        do {
            try await model.replace(installation, with: original, resetConfiguration: true, originURL: nil, locallyModified: true)
            XCTFail("A stale editor replaced a newer installation")
        } catch let failure as SourceDomainError { XCTAssertEqual(failure.code, .storageConflict) }
        try await model.replace(current, with: original, resetConfiguration: true, originURL: nil, locallyModified: true)
        let restored = try XCTUnwrap(model.installations.first)
        XCTAssertEqual(restored.digest, original.sha256)
        XCTAssertEqual(restored.id, installation.id)
    }

    func testNativeReaderRendersOfflineAtPhoneAndTabletWidths() async throws {
        let model = NativeSourceLibrary(databaseURL: FileManager.default.temporaryDirectory.appendingPathComponent("source-layout-\(UUID().uuidString)/native.sqlite3"))
        let source = try await model.inspect(SourceAssets.script("OfflineExample.source"))
        try await model.install(source)
        let installation = try XCTUnwrap(model.installations.first)
        let provider = try await model.provider(installation)
        let (_, library) = try model.services()
        for (name, size, category, dark) in [
            ("phone", CGSize(width: 390, height: 844), UIContentSizeCategory.large, false),
            ("phone-accessibility", CGSize(width: 390, height: 844), UIContentSizeCategory.accessibilityExtraExtraExtraLarge, true),
            ("tablet", CGSize(width: 1024, height: 768), UIContentSizeCategory.large, false)
        ] {
            let book = try await library.addBook(provider: provider, ref: .init(id: name))
            let catalog = try await library.refreshCatalog(provider: provider, book: book.details.ref)
            _ = try await library.download(provider: provider, catalog: catalog)
            let item = NativeSourceLibrary.ShelfBook(installation: installation, book: book)
            let reader = NavigationStack {
                NativeSourceReaderView(model: model, item: item, catalog: catalog, initialChapterID: catalog.chapters[0].ref.id, offline: true)
            }.environment(\.dynamicTypeSize, dark ? .accessibility5 : .large)
            let host = UIHostingController(rootView: reader)
            host.traitOverrides.preferredContentSizeCategory = category
            host.overrideUserInterfaceStyle = dark ? .dark : .light
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene)
            let container = UIViewController()
            window.rootViewController = container
            window.makeKeyAndVisible()
            container.addChild(host)
            host.view.frame = CGRect(origin: .zero, size: size)
            host.view.backgroundColor = dark ? .black : .white
            container.view.addSubview(host.view)
            host.didMove(toParent: container)
            defer { window.isHidden = true; previousKeyWindow?.makeKeyAndVisible() }
            window.layoutIfNeeded()
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
            // Wait for the offline chapter's native anchor, not a timing assumption about WebKit startup.
            var restored = false
            for _ in 0..<100 {
                if try await model.services().0.anchor(book: book.key) != nil { restored = true; break }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertTrue(restored, "Offline reader did not display content")
            try await Task.sleep(for: .milliseconds(300))
            window.layoutIfNeeded()
            var rendered = false
            let image = UIGraphicsImageRenderer(size: size).image { _ in
                rendered = host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            XCTAssertTrue(rendered, "View hierarchy snapshot failed")
            let pixels = try XCTUnwrap(image.cgImage?.dataProvider?.data) as Data
            XCTAssertGreaterThan(Set(pixels).count, 8, "Blank snapshot must not count as layout evidence")
            let attachment = XCTAttachment(image: image)
            attachment.name = "native-reader-" + name
            attachment.lifetime = .keepAlways
            add(attachment)
            XCTAssertEqual(host.view.bounds.width, size.width, accuracy: 1)
            for scroll in descendants(host.view).compactMap({ $0 as? UIScrollView }) where scroll.bounds.width > 100 {
                XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1, "Unexpected horizontal overflow at \(name)")
            }
        }
    }
    private func descendants(_ view: UIView) -> [UIView] { view.subviews.flatMap { [$0] + descendants($0) } }

    func testNativeSearchReplacementDoesNotPublishOldResults() async throws {
        let model = NativeSourceLibrary(databaseURL: FileManager.default.temporaryDirectory.appendingPathComponent("source-search-\(UUID().uuidString)/native.sqlite3"))
        let snapshot = try await source("""
        if(input.query === 'old') {
          await ctx.storage.set('old-started',true);
          await new Promise(resolve=>setTimeout(resolve,2000));
        }
        return {items:[{ref:{id:input.query},title:input.query}],nextCursor:null};
        """)
        try await model.install(snapshot)
        let installation = try XCTUnwrap(model.installations.first)
        let scope = try SourceScope(installationID: installation.id)
        let archive = try model.services().0
        model.search("old")
        var started = false
        for _ in 0..<150 {
            if try await archive.state(scope: scope, key: "old-started") != nil { started = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(started)
        model.search("new")
        for _ in 0..<150 {
            if !model.searching { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertFalse(model.searching)
        XCTAssertEqual(model.results.map(\.book.title), ["new"])
        try await Task.sleep(for: .milliseconds(2100))
        XCTAssertEqual(model.results.map(\.book.title), ["new"])
        XCTAssertTrue(model.searchFailures.isEmpty)
    }

    func testNativeSearchLoadsEmptyAndOverlappingPagesAndRetriesFailure() async throws {
        let model = NativeSourceLibrary(databaseURL: FileManager.default.temporaryDirectory.appendingPathComponent("source-pages-\(UUID().uuidString)/native.sqlite3"))
        let snapshot = try await source("""
        if(input.cursor == null) return {items:[{ref:{id:'a'},title:input.query}],nextCursor:1};
        if(input.cursor === 1) return {items:[],nextCursor:2};
        if(!(await ctx.storage.get('failed-once'))) {
          await ctx.storage.set('failed-once',true);
          throw new Error('synthetic temporary failure');
        }
        return {items:[{ref:{id:'a'},title:input.query},{ref:{id:'b'},title:'Second'}],nextCursor:null};
        """)
        try await model.install(snapshot)
        model.search("first")
        try await waitForNativeSearch(model)
        XCTAssertEqual(model.results.map(\.book.ref.id), ["a"])
        XCTAssertTrue(model.canLoadMore)
        model.loadMore()
        try await waitForNativeSearch(model)
        XCTAssertEqual(model.results.map(\.book.ref.id), ["a"])
        XCTAssertTrue(model.canLoadMore)
        model.loadMore()
        try await waitForNativeSearch(model)
        XCTAssertEqual(model.searchFailures.count, 1)
        XCTAssertTrue(model.canLoadMore)
        model.loadMore()
        try await waitForNativeSearch(model)
        XCTAssertEqual(model.results.map(\.book.ref.id), ["a", "b"])
        XCTAssertTrue(model.searchFailures.isEmpty)
        XCTAssertFalse(model.canLoadMore)
        model.search("replacement")
        try await waitForNativeSearch(model)
        XCTAssertEqual(model.results.map(\.book.title), ["replacement"])
        model.cancelSearch()
        XCTAssertFalse(model.canLoadMore)
    }

    private func waitForNativeSearch(_ model: NativeSourceLibrary) async throws {
        for _ in 0..<150 {
            if !model.searching { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Native search did not complete within its test budget")
        model.cancelSearch()
    }

}


private final class RuntimeMemoryCredentials: SourceCredentialPersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [SourceScope: Data] = [:]
    func read(scope: SourceScope) throws -> Data? { lock.lock(); defer { lock.unlock() }; return records[scope] }
    func write(_ data: Data, scope: SourceScope) throws { lock.lock(); defer { lock.unlock() }; records[scope] = data }
}

extension SourceRuntimeTests {
    private func accountModel() -> NativeSourceLibrary {
        NativeSourceLibrary(databaseURL: FileManager.default.temporaryDirectory.appendingPathComponent("native-account-\(UUID().uuidString)/native.sqlite3"),
                            credentials: SourceCredentialVault(persistence: RuntimeMemoryCredentials()))
    }
    private func waitForLogin(_ browser: NativeSourceLoginBrowser) async throws {
        for _ in 0..<150 {
            if browser.ready { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw SourceDomainError(.timeout, "Fixture login did not load")
    }
    private func script(_ body: String, in view: WKWebView) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            view.callAsyncJavaScript(body, arguments: [:], in: nil, in: .page) { result in
                switch result {
                case .success(let value):
                    if let string = value as? String { continuation.resume(returning: string) }
                    else { continuation.resume(throwing: SourceDomainError(.invalidData, "Script did not return text")) }
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
    }

    func testWebsiteSessionSwitchPreservesLibraryAndRevokesOldProvider() async throws {
        let model = accountModel()
        try await model.install(model.inspect(SourceAssets.script("OfflineExample.source")))
        let installation = try XCTUnwrap(model.installations.first)
        let (archive, library) = try model.services()
        let guestProvider = try await model.provider(installation)
        let guestBook = try await library.addBook(provider: guestProvider, ref: .init(id: "guest-book"))
        let account = try await archive.addAccount(name: "Reader A", installationID: installation.id)
        let oldScope = try SourceScope(installationID: installation.id, accountID: account.id)
        let oldBook = SourceSavedBook(key: try .init(scope: oldScope, bookID: "legacy-local-book"), details: .init(ref: .init(id: "legacy-local-book"), title: "Old local book"))
        try await archive.saveBook(oldBook)
        try await model.selectAccount(account.id, installation: installation)
        XCTAssertEqual(Set(model.shelf.map(\.book.key)), [guestBook.key, oldBook.key])
        do { _ = try await guestProvider.search(.init(query: "stale")); XCTFail("Guest provider survived account selection") }
        catch let error as SourceDomainError { XCTAssertEqual(error.code, .stale) }
        let rebound = try await model.provider(installation, scope: guestBook.key.scope)
        XCTAssertEqual(rebound.descriptor.identity.libraryScope, guestBook.key.scope)
        XCTAssertEqual(rebound.descriptor.identity.scope.accountID, account.id)
        let provider = try await model.provider(installation)
        let privateBook = try await library.addBook(provider: provider, ref: .init(id: "account-book"))
        await model.reload()
        XCTAssertEqual(Set(model.shelf.map(\.book.key)), [guestBook.key, privateBook.key, oldBook.key])
        XCTAssertEqual(privateBook.key.scope, guestBook.key.scope, "New local book identity must not depend on website login")
        try await model.selectAccount("guest", installation: installation)
        XCTAssertEqual(Set(model.shelf.map(\.book.key)), [guestBook.key, privateBook.key, oldBook.key])
        do { _ = try await provider.search(.init(query: "stale")); XCTFail("Account provider survived deselection") }
        catch let error as SourceDomainError { XCTAssertEqual(error.code, .stale) }
    }

    func testBrowserLoginPersistsOnlyAfterSaveAndFeedsNativeHTTP() async throws {
        let model = accountModel()
        let snapshot = try await source("const response = await ctx.http.fetch('\(origin)/state/account'); const account = await response.json(); if(response.status !== 200) throw Error('AUTH_REQUIRED'); return {items:[{ref:{id:'account'},title:account.account}],nextCursor:null};")
        try await model.install(snapshot)
        let installation = try XCTUnwrap(model.installations.first)
        let account = try await model.services().0.addAccount(name: "Reader", installationID: installation.id)
        try await model.selectAccount(account.id, installation: installation)
        let context = try await model.credentialContext(installation, accountID: account.id)
        let browser = NativeSourceLoginBrowser(origin: origin, allowLoopbackHTTP: true)
        defer { browser.close() }
        try await browser.prepare(cookies: [])
        try await waitForLogin(browser)
        let view = try XCTUnwrap(browser.webView)
        XCTAssertFalse(view.configuration.websiteDataStore.isPersistent)
        let hasBridge = try await script("return String(Boolean(window.webkit?.messageHandlers?.sourceHost));", in: view)
        XCTAssertEqual(hasBridge, "false")
        let marker = try await script("await fetch('/state/login'); return 'done';", in: view)
        XCTAssertEqual(marker, "done")
        let before = try await context.session.headers(for: URL(string: origin)!)
        XCTAssertTrue(before.isEmpty)
        let raw = try await script("return document.cookie;", in: view)
        XCTAssertFalse(raw.contains("fixture_session"), "HTTPOnly cookie appeared in document.cookie")
        let cookies = try await browser.cookies()
        XCTAssertEqual(cookies.first(where: { $0.name == "fixture_session" })?.value, "fixture-a")
        try await model.saveLoginCookies(cookies, origin: origin, context: context)
        let current = try await model.credentialSession(installation, accountID: account.id)
        let response = try await SourceHTTP.fetch(.init(url: origin + "/state/account", method: "GET", headers: [:], body: nil, redirect: "follow"),
            policy: .init(origins: [origin], allowLoopbackHTTP: true), credentials: current)
        XCTAssertEqual(response.status, 200)
        let data = try XCTUnwrap(Data(base64Encoded: response.body))
        XCTAssertEqual(try object(String(decoding: data, as: UTF8.self))["account"] as? String, "fixture-a")
        let provider = try WebKitSourceProvider(snapshot: snapshot, installation: installation, accountID: account.id,
            archive: model.services().0, allowLoopbackHTTP: true, credentials: current)
        let search = try await provider.search(.init(query: "account"))
        XCTAssertEqual(search.items.first?.title, "fixture-a")
        let reopened = NativeSourceLoginBrowser(origin: origin, allowLoopbackHTTP: true)
        defer { reopened.close() }
        try await reopened.prepare(cookies: model.credentials.browserCookies(session: current))
        try await waitForLogin(reopened)
        let restored = try await reopened.cookies()
        XCTAssertEqual(restored.first(where: { $0.name == "fixture_session" })?.value, "fixture-a")
    }

    func testDeclaredLegacyLoginRendersCrossOriginScriptAndUnlocksCatalogAndContent() async throws {
        let databaseURL = FileManager.default.temporaryDirectory.appendingPathComponent("website-login-\(UUID().uuidString)/archive.sqlite")
        let vault = SourceCredentialVault(persistence: RuntimeMemoryCredentials())
        let model = NativeSourceLibrary(databaseURL: databaseURL, credentials: vault, allowLoopbackHTTP: true)
        var source = BookSource(bookSourceUrl: origin, bookSourceName: "Website login fixture")
        source.loginUrl = "/website/login"
        source.searchUrl = "/html/search?q={{key}}&page={{page}}"
        source.ruleSearch = .init(bookList: "@css:.book", name: "@css:.title@text", bookUrl: "@css:.title@href")
        var info = BookInfoRule(); info.name = "@css:h1@text"; info.tocUrl = "@js:'/website/catalog'"; source.ruleBookInfo = info
        var toc = TocRule(); toc.chapterList = "@css:.chapter"; toc.chapterName = "@css:a@text"; toc.chapterUrl = "@css:a@href"; source.ruleToc = toc
        var content = ContentRule(); content.content = "@css:article@text"; source.ruleContent = content
        try await model.install(model.inspectCandidates(String(decoding: try SourceCoding.encode(source), as: UTF8.self)))
        let installation = try XCTUnwrap(model.installations.first)
        let initial = try await model.provider(installation)
        let results = try await initial.search(.init(query: "demo"))
        let (archive, library) = try model.services()
        let book = try await library.addBook(provider: initial, ref: XCTUnwrap(results.items.first?.ref))
        do { _ = try await library.refreshCatalog(provider: initial, book: book.details.ref); XCTFail("Verification shell accepted as a catalog") }
        catch let error as SourceExtractionFailure {
            XCTAssertEqual(error.context.httpStatus, 202); XCTAssertEqual(error.context.field, .catalog)
            let responseID = try XCTUnwrap(error.context.responseID)
            let captured = await SourceDiagnostics.shared.localResponse(id: responseID, sourceDigest: installation.digest)
            XCTAssertFalse(try XCTUnwrap(captured).body.isEmpty)
            let verification = try await model.verificationRequest(installation, responseID: responseID)
            XCTAssertEqual(verification.webRequest?.url?.path, "/website/catalog", "Verification must open the failed page, not just the login homepage")
            XCTAssertEqual(verification.webRequest?.value(forHTTPHeaderField: "User-Agent"), LegadoURLBuilder.defaultUserAgent)
            XCTAssertNil(verification.webRequest?.value(forHTTPHeaderField: "Cookie"))
            let report = String(decoding: try await SourceDiagnostics.shared.export(), as: UTF8.self)
            XCTAssertFalse(report.contains("/website/catalog"))
            XCTAssertFalse(report.contains(try XCTUnwrap(captured).body))
        }

        let context = try await model.credentialContext(installation, accountID: "guest")
        let request = try model.websiteLoginRequest(installation, fallbackOrigin: origin)
        XCTAssertEqual(request.url?.path, "/website/login")
        let browser = NativeSourceLoginBrowser(origin: origin, request: request, credentialOrigins: context.session.allowedOrigins, allowLoopbackHTTP: true)
        defer { browser.close() }
        try await browser.prepare(cookies: [])
        let view = try XCTUnwrap(browser.webView)
        let controller = UIViewController()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = controller; window.makeKeyAndVisible()
        window.layoutIfNeeded(); controller.view.layoutIfNeeded()
        view.frame = controller.view.bounds; view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        controller.view.addSubview(view)
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        try await waitForLogin(browser)
        let rendered = try await script("return document.getElementById('login-ready')?.textContent ?? 'blank';", in: view)
        XCTAssertEqual(rendered, "Website login", "The page is blank without its cross-origin script")
        try await Task.sleep(for: .milliseconds(300))
        view.layoutIfNeeded()
        let image: UIImage = try await withCheckedThrowingContinuation { continuation in
            view.takeSnapshot(with: nil) { image, error in
                if let image { continuation.resume(returning: image) }
                else { continuation.resume(throwing: error ?? SourceDomainError(.unavailable, "Login snapshot missing")) }
            }
        }
        let pixels = try XCTUnwrap(image.cgImage?.dataProvider?.data) as Data
        XCTAssertGreaterThan(Set(pixels).count, 8, "A blank snapshot is not evidence of a rendered login page")
        let attachment = XCTAttachment(image: image); attachment.name = "website-login-cross-origin-rendered"; attachment.lifetime = .keepAlways; add(attachment)
        _ = try await script("document.getElementById('login').click(); for(let i=0;i<100;i++){if(document.body.dataset.signedIn==='true')return 'signed-in';await new Promise(r=>setTimeout(r,20));}throw Error('Login timed out');", in: view)
        try await model.saveLoginCookies(browser.cookies(), origins: context.session.allowedOrigins, context: context)
        browser.close()
        let current = try await model.provider(installation)
        let catalog = try await library.refreshCatalog(provider: current, book: book.details.ref)
        XCTAssertEqual(catalog.chapters.count, 1)
        let chapter = try await library.chapter(provider: current, book: book.details.ref, chapter: catalog.chapters[0].ref, catalog: catalog, retainOffline: true)
        XCTAssertEqual(chapter.document.plainText, "Signed in chapter.")
        let anchor = SourceReadingAnchor(chapter: chapter.key, document: chapter.document, offsetUTF16: 4)
        try await archive.saveAnchor(anchor)
        let reopened = NativeSourceLibrary(databaseURL: databaseURL, credentials: vault, allowLoopbackHTTP: true)
        await reopened.reload()
        XCTAssertEqual(reopened.shelf.map(\.book.key), [book.key])
        let resumed = try await reopened.provider(installation)
        let offline = try await reopened.services().1.chapter(provider: resumed, book: book.details.ref, chapter: catalog.chapters[0].ref, policy: .offline)
        XCTAssertEqual(offline.document, chapter.document)
        let restoredAnchor = try await reopened.services().0.anchor(book: book.key)
        XCTAssertEqual(restoredAnchor, anchor)
        let logout = try await reopened.credentialContext(installation, accountID: "guest")
        try await reopened.clearLogin(context: logout)
        XCTAssertEqual(reopened.shelf.map(\.book.key), [book.key])
        let signedOut = try await reopened.provider(installation, scope: book.key.scope)
        let retained = try await reopened.services().1.chapter(provider: signedOut, book: book.details.ref, chapter: catalog.chapters[0].ref, policy: .offline)
        XCTAssertEqual(retained.document, chapter.document)
        do { _ = try await current.chapters(.init(book: book.details.ref)); XCTFail("Pre-logout provider survived") }
        catch let error as SourceDomainError { XCTAssertEqual(error.code, .stale) }
    }

    func testWebsiteLoginExportsOnlyCookiesForApprovedSourceOrigins() async throws {
        let allowed: Set<String> = ["https://www.website.invalid", "https://api.website.invalid"]
        let browser = NativeSourceLoginBrowser(origin: origin, credentialOrigins: allowed, allowLoopbackHTTP: true)
        defer { browser.close() }
        try await browser.prepare(cookies: [])
        try await waitForLogin(browser)
        let view = try XCTUnwrap(browser.webView)
        for (name, domain) in [("parent", ".website.invalid"), ("host", "www.website.invalid"), ("idp", "identity.invalid")] {
            let cookie = try XCTUnwrap(HTTPCookie(properties: [.name: name, .value: "synthetic", .domain: domain, .path: "/", .secure: "TRUE"]))
            await view.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
        }
        let exported = try await browser.cookies()
        XCTAssertEqual(Set(exported.filter { $0.name == "parent" }.map(\.origin)), allowed)
        XCTAssertEqual(exported.filter { $0.name == "host" }.map(\.origin), ["https://www.website.invalid"])
        XCTAssertFalse(exported.contains { $0.name == "idp" })
    }

    func testFailureResponseUsesOnePresentationWithoutOpeningSourceSettings() async throws {
        let model = accountModel()
        try await model.install(model.inspect(SourceAssets.script("OfflineExample.source")))
        let installation = try XCTUnwrap(model.installations.first)
        let provider = try await model.provider(installation)
        let id = UUID()
        let extraction = SourceExtractionContext(field: .catalog, httpStatus: 202, responseBytes: 36, responseID: id)
        let issue = SourceIssue(code: "EMPTY_CATALOG", extraction: extraction)
        let response = SourceLocalResponse(response: .init(data: Data("<html>Fixture verification</html>".utf8), statusCode: 202,
            headers: ["Content-Type": "text/html"], finalURL: URL(string: "https://fixture.invalid/catalog")!))
        await SourceDiagnostics.shared.record(id: id, operation: .chapters, identity: provider.descriptor.identity,
            issue: issue, elapsedMilliseconds: 1, localResponse: response)
        let presentation = NativeSourceIssuePresentation()
        let host = UIHostingController(rootView: NavigationStack {
            Form { NativeSourceIssueView(model: model, installation: installation, issue: issue, presentation: presentation) }
        })
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene); window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; previous?.makeKeyAndVisible() }
        window.layoutIfNeeded(); host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        presentation.destination = .response
        for _ in 0..<100 {
            if descendants(window).compactMap({ $0 as? UINavigationBar }).contains(where: { $0.topItem?.title == "响应详情" }) { break }
            try await Task.sleep(for: .milliseconds(30))
        }
        // Navigation titles appear before UIKit finishes presenting. Wait for the
        // transition itself before capturing or dismissing the sheet.
        for _ in 0..<100 {
            if let presented = host.presentedViewController, !presented.isBeingPresented, presented.transitionCoordinator == nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNotNil(host.presentedViewController)
        XCTAssertFalse(host.presentedViewController?.isBeingPresented ?? true)
        XCTAssertNil(host.presentedViewController?.transitionCoordinator)
        let titles = descendants(window).compactMap { ($0 as? UINavigationBar)?.topItem?.title }
        XCTAssertTrue(titles.contains("响应详情"))
        XCTAssertFalse(titles.contains("书源设置"))
        XCTAssertEqual(presentation.destination, .response)
        XCTAssertNil(host.presentedViewController?.presentedViewController, "Only one modal should open")
        let image = UIGraphicsImageRenderer(size: window.bounds.size).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image); attachment.name = "failed-response-single-presentation"; attachment.lifetime = .keepAlways; add(attachment)
        presentation.destination = nil
        for _ in 0..<100 {
            if host.presentedViewController == nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNil(host.presentedViewController)
    }

    func testBrowserPreservesSameNamedParentAndHostCookiesThroughSaveAndReopen() async throws {
        let allowed: Set<String> = ["https://www.website.invalid", "https://read.website.invalid"]
        let browser = NativeSourceLoginBrowser(origin: origin, credentialOrigins: allowed, allowLoopbackHTTP: true)
        defer { browser.close() }
        try await browser.prepare(cookies: [])
        try await waitForLogin(browser)
        let webView = try XCTUnwrap(browser.webView)
        for (domain, value) in [(".website.invalid", "parent"), ("www.website.invalid", "host")] {
            let cookie = try XCTUnwrap(HTTPCookie(properties: [.name: "sid", .value: value, .domain: domain, .path: "/", .secure: "TRUE"]))
            await webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)
        }
        let captured = try await browser.cookies()
        XCTAssertEqual(captured.filter { $0.name == "sid" }.count, 3)
        XCTAssertEqual(captured.filter { $0.name == "sid" && $0.domain == "website.invalid" }.count, 2)
        let reopened = NativeSourceLoginBrowser(origin: origin, credentialOrigins: allowed, allowLoopbackHTTP: true)
        defer { reopened.close() }
        try await reopened.prepare(cookies: captured)
        try await waitForLogin(reopened)
        let restored = try await reopened.cookies()
        XCTAssertEqual(Set(restored.filter { $0.name == "sid" }.map(\.key)), Set(captured.filter { $0.name == "sid" }.map(\.key)))
    }

    func testBrowserLoginCookieRotationSurvivesOnlineContentAndFullLibraryRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("rotating-login-\(UUID())/archive.sqlite")
        let persistence = RuntimeMemoryCredentials()
        let model = NativeSourceLibrary(databaseURL: directory, credentials: SourceCredentialVault(persistence: persistence), allowLoopbackHTTP: true)
        let scenario = UUID().uuidString
        var source = BookSource(bookSourceUrl: origin, bookSourceName: "Rotating cookie fixture")
        source.loginUrl = "/website/rotating-login?session=\(scenario)"
        source.searchUrl = "/html/search?q={{key}}&page={{page}}"
        source.ruleSearch = .init(bookList: "@css:.book", name: "@css:.title@text", bookUrl: "@css:.title@href")
        var info = BookInfoRule(); info.name = "@css:h1@text"; info.tocUrl = "@js:'/website/rotating/catalog?session=\(scenario)'"; source.ruleBookInfo = info
        var toc = TocRule(); toc.chapterList = "@css:.chapter"; toc.chapterName = "@css:a@text"; toc.chapterUrl = "@css:a@href"; source.ruleToc = toc
        var content = ContentRule(); content.content = "@css:article@text"; source.ruleContent = content
        try await model.install(model.inspectCandidates(String(decoding: try SourceCoding.encode(source), as: UTF8.self)))
        let installation = try XCTUnwrap(model.installations.first)
        let initial = try await model.provider(installation)
        let result = try await initial.search(.init(query: "demo"))
        let book = try await model.services().1.addBook(provider: initial, ref: XCTUnwrap(result.items.first?.ref))
        do { _ = try await model.services().1.refreshCatalog(provider: initial, book: book.details.ref); XCTFail("Unauthenticated catalog succeeded") }
        catch let error as SourceExtractionFailure {
            let local = try XCTUnwrap(error.localResponse)
            XCTAssertEqual(local.httpExchanges.last?.sentCookieCount, 0)
            XCTAssertEqual(local.httpExchanges.last?.status, 202)
        }
        let context = try await model.credentialContext(installation, accountID: "guest")
        let browser = NativeSourceLoginBrowser(origin: origin, request: try model.websiteLoginRequest(installation, fallbackOrigin: origin),
            credentialOrigins: context.session.allowedOrigins, allowLoopbackHTTP: true)
        defer { browser.close() }
        try await browser.prepare(cookies: [])
        try await waitForLogin(browser)
        try await model.saveLoginCookies(browser.cookies(), origins: context.session.allowedOrigins, context: context)
        browser.close()
        for attempt in 0..<3 {
            // A different vault and library must reload rotated credentials from secure persistence.
            let active = attempt == 0 ? model : NativeSourceLibrary(databaseURL: directory,
                credentials: SourceCredentialVault(persistence: persistence), allowLoopbackHTTP: true)
            await active.reload()
            XCTAssertEqual(active.shelf.map(\.book.key), [book.key])
            let provider = try await active.provider(installation, scope: book.key.scope)
            let catalog = try await active.services().1.refreshCatalog(provider: provider, book: book.details.ref)
            let chapter = try await active.services().1.chapter(provider: active.provider(installation, scope: book.key.scope),
                book: catalog.book, chapter: XCTUnwrap(catalog.chapters.first?.ref), policy: .reload, catalog: catalog)
            XCTAssertEqual(chapter.document.plainText, "Rotating session chapter.")
        }
        let records = await SourceDiagnostics.shared.records().filter { $0.sourceDigest == installation.digest && [.chapters, .content].contains($0.operation) && $0.code == "OK" }
        XCTAssertEqual(records.count, 6)
        XCTAssertTrue(records.allSatisfy { $0.httpExchanges?.last?.sentCookieCount ?? 0 > 0 })
        XCTAssertEqual(Set(records.compactMap(\.credentialRevisionDigest)).count, 1, "Routine rotation must not change the login generation")
    }

    func testCancelledWebsiteLoginIsDiscardedAndUnsafeNavigationIsBlocked() async throws {
        let model = accountModel()
        try await model.install(source("return {items:[],nextCursor:null};"))
        let installation = try XCTUnwrap(model.installations.first)
        let account = try await model.services().0.addAccount(name: "Reader", installationID: installation.id)
        try await model.selectAccount(account.id, installation: installation)
        let context = try await model.credentialContext(installation, accountID: account.id)
        let browser = NativeSourceLoginBrowser(origin: origin, allowLoopbackHTTP: true)
        try await browser.prepare(cookies: [])
        try await waitForLogin(browser)
        let view = try XCTUnwrap(browser.webView)
        _ = try await script("await fetch('/state/login'); return 'done';", in: view)
        let marker = UUID().uuidString
        let alternate = origin.replacingOccurrences(of: "127.0.0.1", with: "localhost")
        // The host-only check intentionally returns 400, but still records a reachable control request.
        let (_, control) = try await URLSession.shared.data(from: URL(string: alternate + "/outside-control-" + marker)!)
        XCTAssertEqual((control as? HTTPURLResponse)?.statusCode, 400)
        let allowed = try await script("const r = await fetch('\(alternate)/website/cross-origin?marker=\(marker)'); return String(r.status);", in: view)
        XCTAssertEqual(allowed, "200", "Interactive login must support identity providers and website resources")
        let (diagnosticsData, _) = try await URLSession.shared.data(from: URL(string: origin + "/diagnostics")!)
        let diagnostics = try object(String(decoding: diagnosticsData, as: UTF8.self))
        let requests = try XCTUnwrap(diagnostics["requests"] as? [[String: Any]])
        XCTAssertTrue(requests.contains { ($0["path"] as? String) == "/outside-control-" + marker })
        XCTAssertTrue(requests.contains { ($0["path"] as? String) == "/website/cross-origin?marker=" + marker })
        view.load(URLRequest(url: URL(string: "http://outside.example/")!))
        for _ in 0..<50 {
            if browser.message != nil { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(browser.message)
        XCTAssertEqual(view.url.flatMap(SourceHostHTTPPolicy.origin), origin)
        browser.close()
        let saved = try await context.session.headers(for: URL(string: origin)!)
        XCTAssertTrue(saved.isEmpty)
        let fresh = NativeSourceLoginBrowser(origin: origin, allowLoopbackHTTP: true)
        defer { fresh.close() }
        try await fresh.prepare(cookies: [])
        try await waitForLogin(fresh)
        let cookies = try await fresh.cookies()
        XCTAssertFalse(cookies.contains { $0.name == "fixture_session" })
    }

    func testSourceReplacementRejectsAlreadyOpenCredentialEditor() async throws {
        let model = accountModel()
        let original = try await model.inspect(SourceAssets.script("OfflineExample.source"))
        try await model.install(original)
        let installation = try XCTUnwrap(model.installations.first)
        let account = try await model.services().0.addAccount(name: "Reader", installationID: installation.id)
        try await model.selectAccount(account.id, installation: installation)
        let context = try await model.credentialContext(installation, accountID: account.id)
        let candidate = try await model.inspect(original.source.replacingOccurrences(of: "离线示例", with: "Edited account fixture"))
        try await model.replace(installation, with: candidate, resetConfiguration: false, originURL: nil, locallyModified: true)
        do {
            try await model.saveBearer("discarded-token", origin: installation.origins[0], context: context)
            XCTFail("Stale credential editor saved a token")
        } catch let error as SourceDomainError { XCTAssertEqual(error.code, .stale) }
        let status = try await model.credentials.status(scope: context.session.scope)
        XCTAssertTrue(status.bearerOrigins.isEmpty)
    }

    func testCredentialPersistenceUsesActualSimulatorKeychain() async throws {
        let service = "org.example.source-tests.\(UUID().uuidString)"
        defer { SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary) }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var probe: CFTypeRef?
        let initialStatus = SecItemCopyMatching(query as CFDictionary, &probe)
        XCTAssertEqual(initialStatus, errSecItemNotFound, "Simulator Keychain status: \(initialStatus). The test host needs a signed application identity.")
        let persistence = SourceKeychainCredentials(service: service)
        let scope = try SourceScope(installationID: UUID(), accountID: UUID().uuidString)
        let vault = SourceCredentialVault(persistence: persistence)
        let session = try await vault.session(scope: scope, allowedOrigins: ["https://fixture.example"])
        try await vault.setBearer("synthetic-token", origin: "https://fixture.example", session: session)
        let reloaded = SourceCredentialVault(persistence: persistence)
        let current = try await reloaded.session(scope: scope, allowedOrigins: ["https://fixture.example"])
        let headers = try await current.headers(for: URL(string: "https://fixture.example/")!)
        XCTAssertEqual(headers, ["Authorization": "Bearer synthetic-token"])
        try await reloaded.clear(scope: scope)
        let empty = try await SourceCredentialVault(persistence: persistence).session(scope: scope, allowedOrigins: ["https://fixture.example"])
        let afterClear = try await empty.headers(for: URL(string: "https://fixture.example/")!)
        XCTAssertTrue(afterClear.isEmpty)
    }
    func testSwitchingGuestAccountRejectsDelayedStateWrites() async throws {
        let model = accountModel()
        let snapshot = try await source("await ctx.storage.set('started', true); await new Promise(r => setTimeout(r, 800)); await ctx.storage.set('late', true); return {items:[],nextCursor:null};")
        try await model.install(snapshot)
        let installation = try XCTUnwrap(model.installations.first)
        let archive = try model.services().0
        let guest = try SourceScope(installationID: installation.id)
        let provider = try await model.provider(installation)
        let operation = Task { try await provider.search(.init(query: "test")) }
        var started = false
        for _ in 0..<750 {
            if try await archive.state(scope: guest, key: "started") != nil { started = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(started, "Source operation never reached the state bridge")
        let account = try await archive.addAccount(name: "Reader", installationID: installation.id)
        try await model.selectAccount(account.id, installation: installation)
        do { _ = try await operation.value; XCTFail("Revoked guest operation succeeded") }
        catch let error as SourceDomainError { XCTAssertEqual(error.code, .stale) }
        let late = try await archive.state(scope: guest, key: "late")
        XCTAssertNil(late)
    }

    func testSourceReplacementValidatesNonselectedAccountSettings() async throws {
        let model = accountModel()
        let original = try await source("return {items:[],nextCursor:null};", settings: "{region:{type:'enum',label:'Region',default:'a',options:[{value:'a',label:'A'},{value:'b',label:'B'}]}}")
        try await model.install(original)
        let installation = try XCTUnwrap(model.installations.first)
        let archive = try model.services().0
        let account = try await archive.addAccount(name: "Reader", installationID: installation.id)
        let scope = try SourceScope(installationID: installation.id, accountID: account.id)
        try await archive.saveConfiguration(.object(["region": .string("b")]), scope: scope)
        let changed = try await model.inspect(original.source.replacingOccurrences(of: "options:[{value:'a',label:'A'},{value:'b',label:'B'}]", with: "options:[{value:'a',label:'A'}]"))
        do {
            try await model.replace(installation, with: changed, resetConfiguration: false, originURL: nil, locallyModified: true)
            XCTFail("Source update ignored the nonselected account's invalid settings")
        } catch { XCTAssertEqual(model.installations.first?.digest, installation.digest) }
        try await model.replace(installation, with: changed, resetConfiguration: true, originURL: nil, locallyModified: true)
        let reset = try await archive.configuration(scope: scope)
        XCTAssertEqual(reset, .object([:]))
    }

    func testNativeAccountSettingsRenderAtPhoneAndAccessibilitySizes() async throws {
        let model = accountModel()
        try await model.install(model.inspect(SourceAssets.script("OfflineExample.source")))
        let installation = try XCTUnwrap(model.installations.first)
        for (name, size, category, dark) in [
            ("phone", CGSize(width: 390, height: 844), UIContentSizeCategory.large, false),
            ("accessibility", CGSize(width: 390, height: 844), UIContentSizeCategory.accessibilityExtraExtraExtraLarge, true)
        ] {
            let presentation = NativeSourceAccountPresentation()
            let screen = NavigationStack { NativeSourceAccountsView(model: model, initialInstallation: installation, presentation: presentation) }
                .environment(\.dynamicTypeSize, dark ? .accessibility5 : .large)
            let host = UIHostingController(rootView: screen)
            host.traitOverrides.preferredContentSizeCategory = category
            host.overrideUserInterfaceStyle = dark ? .dark : .light
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let previous = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene), container = UIViewController()
            window.rootViewController = container; window.makeKeyAndVisible()
            container.addChild(host); host.view.frame = CGRect(origin: .zero, size: size)
            container.view.addSubview(host.view); host.didMove(toParent: container)
            defer { window.isHidden = true; previous?.makeKeyAndVisible() }
            window.layoutIfNeeded(); host.view.layoutIfNeeded()
            for _ in 0..<150 {
                if presentation.settings?.selectedID == "guest" { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertEqual(presentation.settings?.selectedID, "guest", "Website login must be available without creating a local account")
            try await Task.sleep(for: .milliseconds(300))
            window.layoutIfNeeded(); host.view.layoutIfNeeded()
            var rendered = false
            let image = UIGraphicsImageRenderer(size: size).image { _ in
                rendered = host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
            }
            XCTAssertTrue(rendered)
            let pixels = try XCTUnwrap(image.cgImage?.dataProvider?.data) as Data
            XCTAssertGreaterThan(Set(pixels).count, 8)
            let attachment = XCTAttachment(image: image); attachment.name = "native-accounts-" + name; attachment.lifetime = .keepAlways
            add(attachment)
            for scroll in descendants(host.view).compactMap({ $0 as? UIScrollView }) where scroll.bounds.width > 100 {
                XCTAssertLessThanOrEqual(scroll.contentSize.width, scroll.bounds.width + 1)
            }
        }
    }

    func testNativeCoverUsesAccountCredentialsAndPersistsAcrossModelRestart() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cover-model-\(UUID().uuidString)/native.sqlite3")
        let credentials = SourceCredentialVault(persistence: RuntimeMemoryCredentials())
        let model = NativeSourceLibrary(databaseURL: url, credentials: credentials, allowLoopbackHTTP: true)
        try await model.install(source("return {items:[],nextCursor:null};"))
        let installation = try XCTUnwrap(model.installations.first)
        let account = try await model.services().0.addAccount(name: "Reader", installationID: installation.id)
        try await model.selectAccount(account.id, installation: installation)
        let context = try await model.credentialContext(installation, accountID: account.id)
        try await model.saveLoginCookies([.init(origin: origin, name: "fixture_session", value: "fixture-a", secure: false)], origin: origin, context: context)
        let scope = try await model.selectedScope(installation)
        let cover = SourceWire.Cover(url: origin + "/covers/private.png?request=" + UUID().uuidString)
        let first = try await model.cover(cover, installation: installation, scope: scope)
        let image = try XCTUnwrap(UIImage(data: first))
        XCTAssertEqual(image.size.width, 64); XCTAssertEqual(image.size.height, 96)
        let reopened = NativeSourceLibrary(databaseURL: url, credentials: credentials, allowLoopbackHTTP: true)
        await reopened.reload()
        let restored = try await reopened.cover(cover, installation: installation, scope: scope)
        XCTAssertEqual(restored, first)
        let (diagnosticData, _) = try await URLSession.shared.data(from: URL(string: origin + "/diagnostics")!)
        let requests = try XCTUnwrap(object(String(decoding: diagnosticData, as: UTF8.self))["requests"] as? [[String: Any]])
        let path = try XCTUnwrap(URLComponents(string: cover.url)).percentEncodedPath + "?" + (URLComponents(string: cover.url)?.percentEncodedQuery ?? "")
        XCTAssertEqual(requests.filter { ($0["path"] as? String) == path }.count, 1)
        let authenticated = try await reopened.provider(installation, scope: scope)
        try await reopened.selectAccount("guest", installation: installation)
        do { _ = try await reopened.cover(cover, installation: installation, scope: scope, expectedIdentity: authenticated.descriptor.identity); XCTFail("Old cover operation survived a website session change") }
        catch let error as SourceDomainError { XCTAssertEqual(error.code, .stale) }
        do { _ = try await reopened.cover(cover, installation: installation, scope: scope); XCTFail("New website session reused an authenticated cover") }
        catch let error as SourceDomainError { XCTAssertEqual(error.code, .invalidData) }
        let (afterData, _) = try await URLSession.shared.data(from: URL(string: origin + "/diagnostics")!)
        let after = try XCTUnwrap(object(String(decoding: afterData, as: UTF8.self))["requests"] as? [[String: Any]])
        let matching = after.filter { ($0["path"] as? String) == path }
        XCTAssertEqual(matching.count, 2)
        XCTAssertEqual(matching.last?["hasCookie"] as? Bool, false)
    }

    func testSearchAuthenticationFailureStaysTypedAndDiagnosticExportDropsWebsiteMessage() async throws {
        let marker = "secret-fixture-message-" + UUID().uuidString
        let model = accountModel()
        let snapshot = try await source("throw ctx.errors.authRequired({message:'\(marker)'});")
        try await model.install(snapshot)
        model.search("private-query")
        try await waitForNativeSearch(model)
        XCTAssertTrue(model.results.isEmpty)
        let failure = try XCTUnwrap(model.searchFailures.first)
        XCTAssertEqual(failure.issue.code, "AUTH_REQUIRED")
        XCTAssertEqual(failure.issue.recovery, .login)
        XCTAssertFalse(failure.issue.message.contains(marker))
        let exported = try await SourceDiagnostics.shared.export()
        let text = String(decoding: exported, as: UTF8.self)
        XCTAssertFalse(text.contains(marker)); XCTAssertFalse(text.contains("private-query"))
        let records = await SourceDiagnostics.shared.records()
        XCTAssertTrue(records.contains { $0.sourceDigest == snapshot.sha256 && $0.operation == .search && $0.code == "AUTH_REQUIRED" })
    }


    func testRuntimeFailureReportsExactAuthorLineAndNoRawStack() async throws {
        let snapshot = try await source("return broken();", topLevel: """
        function broken() {
          throw new Error('synthetic author failure');
        }
        """)
        let lines = snapshot.source.components(separatedBy: "\n")
        let expected = try XCTUnwrap(lines.firstIndex { $0.contains("throw new Error") }) + 1
        do { _ = try await run(snapshot); XCTFail("Expected a source error") }
        catch let failure as SourceFailure {
            XCTAssertEqual(failure.code, "SCRIPT_ERROR")
            XCTAssertEqual(failure.line, expected)
            let column = try XCTUnwrap(failure.column)
            XCTAssertTrue((1...lines[expected - 1].utf16.count + 1).contains(column))
            let encoded = String(decoding: try JSONEncoder().encode(failure), as: UTF8.self)
            XCTAssertFalse(encoded.contains("blob:")); XCTAssertFalse(encoded.contains("stack"))
        }
        let topLevel = try await source("return {items:[],nextCursor:null};", topLevel: "throw new Error('top-level fixture');")
        do { _ = try await run(topLevel); XCTFail("Expected top-level failure") }
        catch let failure as SourceFailure {
            XCTAssertEqual(failure.code, "SCRIPT_ERROR"); XCTAssertEqual(failure.line, 2)
        }
    }

    func testBuiltMultiFileSourceMatchesNodeAndKeepsFailureLocation() async throws {
        struct Case: Decodable { let operation: String; let input: SourceJSON; let expected: SourceJSON }
        struct Failure: Decodable { let input: SourceJSON; let code: String; let line: Int }
        struct Fixture: Decodable { let source: String; let sha256: String; let cases: [Case]; let failure: Failure }
        let (data, _) = try await URLSession.shared.data(from: URL(string: origin + "/built-offline")!)
        let fixture = try JSONDecoder().decode(Fixture.self, from: data)
        let snapshot = try await SourceInspector().inspect(Data(fixture.source.utf8))
        XCTAssertEqual(snapshot.sha256, fixture.sha256)
        XCTAssertGreaterThanOrEqual(fixture.cases.count, 4)
        for sample in fixture.cases {
            let operation = try XCTUnwrap(SourceOperation(rawValue: sample.operation))
            let input = String(decoding: try SourceCoding.encode(sample.input), as: UTF8.self)
            // Every operation gets a fresh WebKit execution page, including persisted refs from prior results.
            let result = try await SourceRuntime().run(operation, inputJSON: input, snapshot: snapshot)
            XCTAssertEqual(try SourceCoding.decode(SourceJSON.self, from: Data(result.utf8)), sample.expected, sample.operation)
        }
        let input = String(decoding: try SourceCoding.encode(fixture.failure.input), as: UTF8.self)
        do { _ = try await SourceRuntime().run(.content, inputJSON: input, snapshot: snapshot); XCTFail("Expected missing chapter") }
        catch let error as SourceFailure { XCTAssertEqual(error.code, fixture.failure.code); XCTAssertEqual(error.line, fixture.failure.line) }
        let model = accountModel()
        try await model.install(snapshot)
        let installation = try XCTUnwrap(model.installations.first)
        let provider = try await model.provider(installation)
        do { _ = try await provider.content(.init(book: .init(id: "demo"), chapter: .init(id: "missing"))); XCTFail("Expected source diagnostic") }
        catch let error as SourceFailure { XCTAssertEqual(error.line, fixture.failure.line) }
        let records = await SourceDiagnostics.shared.records()
        let record = try XCTUnwrap(records.first { $0.sourceDigest == snapshot.sha256 && $0.code == "PARSE" })
        XCTAssertEqual(record.line, fixture.failure.line)
        let retained = try await model.services().0.sourceSnapshot(digest: record.sourceDigest)
        XCTAssertEqual(retained?.source, fixture.source)
    }
}
