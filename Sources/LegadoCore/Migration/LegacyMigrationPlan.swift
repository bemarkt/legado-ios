import Foundation
import SQLite3

/// Local migration evidence. The recovery snapshot remains authoritative for original/unknown fields.
/// This report deliberately excludes credential values and raw row payloads.
public struct LegacyMigrationReport: Codable, Sendable, Equatable {
    public enum Disposition: String, Codable, Sendable { case mapped, retained, needsReview }
    public enum Reason: String, Codable, Sendable {
        case imported, localFeature, unsupportedSource, malformedRecord, missingSource, invalidCatalog
        case missingCache, ambiguousCache, foreignCache, supplementalContent, positionChanged, ambiguousBookmark
        case reauthentication, preservedFeature, capacity, orphanedRecord
    }
    public struct Record: Codable, Sendable, Equatable, Identifiable {
        public let table: String
        public let rowID: Int64
        public let payloadDigest: String?
        public var disposition: Disposition
        public var reason: Reason
        public var id: String { table + ":" + String(rowID) }
    }
    public struct Table: Codable, Sendable, Equatable {
        public let total: Int64
        public var mapped: Int64 = 0
        public var needsReview: Int64 = 0
        public var retained: Int64 { total - mapped - needsReview }
    }
    public struct Source: Codable, Sendable, Equatable, Identifiable {
        public let legacyID: String
        public let installation: SourceInstallation
        public let scope: SourceScope
        public let enabled: Bool
        public let group: String?
        public var id: UUID { installation.id }
    }
    public struct BookMapping: Codable, Sendable, Equatable, Identifiable {
        public let legacyURL: String
        public let key: SourceBookKey
        public let title: String
        public let order: Int
        public let group: Int64
        public let chapterCount: Int
        public var cachedChapters: Int = 0
        public var progressMapped: Bool = false
        public var id: SourceBookKey { key }
    }
    public struct Annotation: Codable, Sendable, Equatable, Identifiable {
        public let rowID: Int64
        public let bookmark: Bookmark
        public let anchor: SourceReadingAnchor?
        public var id: Int64 { rowID }
    }
    public let version: Int
    public let snapshotID: UUID
    public let snapshotDigest: String
    public let attempt: String
    public var tables: [String: Table]
    public var records: [Record]
    public var sources: [Source]
    public var books: [BookMapping]
    public var annotations: [Annotation]
    public var cacheFilesMapped: Int = 0
    public var cacheFilesRetained: Int = 0
    public var archiveSHA256: String = ""
    public var archiveBytes: Int64 = 0
    public let createdAt: Date
    public var reviewCount: Int { records.filter { $0.disposition == .needsReview }.count }
}

/// Read-only, paged SQLite access; a damaged JSON row never hides other rows in the table.
/// Only the mapper uses these values; they are not printed or exported as diagnostics.
actor LegacyMigrationReader {
    struct Row: Sendable {
        let id: Int64
        let fields: [String: String]
        let payload: Data?
        var digest: String? { payload.map(SourceCoding.digest) }
        func decode<T: Decodable>(_ type: T.Type) throws -> T {
            guard let payload, payload.count <= 16_777_216 else { throw SourceDomainError(.invalidData, "旧记录缺少有效内容。") }
            return try SourceCoding.decode(type, from: payload)
        }
    }
    nonisolated(unsafe) private let handle: OpaquePointer
    private let tables: Set<String>
    init(url: URL, tables: Set<String>) throws {
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(url.path, &pointer, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let pointer else {
            if let pointer { sqlite3_close(pointer) }
            throw SourceDomainError(.unavailable, "无法只读打开迁移副本。")
        }
        handle = pointer; self.tables = tables
    }
    deinit { sqlite3_close(handle) }
    func rows(_ table: String, after: Int64? = nil, bookURL: String? = nil) throws -> [Row] {
        guard tables.contains(table) else { return [] }
        let escaped = table.replacingOccurrences(of: "\"", with: "\"\"")
        var sql = "SELECT rowid AS migration_rowid,* FROM \"" + escaped + "\" WHERE 1=1"
        if let after { sql += " AND rowid>" + String(after) }
        if bookURL != nil { sql += " AND book_url=?" }
        sql += " ORDER BY rowid LIMIT 128"
        var query: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &query, nil) == SQLITE_OK, let query else {
            throw SourceDomainError(.invalidData, "旧表结构不符合已知迁移格式。")
        }
        defer { sqlite3_finalize(query) }
        if let bookURL {
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            guard sqlite3_bind_text(query, 1, bookURL, -1, transient) == SQLITE_OK else { throw SourceDomainError(.unavailable, "无法绑定旧目录身份。") }
        }
        var result: [Row] = [], bytes = 0
        while true {
            try Task.checkCancellation()
            let step = sqlite3_step(query)
            if step == SQLITE_DONE { return result }
            guard step == SQLITE_ROW else { throw SourceDomainError(.invalidData, "读取旧表失败。") }
            let id = sqlite3_column_int64(query, 0)
            var fields: [String: String] = [:], payload: Data?
            for index in 1..<sqlite3_column_count(query) {
                let name = String(cString: sqlite3_column_name(query, index))
                let count = Int(sqlite3_column_bytes(query, index))
                // Oversized rows remain in the immutable source, with a review result instead of an allocation spike.
                if name == "payload" {
                    if count <= 16_777_216, let pointer = sqlite3_column_blob(query, index) { payload = Data(bytes: pointer, count: count); bytes += count }
                } else if count <= 16_384, let value = sqlite3_column_text(query, index) {
                    fields[name] = String(cString: value)
                }
            }
            result.append(.init(id: id, fields: fields, payload: payload))
            if bytes >= 16_777_216 { return result }
        }
    }
}
