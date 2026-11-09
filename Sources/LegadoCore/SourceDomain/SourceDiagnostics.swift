import Foundation

/// Measured after authorization is attached, never inferred from the saved cookie count.
/// Contains no cookie names/values, URLs, query parameters or raw request headers.
public struct SourceHTTPExchangeSummary: Codable, Sendable, Equatable {
    public let originDigest: String
    public let userAgentDigest: String?
    public let status: Int
    public let responseBytes: Int
    public let sentCookieCount: Int
    public let receivedCookieCount: Int
    public let deletedCookieCount: Int
    public let hasSetCookieHeader: Bool
    init(request: URLRequest, status: Int, responseBytes: Int, cookies: [SourceCredentialCookie], hasSetCookieHeader: Bool) {
        originDigest = SourceCoding.digest(Data((request.url.flatMap(SourceHostHTTPPolicy.origin) ?? "").utf8))
        userAgentDigest = request.value(forHTTPHeaderField: "User-Agent").map { SourceCoding.digest(Data($0.utf8)) }
        self.status = status; self.responseBytes = responseBytes
        sentCookieCount = (request.value(forHTTPHeaderField: "Cookie") ?? "").split(separator: ";").filter { $0.contains("=") }.count
        receivedCookieCount = cookies.count
        deletedCookieCount = cookies.filter { $0.expiresAt.map { $0 <= Date() } ?? false }.count
        self.hasSetCookieHeader = hasSetCookieHeader
    }
}

/// Host-generated extraction facts, without page text, addresses, headers or credentials.
public struct SourceExtractionContext: Codable, Sendable, Equatable {
    public enum Field: String, Codable, Sendable { case catalog = "ruleToc.chapterList", content = "ruleContent.content" }
    public let field: Field
    public let httpStatus: Int?
    public let responseBytes: Int?
    public let responseID: UUID?
    public init(field: Field, httpStatus: Int?, responseBytes: Int?, responseID: UUID? = nil) {
        self.field = field
        self.httpStatus = httpStatus.flatMap { (100...599).contains($0) ? $0 : nil }
        self.responseBytes = responseBytes.map { min(8_388_608, max(0, $0)) }
        self.responseID = responseID
    }
}

public struct SourceExtractionFailure: Error, Sendable, LocalizedError {
    public let context: SourceExtractionContext
    public let localResponse: SourceLocalResponse?
    public init(field: SourceExtractionContext.Field, httpStatus: Int?, responseBytes: Int?, responseID: UUID? = nil, localResponse: SourceLocalResponse? = nil) {
        self.localResponse = localResponse
        context = .init(field: field, httpStatus: httpStatus, responseBytes: responseBytes, responseID: responseID)
    }
    public var issue: SourceIssue { .init(code: context.field == .catalog ? "EMPTY_CATALOG" : "EMPTY_CONTENT", extraction: context) }
    public var errorDescription: String? { issue.message }
}

/// Deliberately not Codable: website text is available only in the local inspector.
/// No request/response headers are retained except Content-Type. The body may contain private data.
public struct SourceLocalResponse: Sendable {
    public static let maximumTextBytes = 65_536
    public let finalURL: String?
    public let contentType: String?
    public let body: String
    public let truncated: Bool
    public let httpExchanges: [SourceHTTPExchangeSummary]
    public init(response: HTTPResponse) {
        var components = URLComponents(url: response.finalURL, resolvingAgainstBaseURL: false)
        components?.user = nil; components?.password = nil; components?.fragment = nil
        let address = components?.url?.absoluteString
        finalURL = address.flatMap { $0.utf8.count <= 8192 ? $0 : nil }
        contentType = response.headers.first { $0.key.lowercased() == "content-type" }.map { String($0.value.prefix(256)) }
        let bytes = response.decodedText.utf8
        truncated = bytes.count > Self.maximumTextBytes
        // Keep a valid UTF-8 prefix without replacing a cut multibyte character.
        var prefix = Data(bytes.prefix(Self.maximumTextBytes))
        while !prefix.isEmpty && String(data: prefix, encoding: .utf8) == nil { prefix.removeLast() }
        body = String(decoding: prefix, as: UTF8.self)
        httpExchanges = Array(response.httpExchanges.suffix(16))
    }
}

