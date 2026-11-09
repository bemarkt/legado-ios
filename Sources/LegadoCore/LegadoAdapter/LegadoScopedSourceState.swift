import Foundation

/// Synchronous legacy state is bridged to the scoped archive; login fields stay in the credential vault.
/// Constructed once per operation. It cannot address another source by changing a script argument.
public struct LegadoScopedSourceState: JavaScriptSourceState {
    private let sourceID: String
    private let identity: SourceExecutionIdentity
    private let archive: SourceArchive
    private let credentials: SourceCredentialSession?
    private let control: JavaScriptExecutionControl
    public init(sourceID: String, identity: SourceExecutionIdentity, archive: SourceArchive,
                credentials: SourceCredentialSession?, control: JavaScriptExecutionControl) throws {
        if let credentials {
            guard credentials.scope == identity.scope, credentials.revision == identity.credentialRevision,
                  control.commitGate.inherits(credentials.commitGate) else {
                throw SourceDomainError(.invalidInput, "Compatibility credentials do not match the operation scope")
            }
        } else if identity.scope.accountID != "guest" || identity.credentialRevision != nil {
            throw SourceDomainError(.invalidInput, "Named account needs a matching credential session")
        }
        self.sourceID = sourceID; self.identity = identity; self.archive = archive
        self.credentials = credentials; self.control = control
    }
    private func validate(_ sourceID: String, _ key: String) throws {
        try control.check()
        guard sourceID == self.sourceID, !key.isEmpty, key.utf8.count <= 512, !key.contains("\0") else {
            throw SourceDomainError(.invalidInput, "Invalid or foreign compatibility state key")
        }
    }
    private func storageKey(_ key: String) -> String { "legado.source." + SourceCoding.digest(Data(key.utf8)) }
    public func get(sourceID: String, key: String) throws -> String {
        try validate(sourceID, key)
        if ["loginInfo", "loginHeader"].contains(key) {
            guard let credentials else { return "" }
            return try LegadoAsyncBridge.wait(control: control) { try await credentials.legacyValue(key: key) }
        }
        let key = storageKey(key)
        return try LegadoAsyncBridge.wait(control: control) {
            guard let entry = try await archive.state(scope: identity.scope, key: key, expectedIdentity: identity) else { return "" }
            guard case .string(let value) = entry.value else { throw SourceDomainError(.invalidData, "Invalid saved compatibility state") }
            return value
        }
    }
    public func put(sourceID: String, key: String, value: String) throws {
        try validate(sourceID, key)
        if ["loginInfo", "loginHeader"].contains(key) {
            guard let credentials else {
                if value.isEmpty { return }
                throw SourceDomainError(.unavailable, "请先创建独立账号再保存登录状态。")
            }
            return try LegadoAsyncBridge.wait(control: control) {
                try await credentials.setLegacyValue(value, key: key, gate: control.commitGate)
            }
        }
        let key = storageKey(key)
        try LegadoAsyncBridge.wait(control: control) {
            _ = try await archive.setState(scope: identity.scope, key: key, value: .string(value),
                                          gate: control.commitGate, expectedIdentity: identity)
        }
    }
    public func loginHeaders(sourceID: String) throws -> [String: String] {
        let text = try get(sourceID: sourceID, key: "loginHeader")
        guard !text.isEmpty else { return [:] }
        guard let headers = try? SourceCoding.decode([String: String].self, from: Data(text.utf8)) else {
            throw SourceDomainError(.invalidData, "Invalid saved login headers")
        }
        return headers
    }
}
