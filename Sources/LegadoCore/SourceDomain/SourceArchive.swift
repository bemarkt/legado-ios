import Foundation
import SQLite3

public struct SourceInstallation: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let publisherID: String
    public let name: String
    public let version: String
    public let source: String
    public let digest: String
    public let origins: [String]
    public let createdAt: Date
    public let originURL: String?
    public let locallyModified: Bool?
    public init(id: UUID = UUID(), publisherID: String, name: String, version: String, source: String, origins: [String], createdAt: Date = Date(), originURL: String? = nil, locallyModified: Bool = false) throws {
        guard source.utf8.count <= 2_097_152, !publisherID.isEmpty, !name.isEmpty, !origins.isEmpty else {
            throw SourceDomainError(.invalidInput, "Invalid source installation")
        }
        self.id = id; self.publisherID = publisherID; self.name = name; self.version = version
        self.source = source; digest = SourceCoding.digest(Data(source.utf8)); self.origins = origins; self.createdAt = createdAt
        self.originURL = originURL; self.locallyModified = locallyModified
    }
}

public struct SourceStateEntry: Codable, Sendable, Equatable {
    public let value: SourceJSON
    public let revision: String
}
public enum SourceStateCondition: Sendable { case any, missing, revision(String) }

public struct SourceSavedBook: Codable, Sendable, Equatable {
    public let key: SourceBookKey
    public let details: SourceWire.BookDetails
    public let addedAt: Date
    public init(key: SourceBookKey, details: SourceWire.BookDetails, addedAt: Date = Date()) {
        self.key = key; self.details = details; self.addedAt = addedAt
    }
}

/// The exact request and catalog generation that produced a downloaded chapter.
/// Provider catalog revisions and content revisions are independent opaque values.
public struct SourceChapterProvenance: Codable, Sendable, Equatable {
    public let book: SourceWire.SourceRef
    public let chapter: SourceWire.SourceRef
    public let catalogEpoch: String?
}

struct SourceChapterRequest: Sendable {
    let key: SourceChapterKey
    let identity: SourceExecutionIdentity
    let provenance: SourceChapterProvenance
    let catalogDigest: String?
    let previousCacheDigest: String?
}

enum SourceChapterPreparation: Sendable {
    case cached(SourceCachedChapter)
    case fetch(SourceChapterRequest)
}

public struct SourceCachedChapter: Codable, Sendable, Equatable {
    public let key: SourceChapterKey
    public let identity: SourceExecutionIdentity
    public let content: SourceWire.ChapterContent
    public let document: ChapterDocument
    public let storedAt: Date
    public let provenance: SourceChapterProvenance?
    public init(key: SourceChapterKey, identity: SourceExecutionIdentity, content: SourceWire.ChapterContent, document: ChapterDocument,
                storedAt: Date = Date(), provenance: SourceChapterProvenance? = nil) {
        self.key = key; self.identity = identity; self.content = content; self.document = document; self.storedAt = storedAt
        self.provenance = provenance
    }
}

