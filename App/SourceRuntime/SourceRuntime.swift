import Foundation
import WebKit
#if SWIFT_PACKAGE
import LegadoCore
#endif

struct SourceStateBinding: Sendable {
    let archive: SourceArchive
    let scope: SourceScope
}

@MainActor
final class SourceHostBridge: NSObject, WKScriptMessageHandlerWithReply {
    private struct StateRequest: Decodable {
        let key: String
        let value: SourceJSON?
        let condition: SourceStateCondition
        private enum Keys: String, CodingKey { case key, value, ifRevision }
        init(from decoder: Decoder) throws {
            let data = try decoder.container(keyedBy: Keys.self)
            key = try data.decode(String.self, forKey: .key)
            value = data.contains(.value) ? try data.decode(SourceJSON.self, forKey: .value) : nil
            if !data.contains(.ifRevision) { condition = .any }
            else if try data.decodeNil(forKey: .ifRevision) { condition = .missing }
            else { condition = .revision(try data.decode(String.self, forKey: .ifRevision)) }
        }
    }
    private struct Message: Decodable {
        let session: String
        let operation: String
        let id: String
        let method: String
        let request: SourceHTTPRequest?
        let state: StateRequest?
    }
    let session = UUID().uuidString
    let operation = UUID().uuidString
    weak var page: SourceWebPage?
    private let profile: SourceProfile
    private let policy: SourceHTTPPolicy
    private let networkBudget: SourceHTTPRequestBudget
    private var operationDeadline: ContinuousClock.Instant?
    private let stateBinding: SourceStateBinding?
    private let priority: SourceWorkScheduler.Priority
    private let stateGate: SourceCommitGate
    private let credentials: SourceCredentialSession?
    private var stateCount = 0
    private var active = true
    private var ready = false
    private var count = 0
    private var seen = Set<String>()
    private var tasks: [String: Task<Void, Never>] = [:]
    private var replies: [String: @MainActor @Sendable (Any?, String?) -> Void] = [:]

    init(snapshot: SourceSnapshot, profile: SourceProfile, allowLoopbackHTTP: Bool, timeoutMs: Int, state: SourceStateBinding? = nil, priority: SourceWorkScheduler.Priority = .reading, credentials: SourceCredentialSession? = nil) {
        self.profile = profile
        networkBudget = SourceHTTPRequestBudget(maximumRequests: profile.limits.operationHTTPRequests)
        stateBinding = state
        self.credentials = credentials
        stateGate = SourceCommitGate(parent: credentials?.commitGate)
        self.priority = priority
        policy = SourceHTTPPolicy(origins: Set(snapshot.inspection.metadata.origins), allowLoopbackHTTP: allowLoopbackHTTP,
                                  maximumBytes: profile.limits.httpResponseBytes,
                                  maximumRedirects: profile.experimentalRuntimeBudgets.maxRedirects,
                                  timeout: Double(timeoutMs) / 1000)
    }

    func finish() {
        guard active else { return }
        active = false
        stateGate.invalidate()
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        let pending = replies.values
        replies.removeAll()
        for reply in pending { reply(Self.errorJSON(.init(code: "CANCELLED", message: "Operation ended")), nil) }
    }

