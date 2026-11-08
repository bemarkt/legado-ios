import Foundation
import Network
import Testing
@testable import LegadoCore

/// Real loopback HTTP: exercises URLSession redirects, byte streaming, timeouts and cancellation.
private final class NativeHTTPFixture: @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        let target: String
        let headers: [String: String]
        let body: Data
        let occurrence: Int
    }
    struct Response: Sendable {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data("ok".utf8)
        var delay: TimeInterval = 0
        var chunks: [Data]? = nil
        var chunkDelay: TimeInterval = 0.05
    }
    struct Statistics: Sendable { let requests: [Request]; let active: Int; let maximumActive: Int }
    private let queue = DispatchQueue(label: "native-source-http-fixture")
    private let listener: NWListener
    private let respond: @Sendable (Request) -> Response
    private var starting: CheckedContinuation<String, Error>?
    private var connections: [UUID: NWConnection] = [:]
    private var active = Set<UUID>()
    private var maximumActive = 0
    private var requests: [Request] = []
    init(_ respond: @escaping @Sendable (Request) -> Response) throws {
        self.respond = respond
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }
    func start() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.starting = continuation
                self.listener.stateUpdateHandler = { [weak self] state in
                    guard let self, let pending = self.starting else { return }
                    if case .ready = state, let port = self.listener.port {
                        self.starting = nil; pending.resume(returning: "http://127.0.0.1:\(port.rawValue)")
                    } else if case .failed(let error) = state { self.starting = nil; pending.resume(throwing: error) }
                }
                self.listener.newConnectionHandler = { [weak self] connection in
                    guard let self else { connection.cancel(); return }
                    let id = UUID(); self.connections[id] = connection
                    connection.stateUpdateHandler = { [weak self] state in
                        if case .cancelled = state { self?.finish(id) }
                        if case .failed = state { self?.finish(id) }
                    }
                    connection.start(queue: self.queue)
                    self.receive(connection, id: id, buffer: Data())
                }
                self.listener.start(queue: self.queue)
                self.queue.asyncAfter(deadline: .now() + 3) {
                    guard let pending = self.starting else { return }
                    self.starting = nil; self.listener.cancel(); pending.resume(throwing: URLError(.timedOut))
                }
            }
        }
    }
    func stop() {
        queue.async {
            self.listener.cancel()
            for connection in self.connections.values { connection.cancel() }
            self.connections.removeAll(); self.active.removeAll()
        }
    }
    func statistics() async -> Statistics {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: Statistics(requests: self.requests, active: self.active.count, maximumActive: self.maximumActive)) }
        }
    }
    private func finish(_ id: UUID) { active.remove(id); connections.removeValue(forKey: id)?.cancel() }
    private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard buffer.count <= 3_000_000 else { self.finish(id); return }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let lines = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
                let first = (lines.first ?? "").split(separator: " ")
                guard first.count >= 2 else { self.finish(id); return }
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    if let colon = line.firstIndex(of: ":") { headers[String(line[..<colon]).lowercased()] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces) }
                }
                let length = Int(headers["content-length"] ?? "0") ?? 0
                guard buffer.count - end.upperBound >= length else {
                    if complete || error != nil { self.finish(id) }
                    else { self.receive(connection, id: id, buffer: buffer) }
                    return
                }
                let target = String(first[1])
                let request = Request(method: String(first[0]), target: target, headers: headers,
                    body: Data(buffer[end.upperBound..<(end.upperBound + length)]), occurrence: self.requests.filter { $0.target == target }.count + 1)
                self.requests.append(request); self.active.insert(id); self.maximumActive = max(self.maximumActive, self.active.count)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, complete, error in
                    if complete || error != nil { self?.finish(id) }
                }
                let response = self.respond(request)
                self.queue.asyncAfter(deadline: .now() + response.delay) { self.send(response, request: request, connection: connection, id: id) }
            } else if complete || error != nil { self.finish(id) }
            else { self.receive(connection, id: id, buffer: buffer) }
        }
    }
    private func send(_ response: Response, request: Request, connection: NWConnection, id: UUID) {
        guard connections[id] != nil else { return }
        var headers = response.headers
        headers["Connection"] = "close"
        if response.chunks != nil { headers["Transfer-Encoding"] = "chunked" }
        else { headers["Content-Length"] = String(response.body.count) }
        let head = "HTTP/1.1 \(response.status) Fixture\r\n" + headers.map { "\($0): \($1)\r\n" }.joined() + "\r\n"
        var data = Data(head.utf8)
        if let chunks = response.chunks, request.method != "HEAD" {
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self else { connection.cancel(); return }
                if error != nil { self.finish(id) }
                else { self.sendChunks(chunks, interval: response.chunkDelay, connection: connection, id: id) }
            })
        } else {
            if request.method != "HEAD" { data.append(response.body) }
            connection.send(content: data, completion: .contentProcessed { [weak self] _ in self?.finish(id) })
        }
    }
    private func sendChunks(_ chunks: [Data], interval: TimeInterval, connection: NWConnection, id: UUID) {
        guard connections[id] != nil else { return }
        guard let first = chunks.first else {
            connection.send(content: Data("0\r\n\r\n".utf8), completion: .contentProcessed { [weak self] _ in self?.finish(id) }); return
        }
        queue.asyncAfter(deadline: .now() + interval) {
            guard self.connections[id] != nil else { return }
            var frame = Data((String(first.count, radix: 16) + "\r\n").utf8)
            frame.append(first); frame.append(Data("\r\n".utf8))
            connection.send(content: frame, completion: .contentProcessed { [weak self] error in
                guard let self else { connection.cancel(); return }
                if error != nil { self.finish(id) }
                else { self.sendChunks(Array(chunks.dropFirst()), interval: interval, connection: connection, id: id) }
            })
        }
    }
}

