import Foundation

/// UI recovery is determined by a bounded host code, never by matching website error text.
public struct SourceIssue: Codable, Sendable, Equatable {
    public enum Recovery: String, Codable, Sendable { case retry, login, inspectSource, refreshCatalog, settings, none }
    public let code: String
    public let retryAt: Date?
    public init(code: String, retryAfterMs: Int? = nil, now: Date = Date()) {
        let allowed: Set<String> = ["INVALID_INPUT","INVALID_RESULT","INVALID_DATA","NETWORK","HTTP","RATE_LIMITED","AUTH_REQUIRED","PARSE",
            "UNSUPPORTED","TIMEOUT","HOST_TIMEOUT","CANCELLED","RESOURCE_LIMIT","PERMISSION_DENIED","STORAGE_CONFLICT","STALE_SNAPSHOT",
            "SCRIPT_ERROR","CATALOG_CHANGED","NOT_DOWNLOADED","UNAVAILABLE","RUNTIME_TERMINATED"]
        self.code = allowed.contains(code) ? code : "UNKNOWN"
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
        case "INVALID_INPUT","INVALID_RESULT","INVALID_DATA","PARSE","UNSUPPORTED","PERMISSION_DENIED","SCRIPT_ERROR": return .inspectSource
        default: return .none
        }
    }
    public var title: String {
        switch recovery {
        case .login: return "需要登录"
        case .refreshCatalog: return "阅读状态已更新"
        case .inspectSource: return "书源需要检查"
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
        case .login: return "请在此书源的账号设置中登录，再重新搜索或刷新目录。"
        case .refreshCatalog: return "账号、书源或目录已经改变，请返回书籍详情刷新目录后重试。已下载正文仍可离线打开。"
        case .inspectSource: return "请检查书源版本、访问范围或返回的数据。可以在书源设置中审阅源码，并在诊断记录中查看错误类别。"
        case .settings: return code == "RESOURCE_LIMIT" ? "请求、图片或存储达到上限。可在缓存与下载中查看容量，或检查书源返回的数据。" : "请解锁设备后重试；若刚修改过账号或书源，重新打开页面再保存。"
        case .none: return code == "NOT_DOWNLOADED" ? "此账号尚未下载这一章，请联网获取后再尝试离线阅读。" : "已完成的内容会保留，可以重新开始操作。"
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
}

/// In-memory, bounded operational summaries. No website text, URLs, queries, headers, refs or bodies.
public actor SourceDiagnostics {
    public static let shared = SourceDiagnostics()
    private let capacity: Int
    private var values: [SourceDiagnosticRecord] = []
    public init(capacity: Int = 128) { self.capacity = min(128, max(1, capacity)) }
    public func record(id: UUID, operation: SourceDiagnosticOperation, identity: SourceExecutionIdentity,
                       issue: SourceIssue?, elapsedMilliseconds: Int, line: Int? = nil, column: Int? = nil) {
        guard let encoded = try? SourceCoding.encode(identity.scope) else { return }
        values.append(.init(id: id, timestamp: Date(), operation: operation, sourceDigest: identity.sourceDigest,
            scopeDigest: SourceCoding.digest(encoded), configurationDigest: identity.configurationDigest,
            code: issue?.code ?? "OK", elapsedMilliseconds: max(0, min(300_000, elapsedMilliseconds)),
            line: line.flatMap { (1...2_097_152).contains($0) ? $0 : nil }, column: column.flatMap { (1...2_097_152).contains($0) ? $0 : nil }))
        if values.count > capacity { values.removeFirst(values.count - capacity) }
    }
    public func records() -> [SourceDiagnosticRecord] { Array(values.reversed()) }
    public func clear() { values.removeAll() }
    public func export() throws -> Data {
        struct Report: Encodable { let version = 1; let operations: [SourceDiagnosticRecord] }
        let data = try SourceCoding.encode(Report(operations: values))
        guard data.count <= 131_072 else { throw SourceDomainError(.resourceLimit, "诊断报告超过容量限制。") }
        return data
    }
}