    private static func errorJSON(_ error: SourceFailure) -> String {
        struct Envelope: Encodable { let error: SourceFailure }
        return String(decoding: try! JSONEncoder().encode(Envelope(error: error)), as: UTF8.self)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        do {
            guard active, message.webView === page?.webView, message.frameInfo.isMainFrame,
                  let text = message.body as? String, text.utf8.count <= 3_000_000 else {
                throw SourceFailure(code: "INVALID_INPUT", message: "Inactive, oversized or foreign bridge message")
            }
            try stateGate.check()
            let data = Data(text.utf8)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys).isSubset(of: ["session", "operation", "id", "method", "request", "state"]) else {
                throw SourceFailure(code: "INVALID_INPUT", message: "Unknown bridge fields")
            }
            let envelope = try JSONDecoder().decode(Message.self, from: data)
            guard envelope.session == session, envelope.operation == operation, !envelope.id.isEmpty, envelope.id.utf8.count <= 128 else {
                throw SourceFailure(code: "INVALID_INPUT", message: "Bridge identity mismatch")
            }
            if envelope.method == "ready" {
                guard !ready, envelope.id == "ready", envelope.request == nil, envelope.state == nil else {
                    throw SourceFailure(code: "INVALID_INPUT", message: "Invalid or repeated module initialization")
                }
                ready = true
                operationDeadline = ContinuousClock.now.advanced(by: .seconds(policy.timeout))
                page?.resetDeadline(milliseconds: Int(policy.timeout * 1000))
                replyHandler("{}", nil)
                return
            }
            guard ready else { throw SourceFailure(code: "INVALID_INPUT", message: "Module not initialized") }
            if envelope.method == "abortHTTP" {
                guard envelope.request == nil, envelope.state == nil, seen.contains(envelope.id) else {
                    throw SourceFailure(code: "INVALID_INPUT", message: "Unknown cancellation target")
                }
                tasks[envelope.id]?.cancel()
                replyHandler("{}", nil)
                return
            }
            if ["storageGet", "storageSet", "storageRemove"].contains(envelope.method) {
                guard let binding = stateBinding else { throw SourceFailure(code: "UNSUPPORTED", message: "No installed source state scope") }
                guard !seen.contains(envelope.id), envelope.request == nil, let state = envelope.state,
                      let fields = object["state"] as? [String: Any],
                      Set(fields.keys).isSubset(of: ["key", "value", "ifRevision"]) else {
                    throw SourceFailure(code: "INVALID_INPUT", message: "Invalid state bridge data")
                }
                guard stateCount < 128 else { throw SourceFailure(code: "RESOURCE_LIMIT", message: "Operation state request budget exceeded") }
                guard (envelope.method == "storageSet") == fields.keys.contains("value"),
                      envelope.method != "storageGet" || !fields.keys.contains("ifRevision") else {
                    throw SourceFailure(code: "INVALID_INPUT", message: "Unexpected state fields")
                }
                stateCount += 1
                seen.insert(envelope.id)
                replies[envelope.id] = replyHandler
                let stateGate = self.stateGate
                tasks[envelope.id] = Task { [weak self] in
                    let response: String
                    do {
                        try Task.checkCancellation()
                        try stateGate.check()
                        switch envelope.method {
                        case "storageGet":
                            let entry = try await binding.archive.state(scope: binding.scope, key: state.key)
                            try stateGate.check()
                            response = String(decoding: try SourceCoding.encode(entry), as: UTF8.self)
                        case "storageSet":
                            guard let value = state.value else { throw SourceFailure(code: "INVALID_INPUT", message: "Missing state value") }
                            let entry = try await binding.archive.setState(scope: binding.scope, key: state.key, value: value, condition: state.condition, gate: stateGate)
                            response = String(decoding: try SourceCoding.encode(entry), as: UTF8.self)
                        default:
                            try await binding.archive.removeState(scope: binding.scope, key: state.key, condition: state.condition, gate: stateGate)
                            response = "null"
                        }
                    } catch let error as SourceDomainError {
                        response = Self.errorJSON(.init(code: error.code.rawValue, message: error.message))
                    } catch is CancellationError {
                        response = Self.errorJSON(.init(code: "CANCELLED", message: "State operation cancelled"))
                    } catch { response = Self.errorJSON(error as? SourceFailure ?? .init(code: "HOST_ERROR", message: "State operation failed")) }
                    guard let self, self.active, let reply = self.replies.removeValue(forKey: envelope.id) else { return }
                    self.tasks.removeValue(forKey: envelope.id)
                    reply(response, nil)
                }
                return
            }
            guard envelope.method == "http", let request = envelope.request, !seen.contains(envelope.id), envelope.state == nil else {
                throw SourceFailure(code: "INVALID_INPUT", message: "Unknown or duplicate bridge request")
            }
            guard count < profile.limits.operationHTTPRequests else {
                throw SourceFailure(code: "RESOURCE_LIMIT", message: "Operation request budget exceeded")
            }
            guard let requestObject = object["request"] as? [String: Any],
                  Set(requestObject.keys).isSubset(of: ["url", "method", "headers", "body", "redirect"]) else {
                throw SourceFailure(code: "INVALID_INPUT", message: "Unknown HTTP bridge fields")
            }
            count += 1
            seen.insert(envelope.id)
            replies[envelope.id] = replyHandler
            tasks[envelope.id] = Task { [weak self, policy, priority, networkBudget, credentials, deadline = operationDeadline] in
                let response: String
                do { response = String(decoding: try JSONEncoder().encode(await SourceHTTP.fetch(request, policy: policy, priority: priority, deadline: deadline, budget: networkBudget, credentials: credentials)), as: UTF8.self) }
                catch { response = Self.errorJSON(error as? SourceFailure ?? .init(code: "NETWORK", message: "HTTP request failed")) }
                guard let self, self.active, let reply = self.replies.removeValue(forKey: envelope.id) else { return }
                self.tasks.removeValue(forKey: envelope.id)
                reply(response, nil)
            }
        } catch {
            replyHandler(Self.errorJSON(error as? SourceFailure ?? .init(code: "INVALID_INPUT", message: "Invalid bridge data")), nil)
        }
    }
}

