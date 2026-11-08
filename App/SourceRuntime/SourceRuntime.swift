import Foundation
import WebKit

@MainActor
private final class SourceHostBridge: NSObject, WKScriptMessageHandlerWithReply {
    private struct Message: Decodable {
        let session: String
        let operation: String
        let id: String
        let method: String
        let request: SourceHTTPRequest?
    }
    let session = UUID().uuidString
    let operation = UUID().uuidString
    weak var page: SourceWebPage?
    private let profile: SourceProfile
    private let policy: SourceHTTPPolicy
    private var active = true
    private var ready = false
    private var count = 0
    private var seen = Set<String>()
    private var tasks: [String: Task<Void, Never>] = [:]
    private var replies: [String: (Any?, String?) -> Void] = [:]

    init(snapshot: SourceSnapshot, profile: SourceProfile, allowLoopbackHTTP: Bool, timeoutMs: Int) {
        self.profile = profile
        policy = SourceHTTPPolicy(origins: Set(snapshot.inspection.metadata.origins), allowLoopbackHTTP: allowLoopbackHTTP,
                                  maximumBytes: profile.limits.httpResponseBytes,
                                  maximumRedirects: profile.experimentalRuntimeBudgets.maxRedirects,
                                  timeout: Double(timeoutMs) / 1000)
    }

    func finish() {
        guard active else { return }
        active = false
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
                               replyHandler: @escaping (Any?, String?) -> Void) {
        do {
            guard active, message.webView === page?.webView, message.frameInfo.isMainFrame,
                  let text = message.body as? String, text.utf8.count <= 3_000_000 else {
                throw SourceFailure(code: "INVALID_INPUT", message: "Inactive, oversized or foreign bridge message")
            }
            let data = Data(text.utf8)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys).isSubset(of: ["session", "operation", "id", "method", "request"]) else {
                throw SourceFailure(code: "INVALID_INPUT", message: "Unknown bridge fields")
            }
            let envelope = try JSONDecoder().decode(Message.self, from: data)
            guard envelope.session == session, envelope.operation == operation, envelope.id.utf8.count <= 128 else {
                throw SourceFailure(code: "INVALID_INPUT", message: "Bridge identity mismatch")
            }
            if envelope.method == "ready" {
                guard !ready else { throw SourceFailure(code: "INVALID_INPUT", message: "Module already initialized") }
                ready = true
                page?.resetDeadline(milliseconds: Int(policy.timeout * 1000))
                replyHandler("{}", nil)
                return
            }
            guard ready else { throw SourceFailure(code: "INVALID_INPUT", message: "Module not initialized") }
            if envelope.method == "abortHTTP" {
                tasks[envelope.id]?.cancel()
                replyHandler("{}", nil)
                return
            }
            guard envelope.method == "http", let request = envelope.request, !seen.contains(envelope.id) else {
                throw SourceFailure(code: "INVALID_INPUT", message: "Unknown or duplicate bridge request")
            }
            guard count < profile.limits.operationHTTPRequests else {
                throw SourceFailure(code: "RESOURCE_LIMIT", message: "Operation request budget exceeded")
            }
            count += 1
            seen.insert(envelope.id)
            replies[envelope.id] = replyHandler
            tasks[envelope.id] = Task { [weak self, policy] in
                let response: String
                do { response = String(decoding: try JSONEncoder().encode(await SourceHTTP.fetch(request, policy: policy)), as: UTF8.self) }
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
             allowLoopbackHTTP: Bool = false, timeoutMs: Int? = nil) async throws -> String {
        guard snapshot.inspection.unsupportedRequirements.isEmpty,
              snapshot.inspection.operations.contains(operation.rawValue) else {
            throw SourceFailure(code: "UNSUPPORTED", message: "Required source capability is unavailable")
        }
        try await inspector.validate(operation.inputContract, json: inputJSON)
        try Task.checkCancellation()
        let budget = min(max(timeoutMs ?? profile.experimentalRuntimeBudgets.operationMs, 1), profile.experimentalRuntimeBudgets.operationMs)
        let bridge = SourceHostBridge(snapshot: snapshot, profile: profile, allowLoopbackHTTP: allowLoopbackHTTP, timeoutMs: budget)
        let page = try SourceWebPage(script: SourceAssets.script("SourceRunner"), bridge: bridge)
        bridge.page = page
        page.onClose = { [weak bridge] in bridge?.finish() }
        defer { bridge.finish() }
        let defaults = snapshot.inspection.metadata.settings?.mapValues(\.default) ?? [:]
        let configJSON = String(decoding: try JSONEncoder().encode(defaults), as: UTF8.self)
        let raw = try await page.perform("return await SourceRunner.run(source, operation, inputJSON, session, operationID, configJSON);",
                                         arguments: ["source": snapshot.source, "operation": operation.rawValue,
                                                     "inputJSON": inputJSON, "configJSON": configJSON, "session": bridge.session, "operationID": bridge.operation],
                                         timeoutMs: profile.experimentalRuntimeBudgets.moduleInitializationMs)
        guard raw.utf8.count <= profile.limits.outputBytes else {
            throw SourceFailure(code: "RESOURCE_LIMIT", message: "Output byte budget exceeded")
        }
        struct ResultEnvelope: Decodable { let json: String?; let error: SourceFailure? }
        let result = try JSONDecoder().decode(ResultEnvelope.self, from: Data(raw.utf8))
        if let error = result.error { throw error }
        guard let json = result.json else { throw SourceFailure(code: "INVALID_DATA", message: "Missing operation result") }
        // The author page cannot change this independent page's validator or schema.
        try Task.checkCancellation()
        try await inspector.validate(operation.outputContract, json: json)
        try Task.checkCancellation()
        return json
    }
}
