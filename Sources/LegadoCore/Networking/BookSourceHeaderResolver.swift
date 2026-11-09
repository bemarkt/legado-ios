import Foundation

public struct BookSourceHeaderResolver: Sendable {
    public init() {}

    public func resolve(_ source: BookSource, includeLoginHeader: Bool = true, environment: JavaScriptHostEnvironment? = nil) throws -> [String: String] {
        var headers: [String: String] = [:]
        if let raw = source.header?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            let json: String
            if raw.lowercased().hasPrefix("@js:") {
                json = try JavaScriptRuleEvaluator().evaluate(
                    script: String(raw.dropFirst(4)),
                    result: .null,
                    executionContext: .init(source: source, environment: environment)
                ).value.stringValue
            } else if raw.lowercased().hasPrefix("<js>"), raw.lowercased().hasSuffix("</js>") {
                json = try JavaScriptRuleEvaluator().evaluate(
                    script: String(raw.dropFirst(4).dropLast(5)),
                    result: .null,
                    executionContext: .init(source: source, environment: environment)
                ).value.stringValue
            } else {
                json = raw
            }
            if case .object(let object) = try LegadoURLBuilder.decodeLenientJSON(json) {
                headers = object.mapValues(\.stringValue)
            }
        }
        if includeLoginHeader {
            headers.merge(try (environment ?? .legacy).sourceState.loginHeaders(sourceID: source.id)) { _, login in login }
        }
        return headers
    }
}

public extension BookSourceHeaderResolver {
    /// 走 WebView 的请求实际使用的 User-Agent。
    ///
    /// WebKit 只认 `WKWebView.customUserAgent`：`URLRequest` 上设置的 `User-Agent`
    /// 会被静默丢弃，请求最终发出的是系统默认串（`... Mobile/15E148`）。
    /// 因此书源 header 与「设置 - 网络与缓存」里的 UA 在 WebView 链路上
    /// 都必须经过这里取值，只往 request 上塞 header 等于没设。
    func webViewUserAgent(_ prepared: PreparedRequest) -> String? {
        guard !prepared.suppressesUserAgent else { return nil }
        return Self.userAgent(
            in: prepared.headers,
            global: ApplicationSettingsStore.shared.settings.effectiveUserAgent
        )
    }

    /// 只拿到书源（没有 `PreparedRequest`）时用这个，比如 RSS 阅读器的 WebView。
    func webViewUserAgent(for source: BookSource) -> String? {
        Self.userAgent(
            in: (try? resolve(source)) ?? [:],
            global: ApplicationSettingsStore.shared.settings.effectiveUserAgent
        )
    }

    /// `"null"` 是书源里「禁用默认 UA」的显式写法，不能被当成一个真实 UA 发出去；
    /// 空值或缺席才回落到全局设置。
    static func userAgent(in headers: [String: String], global: String) -> String? {
        let explicit = headers
            .first { $0.key.caseInsensitiveCompare("User-Agent") == .orderedSame }?
            .value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let explicit, explicit.lowercased() == "null" { return nil }
        if let explicit, !explicit.isEmpty { return explicit }
        let fallback = global.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? nil : fallback
    }
}