@MainActor
final class SourceRuntime {
    private let inspector: SourceInspector
    private let profile: SourceProfile
    init() throws { inspector = try SourceInspector(); profile = try .load() }

    func run(_ operation: SourceOperation, inputJSON: String, snapshot: SourceSnapshot,
             allowLoopbackHTTP: Bool = false, timeoutMs: Int? = nil,
             configuration: SourceJSON? = nil, state: SourceStateBinding? = nil, priority: SourceWorkScheduler.Priority = .reading,
             credentials: SourceCredentialSession? = nil) async throws -> String {
        try credentials?.commitGate.check()
        guard snapshot.inspection.unsupportedRequirements.isEmpty,
              snapshot.inspection.operations.contains(operation.rawValue) else {
            throw SourceFailure(code: "UNSUPPORTED", message: "Required source capability is unavailable")
        }
        try await inspector.validate(operation.inputContract, json: inputJSON)
        try Task.checkCancellation()
        let budget = min(max(timeoutMs ?? profile.experimentalRuntimeBudgets.operationMs, 1), profile.experimentalRuntimeBudgets.operationMs)
        let bridge = SourceHostBridge(snapshot: snapshot, profile: profile, allowLoopbackHTTP: allowLoopbackHTTP, timeoutMs: budget, state: state, priority: priority, credentials: credentials)
        let page = try SourceWebPage(script: SourceAssets.script("SourceRunner"), bridge: bridge)
        bridge.page = page
        page.onClose = { [weak bridge] in bridge?.finish() }
        defer { bridge.finish() }
        let configJSON = String(decoding: try SourceCoding.encode(snapshot.configuration(overrides: configuration)), as: UTF8.self)
        let raw = try await page.perform("return await SourceRunner.run(source, operation, inputJSON, session, operationID, configJSON);",
                                         arguments: ["source": snapshot.source, "operation": operation.rawValue,
                                                     "inputJSON": inputJSON, "configJSON": configJSON, "session": bridge.session, "operationID": bridge.operation],
                                         timeoutMs: profile.experimentalRuntimeBudgets.moduleInitializationMs)
        try credentials?.commitGate.check()
        // The envelope escapes the serialized result. Bound both wire and decoded sizes.
        guard raw.utf8.count <= profile.limits.outputBytes * 2 + 4096 else {
            throw SourceFailure(code: "RESOURCE_LIMIT", message: "Output byte budget exceeded")
        }
        struct ResultEnvelope: Decodable { let json: String?; let error: SourceFailure? }
        let result = try JSONDecoder().decode(ResultEnvelope.self, from: Data(raw.utf8))
        if let error = result.error {
            // Author exceptions are data. Do not allow arbitrary codes or retry budgets to enter native scheduling.
            let codes: Set<String> = ["INVALID_INPUT", "INVALID_RESULT", "INVALID_DATA", "NETWORK", "HTTP",
                "RATE_LIMITED", "AUTH_REQUIRED", "PARSE", "UNSUPPORTED", "TIMEOUT", "CANCELLED", "RESOURCE_LIMIT",
                "PERMISSION_DENIED", "STORAGE_CONFLICT", "STALE_SNAPSHOT", "SCRIPT_ERROR"]
            guard codes.contains(error.code), !error.message.isEmpty, error.message.utf16.count <= 2048,
                  error.retryAfterMs.map({ (0...86_400_000).contains($0) }) ?? true else {
                throw SourceFailure(code: "INVALID_DATA", message: "Invalid source error envelope")
            }
            throw error
        }
        guard let json = result.json else { throw SourceFailure(code: "INVALID_DATA", message: "Missing operation result") }
        // The author page cannot change this independent page's validator or schema.
        try Task.checkCancellation()
        try await inspector.validate(operation.outputContract, json: json)
        try Task.checkCancellation()
        return json
    }
}