@Suite("Native source HTTP transport", .timeLimit(.minutes(1)))
struct SourceHostHTTPTests {
    private func policy(_ origins: Set<String>, timeout: TimeInterval = 3, bytes: Int = 8192, attempts: Int = 2) -> SourceHostHTTPPolicy {
        .init(origins: origins, allowLoopbackHTTP: true, maximumBytes: bytes, timeout: timeout, maximumAttempts: attempts)
    }
    private func failure(_ code: SourceHostHTTPFailure.Code, _ work: () async throws -> Void) async {
        do { try await work(); Issue.record("Expected \(code)") }
        catch let error as SourceHostHTTPFailure { #expect(error.code == code) }
        catch { Issue.record("Unexpected error: \(error)") }
    }
    private func wait(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw URLError(.timedOut)
    }

    @Test func redirectsDropCrossOriginHeadersAndApplyMethodRules() async throws {
        let target = try NativeHTTPFixture { request in
            .init(body: Data("\(request.method):\(String(decoding: request.body, as: UTF8.self))".utf8))
        }
        let b = try await target.start(); defer { target.stop() }
        let redirect = try NativeHTTPFixture { request in .init(status: request.target == "/307" ? 307 : 303, headers: ["Location": b + "/echo"], body: Data()) }
        let a = try await redirect.start(); defer { redirect.stop() }
        let client = SourceHostHTTPClient(), policy = policy([a,b])
        for status in [303,307] {
            let result = try await client.fetch(.init(url: a + "/\(status)", method: "POST", headers: ["Authorization":"PRIVATE", "X-Secret":"PRIVATE", "Content-Type":"text/plain"], body: Data("payload".utf8).base64EncodedString()), policy: policy)
            let body = String(decoding: try #require(Data(base64Encoded: result.body)), as: UTF8.self)
            #expect(body == (status == 303 ? "GET:" : "POST:payload"))
            #expect(result.url == b + "/echo")
        }
        let requests = await target.statistics().requests
        #expect(requests.count == 2)
        #expect(requests.allSatisfy { $0.headers["authorization"] == nil && $0.headers["x-secret"] == nil })
    }

    @Test func sameOriginRedirectKeepsHeadersAndRejectsForbiddenTargetOrLoop() async throws {
        let server = try NativeHTTPFixture { request in
            if request.target == "/allowed" { return .init(status: 302, headers: ["Location":"/echo"], body: Data()) }
            if request.target == "/outside" { return .init(status: 302, headers: ["Location":"http://127.0.0.1:1/denied"], body: Data()) }
            if request.target == "/loop" { return .init(status: 302, headers: ["Location":"/loop"], body: Data()) }
            return .init(body: Data((request.headers["authorization"] ?? "missing").utf8))
        }
        let origin = try await server.start(); defer { server.stop() }
        let client = SourceHostHTTPClient(), policy = policy([origin])
        let result = try await client.fetch(.init(url: origin + "/allowed", headers: ["Authorization":"retained"]), policy: policy)
        #expect(Data(base64Encoded: result.body) == Data("retained".utf8))
        await failure(.permissionDenied) { _ = try await client.fetch(.init(url: origin + "/outside"), policy: policy) }
        await failure(.resourceLimit) { _ = try await client.fetch(.init(url: origin + "/loop"), policy: policy) }
        await failure(.network) { _ = try await client.fetch(.init(url: origin + "/allowed", redirect: "error"), policy: policy) }
    }

    @Test func redirectedAndDirectTrafficShareTargetOriginLimit() async throws {
        let target = try NativeHTTPFixture { _ in .init(delay: 0.08) }
        let b = try await target.start(); defer { target.stop() }
        let entry = try NativeHTTPFixture { _ in .init(status: 302, headers: ["Location":b + "/slow"], body: Data()) }
        let a = try await entry.start(); defer { entry.stop() }
        let scheduler = SourceWorkScheduler(globalLimit: 4, perOriginLimit: 2)
        let client = SourceHostHTTPClient(scheduler: scheduler), policy = policy([a,b])
        try await withThrowingTaskGroup(of: Void.self) { group in
            for n in 0..<8 {
                group.addTask { _ = try await client.fetch(.init(url: n.isMultiple(of: 2) ? a + "/redirect" : b + "/slow"), policy: policy) }
            }
            try await group.waitForAll()
        }
        let stats = await target.statistics(), counts = await scheduler.counts
        #expect(stats.requests.count == 8 && stats.maximumActive <= 2)
        #expect(counts.active == 0 && counts.waiting == 0)
    }

    @Test func redirectReleasesGlobalPermitBeforeNextHop() async throws {
        let end = try NativeHTTPFixture { _ in .init() }
        let b = try await end.start(); defer { end.stop() }
        let start = try NativeHTTPFixture { _ in .init(status: 302, headers: ["Location":b + "/end"], body: Data()) }
        let a = try await start.start(); defer { start.stop() }
        let scheduler = SourceWorkScheduler(globalLimit: 1, perOriginLimit: 1)
        let result = try await SourceHostHTTPClient(scheduler: scheduler).fetch(.init(url: a + "/start"), policy: policy([a,b]))
        #expect(result.status == 200)
        #expect(await scheduler.counts.active == 0)
    }

    @Test func requestDeadlineIncludesQueueAndTransmission() async throws {
        let server = try NativeHTTPFixture { _ in .init(delay: 0.7) }
        let origin = try await server.start(); defer { server.stop() }
        let scheduler = SourceWorkScheduler(globalLimit: 1, perOriginLimit: 1)
        let holding = Task { try await scheduler.withPermit(origin: origin, deadline: ContinuousClock.now.advanced(by: .seconds(3))) { try await Task.sleep(for: .milliseconds(250)) } }
        try await wait { await scheduler.counts.active == 1 }
        let clock = ContinuousClock(), started = clock.now
        await failure(.timeout) { _ = try await SourceHostHTTPClient(scheduler: scheduler).fetch(.init(url: origin + "/slow"), policy: policy([origin], timeout: 0.4)) }
        let duration = started.duration(to: clock.now)
        #expect(duration < .milliseconds(650))
        try await holding.value
        #expect(await scheduler.counts.active == 0)
    }

    @Test func operationDeadlineAndTrickleBodyCannotRenewTimeout() async throws {
        let server = try NativeHTTPFixture { _ in .init(chunks: Array(repeating: Data("x".utf8), count: 30), chunkDelay: 0.05) }
        let origin = try await server.start(); defer { server.stop() }
        let client = SourceHostHTTPClient(), started = ContinuousClock.now
        await failure(.timeout) {
            _ = try await client.fetch(.init(url: origin + "/trickle"), policy: policy([origin]), deadline: started.advanced(by: .milliseconds(220)))
        }
        #expect(started.duration(to: ContinuousClock.now) < .milliseconds(800))
    }

    @Test func cancellingQueuedAndActiveRequestsReleasesSlots() async throws {
        let server = try NativeHTTPFixture { _ in .init(delay: 1) }
        let origin = try await server.start(); defer { server.stop() }
        let scheduler = SourceWorkScheduler(globalLimit: 1, perOriginLimit: 1)
        let client = SourceHostHTTPClient(scheduler: scheduler), policy = policy([origin])
        let running = Task { try await client.fetch(.init(url: origin + "/one"), policy: policy) }
        try await wait { await server.statistics().requests.count == 1 }
        let queued = Task { try await client.fetch(.init(url: origin + "/two"), policy: policy) }
        try await wait { await scheduler.counts.waiting == 1 }
        queued.cancel(); running.cancel()
        await failure(.cancelled) { _ = try await queued.value }
        await failure(.cancelled) { _ = try await running.value }
        let counts = await scheduler.counts
        #expect(counts.active == 0 && counts.waiting == 0)
        #expect(await server.statistics().requests.count == 1)
        try await wait { await server.statistics().active == 0 }
    }

    @Test func safeRetriesAreBoundedAndWritesAreNotRetried() async throws {
        let server = try NativeHTTPFixture { request in .init(status: request.occurrence == 1 || request.target == "/always" ? 503 : 200, headers: ["Retry-After":"0"]) }
        let origin = try await server.start(); defer { server.stop() }
        let client = SourceHostHTTPClient(), policy = policy([origin])
        #expect(try await client.fetch(.init(url: origin + "/get"), policy: policy).status == 200)
        #expect(try await client.fetch(.init(url: origin + "/post", method: "POST"), policy: policy).status == 503)
        #expect(try await client.fetch(.init(url: origin + "/always"), policy: policy).status == 503)
        let requests = await server.statistics().requests
        #expect(requests.filter { $0.target == "/get" }.count == 2)
        #expect(requests.filter { $0.target == "/post" }.count == 1)
        #expect(requests.filter { $0.target == "/always" }.count == 2)
    }

    @Test func retryDelayDoesNotHoldPermitAndCanBeCancelled() async throws {
        let server = try NativeHTTPFixture { request in .init(status: request.target == "/limited" ? 429 : 200, headers: ["Retry-After":"1"]) }
        let origin = try await server.start(); defer { server.stop() }
        let scheduler = SourceWorkScheduler(globalLimit: 1, perOriginLimit: 1)
        let client = SourceHostHTTPClient(scheduler: scheduler), policy = policy([origin])
        let waiting = Task { try await client.fetch(.init(url: origin + "/limited"), policy: policy) }
        try await wait { await server.statistics().requests.count == 1 }
        try await wait { await scheduler.counts.active == 0 }
        #expect(try await client.fetch(.init(url: origin + "/healthy"), policy: policy).status == 200)
        waiting.cancel()
        await failure(.cancelled) { _ = try await waiting.value }
        #expect(await server.statistics().requests.filter { $0.target == "/limited" }.count == 1)
    }

    @Test func retryAfterOutsideBudgetReturnsOriginalResponse() async throws {
        let server = try NativeHTTPFixture { _ in .init(status: 429, headers: ["Retry-After":"100"]) }
        let origin = try await server.start(); defer { server.stop() }
        let result = try await SourceHostHTTPClient().fetch(.init(url: origin + "/limited"), policy: policy([origin]))
        #expect(result.status == 429 && result.headers["retry-after"] == "100")
        #expect(await server.statistics().requests.count == 1)
    }

    @Test func operationAttemptBudgetCountsRedirectsAndRetries() async throws {
        let server = try NativeHTTPFixture { request in
            if request.target == "/redirect" { return .init(status: 302, headers: ["Location":"/retry"], body: Data()) }
            return .init(status: 503, headers: ["Retry-After":"0"])
        }
        let origin = try await server.start(); defer { server.stop() }
        let budget = SourceHTTPRequestBudget(maximumRequests: 2), client = SourceHostHTTPClient(), policy = policy([origin])
        await failure(.resourceLimit) { _ = try await client.fetch(.init(url: origin + "/redirect"), policy: policy, budget: budget) }
        await failure(.resourceLimit) { _ = try await client.fetch(.init(url: origin + "/later"), policy: policy, budget: budget) }
        #expect(await server.statistics().requests.count == 2)
    }

    @Test func responseLimitsAndCookieIsolationRemainEnforced() async throws {
        let server = try NativeHTTPFixture { request in
            if request.target == "/large" { return .init(body: Data(repeating: 120, count: 40)) }
            if request.target == "/chunked" { return .init(chunks: [Data(repeating: 120, count: 20),Data(repeating: 120, count: 20)]) }
            return .init(headers: ["Set-Cookie":"secret=ignored"], body: Data((request.headers["cookie"] ?? "no-cookie").utf8))
        }
        let origin = try await server.start(); defer { server.stop() }
        let client = SourceHostHTTPClient(), policy = policy([origin], bytes: 32)
        await failure(.resourceLimit) { _ = try await client.fetch(.init(url: origin + "/large"), policy: policy) }
        await failure(.resourceLimit) { _ = try await client.fetch(.init(url: origin + "/chunked"), policy: policy) }
        for _ in 0..<2 {
            let result = try await client.fetch(.init(url: origin + "/cookies"), policy: policy)
            #expect(result.headers["set-cookie"] == nil)
            #expect(Data(base64Encoded: result.body) == Data("no-cookie".utf8))
        }
        await failure(.invalidInput) { _ = try await client.fetch(.init(url: origin + "/cookies", headers: ["Cookie":"must not send"]), policy: policy) }
    }

    @Test func retryAfterParsesDateWithoutShorteningAndRejectsMalformedValues() {
        let now = Date(timeIntervalSince1970: 784111777) // 1994-11-06 08:49:37 GMT
        #expect(SourceHostHTTPClient.retryDelay(header: "Sun, 06 Nov 1994 08:49:39 GMT", maximumDelay: 3, remaining: 4, now: now) == 2)
        #expect(SourceHostHTTPClient.retryDelay(header: "Sunday, 06-Nov-94 08:49:39 GMT", maximumDelay: 3, remaining: 4, now: now) == 2)
        #expect(SourceHostHTTPClient.retryDelay(header: "Sun Nov 6 08:49:39 1994", maximumDelay: 3, remaining: 4, now: now) == 2)
        for value in ["-1","1.5","invalid","9999999999999999999999999999999999999999"] {
            #expect(SourceHostHTTPClient.retryDelay(header: value, maximumDelay: 2, remaining: 5) == nil)
        }
        #expect(SourceHostHTTPClient.retryDelay(header: "2", maximumDelay: 1, remaining: 5) == nil)
        #expect(SourceHostHTTPClient.retryDelay(header: "2", maximumDelay: 3, remaining: 1) == nil)
    }
}