/// UI recovery is determined by a bounded host code, never by matching website error text.
public struct SourceIssue: Codable, Sendable, Equatable {
    public enum Recovery: String, Codable, Sendable { case retry, login, inspectSource, refreshCatalog, settings, none }
    public let code: String
    public let retryAt: Date?
    public let extraction: SourceExtractionContext?
    public init(code: String, retryAfterMs: Int? = nil, now: Date = Date(), extraction: SourceExtractionContext? = nil) {
        let allowed: Set<String> = ["INVALID_INPUT","INVALID_RESULT","INVALID_DATA","NETWORK","HTTP","RATE_LIMITED","AUTH_REQUIRED","PARSE",
            "UNSUPPORTED","TIMEOUT","HOST_TIMEOUT","CANCELLED","RESOURCE_LIMIT","PERMISSION_DENIED","STORAGE_CONFLICT","STALE_SNAPSHOT",
            "SCRIPT_ERROR","CATALOG_CHANGED","NOT_DOWNLOADED","UNAVAILABLE","RUNTIME_TERMINATED","EMPTY_CATALOG","EMPTY_CONTENT"]
        self.code = allowed.contains(code) ? code : "UNKNOWN"
        self.extraction = extraction
        if code == "RATE_LIMITED", let retryAfterMs, (0...86_400_000).contains(retryAfterMs) {
            retryAt = now.addingTimeInterval(Double(retryAfterMs) / 1000)
        } else { retryAt = nil }
    }
    public var recovery: Recovery {
        switch code {
        case "AUTH_REQUIRED": return .login
        case "NETWORK","HTTP","RATE_LIMITED","TIMEOUT","HOST_TIMEOUT","RUNTIME_TERMINATED","UNKNOWN": return .retry
        case "STALE_SNAPSHOT","CATALOG_CHANGED": return .refreshCatalog
        case "RESOURCE_LIMIT","UNAVAILABLE","STORAGE_CONFLICT": return .settings
        case "INVALID_INPUT","INVALID_RESULT","INVALID_DATA","PARSE","UNSUPPORTED","PERMISSION_DENIED","SCRIPT_ERROR","EMPTY_CATALOG","EMPTY_CONTENT": return .inspectSource
        default: return .none
        }
    }
    public var title: String {
        switch recovery {
        case .login: return "需要登录"
        case .refreshCatalog: return "阅读状态已更新"
        case .inspectSource: return code == "EMPTY_CATALOG" ? "未提取到目录" : code == "EMPTY_CONTENT" ? "未提取到正文" : "书源需要检查"
        case .settings: return code == "RESOURCE_LIMIT" ? "达到资源限制" : "本机状态暂不可用"
        case .none: return code == "NOT_DOWNLOADED" ? "没有离线副本" : "操作已取消"
        case .retry:
            if code == "RATE_LIMITED" { return "网站暂时限制请求" }
            if ["TIMEOUT","HOST_TIMEOUT"].contains(code) { return "请求超时" }
            return "暂时无法完成"
        }
    }
    public var message: String {
        switch recovery {
        case .login: return "请打开此书源的网站登录，再重新搜索或刷新目录。"
        case .refreshCatalog: return "账号、书源或目录已经改变，请返回书籍详情刷新目录后重试。已下载正文仍可离线打开。"
        case .inspectSource:
            if ["EMPTY_CATALOG", "EMPTY_CONTENT"].contains(code) {
                return "网站返回的页面没有匹配内容，可能需要网站验证、登录或更新书源规则。可先打开网站完成验证，再重试；已有目录和下载会保留。"
            }
            return "请检查书源版本、访问范围或返回的数据。可以在书源设置中审阅源码，并在诊断记录中查看错误类别。"
        case .settings: return code == "RESOURCE_LIMIT" ? "请求、图片或存储达到上限。可在缓存与下载中查看容量，或检查书源返回的数据。" : "请解锁设备后重试；若刚修改过账号或书源，重新打开页面再保存。"
        case .none: return code == "NOT_DOWNLOADED" ? "这本书尚未下载这一章，请联网获取后再尝试离线阅读。" : "已完成的内容会保留，可以重新开始操作。"
        case .retry: return code == "RATE_LIMITED" ? "请等待网站允许后再重试，避免连续刷新。" : "请检查网络后重试；已有离线副本仍可阅读。"
        }
    }
    public func canRetry(at now: Date = Date()) -> Bool { retryAt.map { now >= $0 } ?? true }
}

public enum SourceDiagnosticOperation: String, Codable, Sendable { case search, book, chapters, content, cover }
public struct SourceDiagnosticRecord: Codable, Sendable, Identifiable {
    public let id: UUID
    public let timestamp: Date
    public let operation: SourceDiagnosticOperation
    public let sourceDigest: String
    public let scopeDigest: String
    public let configurationDigest: String
    public let code: String
    public let elapsedMilliseconds: Int
    public let line: Int?
    public let column: Int?
    public let extraction: SourceExtractionContext?
    public let credentialRevisionDigest: String?
    public let cookieJarEnabled: Bool?
    public let httpExchanges: [SourceHTTPExchangeSummary]?
}