/// P2 adapter: immutable host identity and typed wire results; no WebKit types escape to the library.
struct WebKitSourceProvider: SourceProvider {
    let descriptor: SourceProviderDescriptor
    private let snapshot: SourceSnapshot
    private let configuration: SourceJSON
    private let state: SourceStateBinding
    private let allowLoopbackHTTP: Bool
    private let credentials: SourceCredentialSession?
    private static let scheduler = SourceWorkScheduler(globalLimit: 2, perOriginLimit: 1)
    private var priorityOverride: SourceWorkScheduler.Priority?

    init(snapshot: SourceSnapshot, installation: SourceInstallation, accountID: String = "guest", configuration: SourceJSON? = nil,
         archive: SourceArchive, allowLoopbackHTTP: Bool = false, credentials: SourceCredentialSession? = nil) throws {
        guard snapshot.sha256 == installation.digest else { throw SourceFailure(code: "INVALID_INPUT", message: "Installed source digest mismatch") }
        self.snapshot = snapshot
        self.configuration = try snapshot.configuration(overrides: configuration)
        let scope = try SourceScope(installationID: installation.id, accountID: accountID)
        guard credentials == nil || (credentials?.scope == scope && credentials?.allowedOrigins == Set(snapshot.inspection.metadata.origins)) else {
            throw SourceFailure(code: "INVALID_INPUT", message: "Credential scope does not match the source snapshot")
        }
        self.credentials = credentials
        descriptor = SourceProviderDescriptor(identity: try .init(scope: scope, sourceDigest: snapshot.sha256, configuration: self.configuration, credentialRevision: credentials?.revision),
                                              name: snapshot.inspection.metadata.name, supportsSearch: snapshot.inspection.operations.contains("search"), commitGate: credentials?.commitGate)
        state = SourceStateBinding(archive: archive, scope: scope)
        self.allowLoopbackHTTP = allowLoopbackHTTP
    }
    func search(_ input: SourceWire.SearchInput) async throws -> SourceWire.SearchPage { try await invoke(.search, input: input) }
    func book(_ input: SourceWire.BookInput) async throws -> SourceWire.BookDetails { try await invoke(.book, input: input) }
    func chapters(_ input: SourceWire.ChaptersInput) async throws -> SourceWire.ChapterPage { try await invoke(.chapters, input: input) }
    func content(_ input: SourceWire.ContentInput) async throws -> SourceWire.ChapterContent { try await invoke(.content, input: input) }

    func prioritized(_ priority: SourceWorkScheduler.Priority) -> Self {
        var provider = self
        provider.priorityOverride = priority
        return provider
    }

    private func invoke<Input: Encodable & Sendable, Output: Decodable & Sendable>(_ operation: SourceOperation, input: Input) async throws -> Output {
        try credentials?.commitGate.check()
        let inputJSON = String(decoding: try SourceCoding.encode(input), as: UTF8.self)
        let priority = priorityOverride ?? (operation == .content ? .reading : .search)
        let raw = try await Self.scheduler.withPermit(origin: descriptor.identity.scope.installationID.uuidString,
            priority: priority, deadline: Date().addingTimeInterval(30)) {
            try await execute(operation, inputJSON: inputJSON, priority: priority)
        }
        try credentials?.commitGate.check()
        return try SourceCoding.decode(Output.self, from: Data(raw.utf8))
    }
    @MainActor private func execute(_ operation: SourceOperation, inputJSON: String, priority: SourceWorkScheduler.Priority) async throws -> String {
        try await SourceRuntime().run(operation, inputJSON: inputJSON, snapshot: snapshot, allowLoopbackHTTP: allowLoopbackHTTP,
                                      configuration: configuration, state: state, priority: priority, credentials: credentials)
    }
}
