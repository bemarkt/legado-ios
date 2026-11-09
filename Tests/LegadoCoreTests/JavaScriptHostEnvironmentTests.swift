import Foundation
import Testing
@testable import LegadoCore

private final class ScopedHostFixture: JavaScriptSourceState, JavaScriptCookieState, JavaScriptRedirectNetworkLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var state: [String: [String: String]] = [:]
    private var cookies: [String: String] = [:]
    private var requests: [URLRequest] = []
    private var messages: [String] = []
    let release = DispatchSemaphore(value: 0)

    func get(sourceID: String, key: String) throws -> String { lock.withLock { state[sourceID]?[key] ?? "" } }
    func put(sourceID: String, key: String, value: String) throws { lock.withLock { state[sourceID, default: [:]][key] = value } }
    func loginHeaders(sourceID: String) throws -> [String: String] {
        let text = try get(sourceID: sourceID, key: "loginHeader")
        return (try? JSONDecoder().decode([String: String].self, from: Data(text.utf8))) ?? [:]
    }
    func cookieHeader(for value: String) throws -> String { lock.withLock { cookies[value] ?? "" } }
    func cookie(for value: String, key: String) throws -> String {
        try cookieHeader(for: value).split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            .first(where: { $0.hasPrefix(key + "=") }).map { String($0.dropFirst(key.count + 1)) } ?? ""
    }
    func setCookie(_ cookie: String, for value: String) throws { lock.withLock { cookies[value] = cookie } }
    func removeCookies(for value: String) throws { _ = lock.withLock { cookies.removeValue(forKey: value) } }
    func record(_ message: String) { lock.withLock { messages.append(message) } }
    var calls: [URLRequest] { lock.withLock { requests } }
    var logs: [String] { lock.withLock { messages } }

    func load(_ request: URLRequest, followRedirects: Bool) throws -> HTTPResponse {
        #expect(!followRedirects)
        return try load(request)
    }
    func load(_ request: URLRequest) throws -> HTTPResponse {
        lock.withLock { requests.append(request) }
        let url = try #require(request.url)
        if url.path == "/fail" { throw URLError(.networkConnectionLost) }
        if url.path == "/late" {
            guard release.wait(timeout: .now() + 3) == .success else { throw URLError(.timedOut) }
        }
        return .init(data: Data("response".utf8), statusCode: 200,
                     headers: ["Set-Cookie": "received=fixture"], finalURL: url)
    }
    func environment(_ name: String, control: JavaScriptExecutionControl = .init()) -> JavaScriptHostEnvironment {
        .init(sourceState: self, cookies: self, control: control, network: self, userAgent: "UA/" + name,
              identifier: { name }, record: { [self] in record($0) })
    }
}

struct JavaScriptHostEnvironmentTests {
    private var source: BookSource { .init(bookSourceUrl: "https://fixture.invalid", bookSourceName: "Scoped fixture") }

    @Test func sourceCookiesLoginIdentityAndLogsStayInTheSelectedEnvironment() throws {
        let alice = ScopedHostFixture(), bob = ScopedHostFixture()
        let a = RuleExecutionContext(source: source, environment: alice.environment("alice"))
        let b = RuleExecutionContext(source: source, environment: bob.environment("bob"))
        let engine = JavaScriptRuleEvaluator()
        let write = #"source.put('token','private'); source.putLoginHeader('{"Authorization":"alice"}'); source.putLoginInfo('{"name":"alice"}'); cookie.setCookie(source.bookSourceUrl,'session=alice'); console.log('alice-log'); java.androidId()"#
        #expect(try engine.evaluate(script: write, result: .null, executionContext: a).value == .string("alice"))
        let read = "[source.get('token'), source.getLoginHeader(), cookie.getCookie(source.bookSourceUrl), java.androidId()].join('|')"
        #expect(try engine.evaluate(script: read, result: .null, executionContext: b).value.stringValue == "|||bob")
        #expect(try alice.get(sourceID: source.id, key: "loginInfo") == #"{"name":"alice"}"#)
        #expect(try bob.get(sourceID: source.id, key: "loginInfo") == "")
        #expect(alice.logs.contains("alice-log"))
        #expect(bob.logs.isEmpty)
        #expect(try engine.evaluate(script: "source.getHeaderMap(true).Authorization", result: .null, executionContext: a).value == .string("alice"))
        #expect(try engine.evaluate(script: "source.get('token')", result: .null, executionContext: a).value == .string("private"))
    }