/// Separate database while the native protocol remains experimental. Existing Legado/TXT/EPUB data is untouched.
/// Actor isolation and BEGIN IMMEDIATE protect compare-and-set across multiple repository instances.
public actor SourceArchive {
    nonisolated(unsafe) private let handle: OpaquePointer
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let stateLimit: Int
    public init(url: URL, stateLimit: Int = 1_048_576) throws {
        self.stateLimit = stateLimit
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var raw: OpaquePointer?
        guard sqlite3_open_v2(url.path, &raw, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let raw else {
            if let raw { sqlite3_close(raw) }
            throw SourceDomainError(.unavailable, "Cannot open native source database")
        }
        handle = raw
        sqlite3_busy_timeout(raw, 5000)
        do {
            try Self.execute(raw, "PRAGMA journal_mode=WAL")
            var query: OpaquePointer?
            guard sqlite3_prepare_v2(raw, "PRAGMA user_version", -1, &query, nil) == SQLITE_OK, let query else {
                throw SourceDomainError(.unavailable, "Cannot read native source database version")
            }
            let version: Int32
            if sqlite3_step(query) == SQLITE_ROW { version = sqlite3_column_int(query, 0) }
            else { sqlite3_finalize(query); throw SourceDomainError(.unavailable, "Missing database version") }
            sqlite3_finalize(query)
            guard version <= 1 else { throw SourceDomainError(.unavailable, "Native source database is newer than this app") }
            try Self.execute(raw, """
                BEGIN IMMEDIATE;
                CREATE TABLE IF NOT EXISTS records(namespace TEXT NOT NULL, scope TEXT NOT NULL, key TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(namespace,scope,key));
                CREATE TABLE IF NOT EXISTS source_state(scope TEXT NOT NULL, key TEXT NOT NULL, payload BLOB NOT NULL, revision TEXT NOT NULL, PRIMARY KEY(scope,key));
                PRAGMA user_version=1;
                COMMIT;
                """)
        } catch { try? Self.execute(raw, "ROLLBACK"); sqlite3_close(raw); throw error }
    }
    deinit { sqlite3_close(handle) }
    public static func defaultURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Legado/native-sources.sqlite3")
    }

    public func installations() throws -> [SourceInstallation] { try records("installation", scope: "", as: SourceInstallation.self) }
    public func installation(_ id: UUID) throws -> SourceInstallation? { try record("installation", scope: "", key: id.uuidString) }
    /// Source and configuration are captured in one database read transaction, including across connections.
    public func executionSnapshot(scope: SourceScope) throws -> (installation: SourceInstallation, configuration: SourceJSON?) {
        try transaction {
            guard let source = try installation(scope.installationID) else {
                throw SourceDomainError(.unavailable, "Source installation is unavailable")
            }
            return (source, try configuration(scope: scope))
        }
    }
    public func installationHistory(_ id: UUID) throws -> [SourceInstallation] {
        try record("installation-history", scope: "", key: id.uuidString) ?? []
    }
    public func saveInstallation(_ value: SourceInstallation, replacing expectedDigest: String? = nil,
                                 resetConfigurationFor scope: SourceScope? = nil) throws {
        guard value.digest == SourceCoding.digest(Data(value.source.utf8)), value.source.utf8.count <= 2_097_152 else {
            throw SourceDomainError(.invalidData, "Source snapshot digest mismatch")
        }
        try transaction {
            let current = try installation(value.id)
            guard current?.digest == expectedDigest else { throw SourceDomainError(.storageConflict, "Installation changed; reload before saving") }
            if let current {
                guard current.publisherID == value.publisherID else { throw SourceDomainError(.invalidInput, "A different publisher ID needs a separate installation") }
                if current.digest != value.digest {
                    var history = try installationHistory(value.id)
                    history.insert(current, at: 0)
                    try put("installation-history", scope: "", key: value.id.uuidString, value: Array(history.prefix(8)))
                }
            }
            if let scope {
                guard scope.installationID == value.id else { throw SourceDomainError(.invalidInput, "Configuration scope does not match installation") }
                try saveConfiguration(.object([:]), scope: scope)
            }
            try put("installation", scope: "", key: value.id.uuidString, value: value)
        }
    }
    public func configuration(scope: SourceScope) throws -> SourceJSON? { try record("configuration", scope: scopeKey(scope), key: "values") }
    public func saveConfiguration(_ value: SourceJSON, scope: SourceScope, expectedSourceDigest: String? = nil) throws {
        guard case .object = value else { throw SourceDomainError(.invalidInput, "Configuration must be an object") }
        _ = try value.validatedData(maximumBytes: 65_536)
        if let expectedSourceDigest {
            try transaction {
                guard try installation(scope.installationID)?.digest == expectedSourceDigest else {
                    throw SourceDomainError(.storageConflict, "Source changed; reopen settings before saving")
                }
                try put("configuration", scope: scopeKey(scope), key: "values", value: value)
            }
        } else { try put("configuration", scope: scopeKey(scope), key: "values", value: value) }
    }
    public func books(scope: SourceScope) throws -> [SourceSavedBook] { try records("book", scope: scopeKey(scope), as: SourceSavedBook.self) }
    public func saveBook(_ value: SourceSavedBook) throws {
        guard value.key.bookID == value.details.ref.id else { throw SourceDomainError(.invalidInput, "Book identity mismatch") }
        try put("book", scope: scopeKey(value.key.scope), key: value.key.bookID, value: value)
    }
    public func catalog(book: SourceBookKey) throws -> SourceCatalog? { try record("catalog", scope: scopeKey(book.scope), key: book.bookID) }
    @discardableResult
    public func saveCatalog(_ value: SourceCatalog, gate: SourceCommitGate? = nil) throws -> SourceCatalog {
        try transaction(gate: gate) {
            let key = try SourceBookKey(scope: value.identity.scope, bookID: value.book.id)
            let previous = try catalog(book: key)
            var saved = value
            if let previous, let revision = value.revision, !revision.isEmpty,
               previous.identity == value.identity, previous.book == value.book,
               previous.revision == revision, previous.chapters == value.chapters,
               let epoch = previous.cacheEpoch {
                saved.cacheEpoch = epoch
            } else { saved.cacheEpoch = UUID() }
            try put("catalog", scope: scopeKey(key.scope), key: key.bookID, value: saved)
            return saved
        }
    }

    /// Without an expected request this is a diagnostic/cache lookup. Production online reads
    /// use prepareChapter so request validation and cache lookup share the same transaction.
    public func chapter(_ key: SourceChapterKey, identity: SourceExecutionIdentity, allowPreviousExtraction: Bool = false, gate: SourceCommitGate? = nil) throws -> SourceCachedChapter? {
        guard key.book.scope == identity.scope else { throw SourceDomainError(.invalidInput, "Cache scope mismatch") }
        return try transaction(gate: gate) {
            guard let cached = try storedChapter(key) else { return nil }
            if !allowPreviousExtraction {
                guard cached.identity == identity, let provenance = cached.provenance,
                      try matchesCatalog(provenance, identity: identity, catalog: catalog(book: key.book)) else { return nil }
            }
            return try normalizeCachedChapter(cached)
        }
    }

    func prepareChapter(identity: SourceExecutionIdentity, book: SourceWire.SourceRef, chapter: SourceWire.SourceRef,
                        expectedCatalog: SourceCatalog?, reload: Bool, gate: SourceCommitGate) throws -> SourceChapterPreparation {
        let key = try SourceChapterKey(book: .init(scope: identity.scope, bookID: book.id), chapterID: chapter.id)
        return try transaction(gate: gate) {
            let current = try catalog(book: key.book)
            if let expectedCatalog {
                guard try digest(expectedCatalog) == digest(current) else {
                    throw SourceDomainError(.catalogChanged, "目录已更新，请返回书籍详情重新打开章节。")
                }
            }
            let provenance = SourceChapterProvenance(book: book, chapter: chapter, catalogEpoch: try epoch(current))
            guard try matchesCatalog(provenance, identity: identity, catalog: current) else {
                throw SourceDomainError(.catalogChanged, "书源、目录或章节引用已改变，请刷新目录后重试。")
            }
            let cached = try storedChapter(key)
            if !reload, let cached, cached.identity == identity, cached.provenance == provenance {
                return .cached(try normalizeCachedChapter(cached))
            }
            return .fetch(SourceChapterRequest(key: key, identity: identity, provenance: provenance,
                                               catalogDigest: try digest(current), previousCacheDigest: try digest(cached)))
        }
    }

    /// Compare the directory AND the previously observed cache in one SQLite transaction.
    /// A response captured before another connection's commit cannot overwrite that commit.
    func saveChapter(_ value: SourceCachedChapter, request: SourceChapterRequest, gate: SourceCommitGate) throws {
        guard value.key == request.key, value.identity == request.identity, value.provenance == request.provenance,
              value.key.book.scope == value.identity.scope else { throw SourceDomainError(.invalidInput, "Chapter request identity mismatch") }
        try transaction(gate: gate) {
            guard try digest(catalog(book: value.key.book)) == request.catalogDigest else {
                throw SourceDomainError(.catalogChanged, "读取期间目录已更新，请重新打开章节。")
            }
            guard try digest(storedChapter(value.key)) == request.previousCacheDigest else {
                throw SourceDomainError(.stale, "章节缓存已由另一读取更新，请重试。")
            }
            try put("chapter", scope: scopeKey(value.key.book.scope), key: chapterKey(value.key), value: value)
        }
    }

    private func storedChapter(_ key: SourceChapterKey) throws -> SourceCachedChapter? {
        let value: SourceCachedChapter? = try record("chapter", scope: scopeKey(key.book.scope), key: chapterKey(key))
        guard value == nil || value?.key == key else { throw SourceDomainError(.invalidData, "Corrupt chapter cache identity") }
        return value
    }
    private func digest<T: Encodable>(_ value: T?) throws -> String? {
        try value.map { SourceCoding.digest(try SourceCoding.encode($0)) }
    }
    private func epoch(_ catalog: SourceCatalog?) throws -> String? {
        guard let catalog else { return nil }
        return try catalog.cacheEpoch?.uuidString ?? digest(catalog)
    }
    private func matchesCatalog(_ provenance: SourceChapterProvenance, identity: SourceExecutionIdentity, catalog: SourceCatalog?) throws -> Bool {
        guard let catalog else { return provenance.catalogEpoch == nil }
        return try catalog.identity == identity && catalog.book == provenance.book && epoch(catalog) == provenance.catalogEpoch &&
            catalog.chapters.contains(where: { $0.ref == provenance.chapter })
    }
    private func normalizeCachedChapter(_ value: SourceCachedChapter) throws -> SourceCachedChapter {
        guard value.document.normalizationVersion != ChapterDocument.currentVersion else { return value }
        let normalized = SourceCachedChapter(key: value.key, identity: value.identity, content: value.content,
            document: try ChapterNormalizer.normalize(value.content), storedAt: value.storedAt, provenance: value.provenance)
        try put("chapter", scope: scopeKey(value.key.book.scope), key: chapterKey(value.key), value: normalized)
        return normalized
    }
    public func anchor(book: SourceBookKey) throws -> SourceReadingAnchor? { try record("anchor", scope: scopeKey(book.scope), key: book.bookID) }
    public func saveAnchor(_ value: SourceReadingAnchor) throws { try put("anchor", scope: scopeKey(value.chapter.book.scope), key: value.chapter.book.bookID, value: value) }

    public func state(scope: SourceScope, key: String) throws -> SourceStateEntry? {
        try validateStateKey(key)
        let statement = try prepare("SELECT payload,revision FROM source_state WHERE scope=? AND key=?", strings: [scopeKey(scope), key])
        defer { sqlite3_finalize(statement) }
        switch sqlite3_step(statement) {
        case SQLITE_DONE: return nil
        case SQLITE_ROW: return SourceStateEntry(value: try SourceCoding.decode(SourceJSON.self, from: data(statement, column: 0)), revision: string(statement, column: 1))
        default: throw databaseError()
        }
    }
    @discardableResult
    public func setState(scope: SourceScope, key: String, value: SourceJSON, condition: SourceStateCondition = .any, gate: SourceCommitGate? = nil) throws -> SourceStateEntry {
        try validateStateKey(key)
        let payload = try value.validatedData(maximumBytes: 65_536)
        return try transaction(gate: gate) {
            let current = try state(scope: scope, key: key)
            try check(condition, current: current)
            let query = try prepare("SELECT COALESCE(SUM(length(payload)),0) FROM source_state WHERE scope=? AND key<>?", strings: [scopeKey(scope), key])
            defer { sqlite3_finalize(query) }
            guard sqlite3_step(query) == SQLITE_ROW else { throw databaseError() }
            guard Int(sqlite3_column_int64(query, 0)) + payload.count <= stateLimit else {
                throw SourceDomainError(.resourceLimit, "Source state quota exceeded")
            }
            let result = SourceStateEntry(value: value, revision: UUID().uuidString)
            let statement = try prepare("INSERT INTO source_state(scope,key,payload,revision) VALUES(?,?,?,?) ON CONFLICT(scope,key) DO UPDATE SET payload=excluded.payload,revision=excluded.revision", strings: [scopeKey(scope), key])
            defer { sqlite3_finalize(statement) }
            try bind(payload, to: statement, at: 3)
            try bind(result.revision, to: statement, at: 4)
            try done(statement)
            return result
        }
    }
    public func removeState(scope: SourceScope, key: String, condition: SourceStateCondition = .any, gate: SourceCommitGate? = nil) throws {
        try validateStateKey(key)
        try transaction(gate: gate) {
            try check(condition, current: state(scope: scope, key: key))
            let statement = try prepare("DELETE FROM source_state WHERE scope=? AND key=?", strings: [scopeKey(scope), key])
            defer { sqlite3_finalize(statement) }
            try done(statement)
        }
    }
    private func check(_ condition: SourceStateCondition, current: SourceStateEntry?) throws {
        let matches: Bool
        switch condition {
        case .any: matches = true
        case .missing: matches = current == nil
        case .revision(let value): matches = current?.revision == value
        }
        guard matches else { throw SourceDomainError(.storageConflict, "Source state revision changed") }
    }
    private func validateStateKey(_ key: String) throws {
        guard !key.isEmpty, key.unicodeScalars.count <= 128, !key.contains("\0") else { throw SourceDomainError(.invalidInput, "Invalid source state key") }
    }
    private func scopeKey(_ scope: SourceScope) throws -> String { SourceCoding.digest(try SourceCoding.encode(scope)) }
    private func chapterKey(_ key: SourceChapterKey) throws -> String { SourceCoding.digest(try SourceCoding.encode(key)) }
    private func record<T: Decodable>(_ namespace: String, scope: String, key: String) throws -> T? {
        let statement = try prepare("SELECT payload FROM records WHERE namespace=? AND scope=? AND key=?", strings: [namespace, scope, key])
        defer { sqlite3_finalize(statement) }
        switch sqlite3_step(statement) {
        case SQLITE_DONE: return nil
        case SQLITE_ROW: return try SourceCoding.decode(T.self, from: data(statement, column: 0))
        default: throw databaseError()
        }
    }
    private func records<T: Decodable>(_ namespace: String, scope: String, as type: T.Type) throws -> [T] {
        let statement = try prepare("SELECT payload FROM records WHERE namespace=? AND scope=? ORDER BY key", strings: [namespace, scope])
        defer { sqlite3_finalize(statement) }
        var result: [T] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_DONE: return result
            case SQLITE_ROW: result.append(try SourceCoding.decode(T.self, from: data(statement, column: 0)))
            default: throw databaseError()
            }
        }
    }
    private func put<T: Encodable>(_ namespace: String, scope: String, key: String, value: T, gate: SourceCommitGate? = nil) throws {
        try Task.checkCancellation()
        let payload = try SourceCoding.encode(value)
        guard payload.count <= 64 * 1024 * 1024 else { throw SourceDomainError(.resourceLimit, "Archive record budget exceeded") }
        let statement = try prepare("INSERT INTO records(namespace,scope,key,payload) VALUES(?,?,?,?) ON CONFLICT(namespace,scope,key) DO UPDATE SET payload=excluded.payload", strings: [namespace, scope, key])
        defer { sqlite3_finalize(statement) }
        try bind(payload, to: statement, at: 4)
        if let gate { try transaction(gate: gate) { try done(statement) } }
        else { try Task.checkCancellation(); try done(statement) }
    }
    private func transaction<T>(gate: SourceCommitGate? = nil, _ body: () throws -> T) throws -> T {
        try Task.checkCancellation()
        try Self.execute(handle, "BEGIN IMMEDIATE")
        do {
            let result = try body()
            try Task.checkCancellation()
            if let gate { try gate.withCommit { try Self.execute(handle, "COMMIT") } }
            else { try Self.execute(handle, "COMMIT") }
            return result
        } catch { try? Self.execute(handle, "ROLLBACK"); throw error }
    }
    private func prepare(_ sql: String, strings: [String]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw databaseError() }
        do { for (index, value) in strings.enumerated() { try bind(value, to: statement, at: Int32(index + 1)) } }
        catch { sqlite3_finalize(statement); throw error }
        return statement
    }
    private func bind(_ value: String, to statement: OpaquePointer, at index: Int32) throws {
        let status = value.withCString { sqlite3_bind_text(statement, index, $0, -1, Self.transient) }
        guard status == SQLITE_OK else { throw databaseError() }
    }
    private func bind(_ value: Data, to statement: OpaquePointer, at index: Int32) throws {
        let status = value.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32($0.count), Self.transient) }
        guard status == SQLITE_OK else { throw databaseError() }
    }
    private func done(_ statement: OpaquePointer) throws { guard sqlite3_step(statement) == SQLITE_DONE else { throw databaseError() } }
    private func data(_ statement: OpaquePointer, column: Int32) -> Data {
        let length = Int(sqlite3_column_bytes(statement, column))
        guard let bytes = sqlite3_column_blob(statement, column), length > 0 else { return Data() }
        return Data(bytes: bytes, count: length)
    }
    private func string(_ statement: OpaquePointer, column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }
    private func databaseError() -> SourceDomainError { .init(.unavailable, "Native source database operation failed") }
    private static func execute(_ database: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw SourceDomainError(.unavailable, "Native source database operation failed") }
    }
}