/// Exportable summaries contain no website data. A separate, bounded local response cache is never exported.
public actor SourceDiagnostics {
    public static let shared = SourceDiagnostics()
    private let capacity: Int
    private var values: [SourceDiagnosticRecord] = []
    private var responses: [UUID: (created: Date, value: SourceLocalResponse)] = [:]
    public init(capacity: Int = 128) { self.capacity = min(128, max(1, capacity)) }
    public func record(id: UUID, operation: SourceDiagnosticOperation, identity: SourceExecutionIdentity,
                       issue: SourceIssue?, elapsedMilliseconds: Int, line: Int? = nil, column: Int? = nil,
                       localResponse: SourceLocalResponse? = nil, cookieJarEnabled: Bool? = nil,
                       httpExchanges: [SourceHTTPExchangeSummary] = [], now: Date = Date()) {
        guard let encoded = try? SourceCoding.encode(identity.scope) else { return }
        values.append(.init(id: id, timestamp: now, operation: operation, sourceDigest: identity.sourceDigest,
            scopeDigest: SourceCoding.digest(encoded), configurationDigest: identity.configurationDigest,
            code: issue?.code ?? "OK", elapsedMilliseconds: max(0, min(300_000, elapsedMilliseconds)),
            line: line.flatMap { (1...2_097_152).contains($0) ? $0 : nil }, column: column.flatMap { (1...2_097_152).contains($0) ? $0 : nil }, extraction: issue?.extraction,
            credentialRevisionDigest: identity.credentialRevision.map { SourceCoding.digest(Data($0.utf8)) }, cookieJarEnabled: cookieJarEnabled,
            httpExchanges: httpExchanges.isEmpty ? nil : Array(httpExchanges.suffix(16))))
        if values.count > capacity { values.removeFirst(values.count - capacity) }
        if let localResponse, issue?.extraction?.responseID == id { responses[id] = (now, localResponse) }
        pruneResponses(now: now)
    }
    private func pruneResponses(now: Date) {
        let retained = Set(values.suffix(128).map(\.id))
        responses = responses.filter { retained.contains($0.key) && now.timeIntervalSince($0.value.created) < 900 }
        let newest = Set(responses.sorted { $0.value.created > $1.value.created }.prefix(8).map(\.key))
        responses = responses.filter { newest.contains($0.key) }
    }
    public func localResponse(id: UUID, sourceDigest: String, now: Date = Date()) -> SourceLocalResponse? {
        pruneResponses(now: now)
        guard values.contains(where: { $0.id == id && $0.sourceDigest == sourceDigest }) else { return nil }
        return responses[id]?.value
    }
    public func records() -> [SourceDiagnosticRecord] { Array(values.reversed()) }
    public func clear() { values.removeAll(); responses.removeAll() }
    public func export() throws -> Data {
        struct Report: Encodable { let version = 1; let operations: [SourceDiagnosticRecord] }
        let data = try SourceCoding.encode(Report(operations: values))
        guard data.count <= 1_048_576 else { throw SourceDomainError(.resourceLimit, "诊断报告超过容量限制。") }
        return data
    }
}

/// A bounded local excerpt must match the diagnostic's immutable source digest.
/// Lines and columns are 1-based UTF-16, matching JavaScript engine diagnostics.
public struct SourceCodeExcerpt: Sendable, Equatable {
    public struct Line: Sendable, Equatable, Identifiable {
        public let number: Int
        public let text: String
        public let selected: Bool
        public var id: Int { number }
    }
    public let lines: [Line]
    public let line: Int
    public let column: Int
    public init(source: String, expectedDigest: String, line: Int, column: Int = 1) throws {
        guard source.utf8.count <= 2_097_152, SourceCoding.digest(Data(source.utf8)) == expectedDigest else {
            throw SourceDomainError(.stale, "源码与这条诊断的版本不一致。")
        }
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{2028}", with: "\n").replacingOccurrences(of: "\u{2029}", with: "\n")
        let values = normalized.components(separatedBy: "\n")
        guard line >= 1, line <= values.count, column >= 1, column <= values[line - 1].utf16.count + 1 else {
            throw SourceDomainError(.invalidInput, "源码位置已超出文件范围。")
        }
        self.line = line; self.column = column
        lines = (max(1, line - 2)...min(values.count, line + 2)).map { number in
            let text = values[number - 1]
            return Line(number: number, text: String(text.prefix(500)) + (text.count > 500 ? "…" : ""), selected: number == line)
        }
    }
}