    @Test func headerURLAndResponseScriptsUseTheSameStateNetworkAndUserAgent() throws {
        let store = ScopedHostFixture(), env = store.environment("alice")
        var fixture = source
        fixture.header = #"@js:JSON.stringify({'X-Profile':source.get('token')})"#
        try store.put(sourceID: fixture.id, key: "token", value: "alice")
        try store.put(sourceID: fixture.id, key: "loginHeader", value: #"{"Authorization":"local-only"}"#)
        let ctx = RuleExecutionContext(baseURL: fixture.bookSourceUrl, source: fixture, environment: env)
        let engine = JavaScriptRuleEvaluator()
        let headers = try BookSourceHeaderResolver().resolve(fixture, environment: env)
        #expect(headers["X-Profile"] == "alice")
        let prepared = try LegadoURLBuilder().prepare("https://fixture.invalid/{{source.get('token')}}", context: .init(source: fixture, environment: env))
        #expect(prepared.url.path == "/alice")
        let request = #"/alice,{"bodyJs":"result + ':' + source.get('token')"}"#
        let value = try engine.evaluate(script: "java.ajax(result)", result: .string(request), executionContext: ctx)
        #expect(value.value == .string("response:alice"))
        _ = try engine.evaluate(script: "java.get('https://fixture.invalid/direct').body()", result: .null, executionContext: ctx)
        #expect(store.calls.count == 2)
        for call in store.calls {
            #expect(call.value(forHTTPHeaderField: "Authorization") == "local-only")
            #expect(call.value(forHTTPHeaderField: "X-Profile") == "alice")
            #expect(call.value(forHTTPHeaderField: "User-Agent") == "UA/alice")
            #expect(!call.httpShouldHandleCookies)
        }
        #expect(try store.cookieHeader(for: "https://fixture.invalid/alice") == "received=fixture")
    }

    @Test func scopedNetworkAndNestedBrowserFailuresAreNotReturnedAsContent() throws {
        let store = ScopedHostFixture()
        let ctx = RuleExecutionContext(baseURL: source.bookSourceUrl, source: source, environment: store.environment("alice"))
        let scripts = [
            "java.ajax('/fail')", "java.get('https://fixture.invalid/fail')",
            "java.connect('/fail')", "java.ajaxAll(['/fail'])", "java.webView('html')",
            "java.startBrowser('https://fixture.invalid')",
            #"java.getString('@js:java.webView("html")')"#,
            #"java.getStringList('@js:java.webView("html")')"#
        ]
        for script in scripts {
            #expect(throws: RuleEngineError.self) {
                try JavaScriptRuleEvaluator().evaluate(script: script, result: .null, executionContext: ctx)
            }
        }
    }

    @Test func cancellingAnActiveLoopInterruptsTheVMAndAllowsAFreshOperation() async throws {
        let store = ScopedHostFixture(), control = JavaScriptExecutionControl(timeout: .seconds(10))
        let ctx = RuleExecutionContext(baseURL: source.bookSourceUrl, source: source, environment: store.environment("alice", control: control))
        let started = ContinuousClock.now
        let task = Task { try await JavaScriptRuleEvaluator(timeoutMilliseconds: 5_000).evaluateAsync(
            script: "java.ajax('/started'); while(true) {}", result: .null, executionContext: ctx) }
        while store.calls.isEmpty && ContinuousClock.now - started < .seconds(2) {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!store.calls.isEmpty)
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled loop returned successfully") }
        catch { #expect(error is CancellationError) }
        #expect(ContinuousClock.now - started < .seconds(3))
        let fresh = RuleExecutionContext(source: source, environment: store.environment("alice"))
        #expect(try await JavaScriptRuleEvaluator().evaluateAsync(script: "'recovered'", result: .null, executionContext: fresh).value == .string("recovered"))
    }

    @Test func cancellationRejectsLateNetworkCookiesEvenWhenScriptCatchesTheError() async throws {
        let store = ScopedHostFixture(), env = store.environment("alice")
        let ctx = RuleExecutionContext(baseURL: source.bookSourceUrl, source: source, environment: env)
        let started = ContinuousClock.now
        let task = Task { try await JavaScriptRuleEvaluator().evaluateAsync(
            script: "try { java.ajax('/late'); } catch(e) {} 'pretend-success'", result: .null, executionContext: ctx) }
        while store.calls.isEmpty && ContinuousClock.now - started < .seconds(2) {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(!store.calls.isEmpty)
        task.cancel()
        store.release.signal()
        do { _ = try await task.value; Issue.record("Cancellation was swallowed by JavaScript") }
        catch { #expect(error is CancellationError) }
        #expect(try store.cookieHeader(for: "https://fixture.invalid/late") == "")
    }

    @Test func anExpiredOperationCannotStartANestedNetworkCall() throws {
        let store = ScopedHostFixture(), control = JavaScriptExecutionControl(timeout: .zero)
        let ctx = RuleExecutionContext(source: source, environment: store.environment("alice", control: control))
        #expect(throws: URLError.self) {
            try JavaScriptRuleEvaluator().evaluate(script: "java.ajax('https://fixture.invalid')", result: .null, executionContext: ctx)
        }
        #expect(store.calls.isEmpty)
    }
}
