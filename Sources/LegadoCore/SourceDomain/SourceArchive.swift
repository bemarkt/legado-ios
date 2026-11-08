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
    let retainOffline: Bool
    let storageGeneration: String
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

public struct SourceChapterStorageLimits: Sendable, Equatable {
    public let readingCacheBytes: Int
    public let offlineBytes: Int
    public init(readingCacheBytes: Int = 128 * 1024 * 1024, offlineBytes: Int = 1024 * 1024 * 1024) {
        self.readingCacheBytes = max(1, readingCacheBytes)
        self.offlineBytes = max(1, offlineBytes)
    }
}

public struct SourceChapterStorageUsage: Sendable, Equatable {
    public let readingCacheBytes: Int
    public let readingCacheCount: Int
    public let offlineBytes: Int
    public let offlineCount: Int
    public let limits: SourceChapterStorageLimits
}

public enum SourceChapterStorageRemoval: Sendable, Equatable { case readingCache, offlineDownloads }

public struct SourceCatalogCacheLimits: Sendable {
    public let maximumCatalogs: Int
    public let maximumChapters: Int
    /// Serialized bytes are an accounting bound, not a measurement of Swift heap usage.
    public let maximumEncodedBytes: Int
    public init(maximumCatalogs: Int = 4, maximumChapters: Int = 100_000, maximumEncodedBytes: Int = 32 * 1024 * 1024) {
        self.maximumCatalogs = max(0, maximumCatalogs)
        self.maximumChapters = max(0, maximumChapters)
        self.maximumEncodedBytes = max(0, maximumEncodedBytes)
    }
}

struct SourceCatalogCacheStatistics: Sendable {
    let catalogs: Int
    let chapters: Int
    let encodedBytes: Int
    let decodes: Int
}

/// Separate database while the native protocol remains experimental. Existing Legado/TXT/EPUB data is untouched.
/// Actor isolation and BEGIN IMMEDIATE protect compare-and-set across multiple repository instances.
public actor SourceArchive {
    nonisolated(unsafe) private let handle: OpaquePointer
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private let stateLimit: Int
    private let catalogCacheLimits: SourceCatalogCacheLimits
    private let coverStorageBytes: Int
    private let coverStorageCount: Int
    private struct CatalogIndex {
        let catalog: SourceCatalog
        let recordVersion: String
        let digest: String
        let references: [String: SourceWire.SourceRef]
        let encodedBytes: Int
        var epoch: String { catalog.cacheEpoch?.uuidString ?? digest }
    }
    private var catalogCache: [SourceBookKey: CatalogIndex] = [:]
    private var catalogOrder: [SourceBookKey] = []
    private var catalogDecodes = 0
    public init(url: URL, stateLimit: Int = 1_048_576, catalogCacheLimits: SourceCatalogCacheLimits = .init(),
                initialChapterStorageLimits: SourceChapterStorageLimits = .init(),
                coverStorageBytes: Int = SourceCoverStorageUsage.maximumBytes, coverStorageCount: Int = SourceCoverStorageUsage.maximumCount) throws {
        self.stateLimit = stateLimit
        self.catalogCacheLimits = catalogCacheLimits
        self.coverStorageBytes = max(1, min(coverStorageBytes, SourceCoverStorageUsage.maximumBytes))
        self.coverStorageCount = max(1, min(coverStorageCount, SourceCoverStorageUsage.maximumCount))
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
            try Self.execute(raw, "BEGIN IMMEDIATE")
            var query: OpaquePointer?
            guard sqlite3_prepare_v2(raw, "PRAGMA user_version", -1, &query, nil) == SQLITE_OK, let query else {
                throw SourceDomainError(.unavailable, "Cannot read native source database version")
            }
            let version: Int32
            if sqlite3_step(query) == SQLITE_ROW { version = sqlite3_column_int(query, 0) }
            else { sqlite3_finalize(query); throw SourceDomainError(.unavailable, "Missing database version") }
            sqlite3_finalize(query)
            guard version <= 3 else { throw SourceDomainError(.unavailable, "Native source database is newer than this app") }
            try Self.execute(raw, """
                CREATE TABLE IF NOT EXISTS records(namespace TEXT NOT NULL, scope TEXT NOT NULL, key TEXT NOT NULL, payload BLOB NOT NULL, PRIMARY KEY(namespace,scope,key));
                CREATE TABLE IF NOT EXISTS source_state(scope TEXT NOT NULL, key TEXT NOT NULL, payload BLOB NOT NULL, revision TEXT NOT NULL, PRIMARY KEY(scope,key));
                """)
            if version < 2 {
                try Self.execute(raw, """
                    ALTER TABLE records ADD COLUMN record_version TEXT NOT NULL DEFAULT '';
                    UPDATE records SET record_version=lower(hex(randomblob(16)));
                    CREATE TRIGGER records_version_insert AFTER INSERT ON records BEGIN
                        UPDATE records SET record_version=lower(hex(randomblob(16)))
                        WHERE namespace=NEW.namespace AND scope=NEW.scope AND key=NEW.key;
                    END;
                    CREATE TRIGGER records_version_update AFTER UPDATE OF payload,namespace,scope,key ON records BEGIN
                        UPDATE records SET record_version=lower(hex(randomblob(16)))
                        WHERE namespace=NEW.namespace AND scope=NEW.scope AND key=NEW.key;
                    END;
                    PRAGMA user_version=2;
                    """)
            }
            if version < 3 {
                try Self.execute(raw, Self.chapterStorageSchema)
                try Self.execute(raw, "UPDATE chapter_usage SET cache_limit=\(initialChapterStorageLimits.readingCacheBytes),offline_limit=\(initialChapterStorageLimits.offlineBytes) WHERE id=1")
            }
            try Self.execute(raw, "COMMIT")
        } catch { try? Self.execute(raw, "ROLLBACK"); sqlite3_close(raw); throw error }
    }
    private static let chapterStorageSchema = """
        CREATE TABLE chapter_usage(id INTEGER PRIMARY KEY CHECK(id=1),cache_bytes INTEGER NOT NULL DEFAULT 0,cache_count INTEGER NOT NULL DEFAULT 0,offline_bytes INTEGER NOT NULL DEFAULT 0,offline_count INTEGER NOT NULL DEFAULT 0,access_clock INTEGER NOT NULL DEFAULT 0,generation TEXT NOT NULL,cache_limit INTEGER NOT NULL DEFAULT 134217728,offline_limit INTEGER NOT NULL DEFAULT 1073741824);
        INSERT INTO chapter_usage(id,generation) VALUES(1,lower(hex(randomblob(16))));
        CREATE TABLE chapter_storage(scope TEXT NOT NULL,key TEXT NOT NULL,bytes INTEGER NOT NULL,retained INTEGER NOT NULL CHECK(retained IN (0,1)),last_access INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(scope,key));
        CREATE INDEX chapter_storage_lru ON chapter_storage(retained,last_access,scope,key);
        CREATE TRIGGER chapter_usage_insert AFTER INSERT ON chapter_storage BEGIN
            UPDATE chapter_usage SET cache_bytes=cache_bytes+NEW.bytes*(1-NEW.retained),cache_count=cache_count+(1-NEW.retained),offline_bytes=offline_bytes+NEW.bytes*NEW.retained,offline_count=offline_count+NEW.retained WHERE id=1;
        END;
        CREATE TRIGGER chapter_usage_update AFTER UPDATE OF bytes,retained ON chapter_storage BEGIN
            UPDATE chapter_usage SET cache_bytes=cache_bytes+NEW.bytes*(1-NEW.retained)-OLD.bytes*(1-OLD.retained),cache_count=cache_count+OLD.retained-NEW.retained,offline_bytes=offline_bytes+NEW.bytes*NEW.retained-OLD.bytes*OLD.retained,offline_count=offline_count+NEW.retained-OLD.retained WHERE id=1;
        END;
        CREATE TRIGGER chapter_usage_delete AFTER DELETE ON chapter_storage BEGIN
            UPDATE chapter_usage SET cache_bytes=cache_bytes-OLD.bytes*(1-OLD.retained),cache_count=cache_count-(1-OLD.retained),offline_bytes=offline_bytes-OLD.bytes*OLD.retained,offline_count=offline_count-OLD.retained WHERE id=1;
        END;
        INSERT INTO chapter_storage(scope,key,bytes,retained) SELECT scope,key,length(payload),1 FROM records WHERE namespace='chapter';
        CREATE TRIGGER chapter_record_insert AFTER INSERT ON records WHEN NEW.namespace='chapter' BEGIN
            INSERT INTO chapter_storage(scope,key,bytes,retained) VALUES(NEW.scope,NEW.key,length(NEW.payload),1);
        END;
        CREATE TRIGGER chapter_record_update AFTER UPDATE OF payload ON records WHEN NEW.namespace='chapter' BEGIN
            INSERT INTO chapter_storage(scope,key,bytes,retained) VALUES(NEW.scope,NEW.key,length(NEW.payload),1)
            ON CONFLICT(scope,key) DO UPDATE SET bytes=excluded.bytes;
        END;
        CREATE TRIGGER chapter_record_delete AFTER DELETE ON records WHEN OLD.namespace='chapter' BEGIN
            DELETE FROM chapter_storage WHERE scope=OLD.scope AND key=OLD.key;
        END;
        PRAGMA user_version=3;
        """

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
                                 resetConfigurationFor scope: SourceScope? = nil,
                                 reviewedConfigurations: [String: SourceJSON]? = nil, resetAllAccountConfigurations: Bool = false) throws {
        guard value.digest == SourceCoding.digest(Data(value.source.utf8)), value.source.utf8.count <= 2_097_152 else {
            throw SourceDomainError(.invalidData, "Source snapshot digest mismatch")
        }
        try transaction {
            let current = try installation(value.id)
            guard current?.digest == expectedDigest else { throw SourceDomainError(.storageConflict, "Installation changed; reload before saving") }
            if let reviewedConfigurations {
                guard try accountConfigurationValues(value.id) == reviewedConfigurations else {
                    throw SourceDomainError(.storageConflict, "账号或选项已经改变，请重新审阅书源更新。")
                }
            }
            if resetAllAccountConfigurations {
                guard let reviewedConfigurations else { throw SourceDomainError(.invalidInput, "重置所有账号选项前需要审阅配置。") }
                for accountID in reviewedConfigurations.keys {
                    try saveConfiguration(.object([:]), scope: SourceScope(installationID: value.id, accountID: accountID))
                }
            }
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
    public func accountSettings(installationID: UUID) throws -> SourceAccountSettings {
        guard try installation(installationID) != nil else { throw SourceDomainError(.unavailable, "书源安装已不存在。") }
        let value: SourceAccountSettings = try record("accounts", scope: "", key: installationID.uuidString) ?? .init()
        guard value.accounts.count <= 32, value.accounts.first == .guest,
              Set(value.accounts.map(\.id)).count == value.accounts.count,
              value.accounts.contains(where: { $0.id == value.selectedID }),
              value.accounts.allSatisfy({ $0.id == "guest" || UUID(uuidString: $0.id) != nil }) else {
            throw SourceDomainError(.invalidData, "账号列表无效。")
        }
        return value
    }
    @discardableResult
    public func addAccount(name: String, installationID: UUID) throws -> SourceAccount {
        try transaction {
            var settings = try accountSettings(installationID: installationID)
            guard settings.accounts.count < 32 else { throw SourceDomainError(.resourceLimit, "每个书源最多保存 31 个独立账号。") }
            let account = try SourceAccount(name: name)
            settings.accounts.append(account)
            try put("accounts", scope: "", key: installationID.uuidString, value: settings)
            return account
        }
    }
    public func selectAccount(_ accountID: String, installationID: UUID) throws {
        try transaction {
            var settings = try accountSettings(installationID: installationID)
            guard settings.accounts.contains(where: { $0.id == accountID }) else { throw SourceDomainError(.invalidInput, "账号已不存在。") }
            settings.selectedID = accountID
            try put("accounts", scope: "", key: installationID.uuidString, value: settings)
        }
    }

    /// Missing overrides and an empty object have the same effective configuration.
    public func accountConfigurations(installationID: UUID) throws -> [String: SourceJSON] {
        try transaction { try accountConfigurationValues(installationID) }
    }
    private func accountConfigurationValues(_ installationID: UUID) throws -> [String: SourceJSON] {
        var values: [String: SourceJSON] = [:]
        for account in try accountSettings(installationID: installationID).accounts {
            let scope = try SourceScope(installationID: installationID, accountID: account.id)
            values[account.id] = try configuration(scope: scope) ?? .object([:])
        }
        return values
    }

    public func configuration(scope: SourceScope) throws -> SourceJSON? { try record("configuration", scope: scopeKey(scope), key: "values") }
    public func saveConfiguration(_ value: SourceJSON, scope: SourceScope, expectedSourceDigest: String? = nil, requireSelectedAccount: Bool = false) throws {
        guard case .object = value else { throw SourceDomainError(.invalidInput, "Configuration must be an object") }
        _ = try value.validatedData(maximumBytes: 65_536)
        if expectedSourceDigest != nil || requireSelectedAccount {
            try transaction {
                if let expectedSourceDigest, try installation(scope.installationID)?.digest != expectedSourceDigest {
                    throw SourceDomainError(.storageConflict, "Source changed; reopen settings before saving")
                }
                if requireSelectedAccount, try accountSettings(installationID: scope.installationID).selectedID != scope.accountID {
                    throw SourceDomainError(.stale, "账号已切换，请重新打开选项。")
                }
                try put("configuration", scope: scopeKey(scope), key: "values", value: value)
            }
        } else { try put("configuration", scope: scopeKey(scope), key: "values", value: value) }
    }

    // Cover thumbnails and their small LRU records use the generic records table; no schema bump.
    public func coverStorageUsage() throws -> SourceCoverStorageUsage {
        let query = try prepare("SELECT COUNT(*),COALESCE(SUM(length(payload)),0) FROM records WHERE namespace='cover-image'", strings: [])
        defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_ROW else { throw databaseError() }
        return .init(count: Int(sqlite3_column_int64(query, 0)), bytes: Int(sqlite3_column_int64(query, 1)))
    }
    private func coverGeneration() throws -> String {
        if let generation: String = try record("cover-control", scope: "", key: "generation") { return generation }
        let generation = UUID().uuidString
        try put("cover-control", scope: "", key: "generation", value: generation)
        return generation
    }
    func prepareCover(_ key: SourceCoverKey, gate: SourceCommitGate) throws -> SourceCoverRequest {
        try transaction(gate: gate) {
            let generation = try coverGeneration(), scope = try scopeKey(key.scope)
            let metadata: SourceCoverMetadata? = try record("cover-access", scope: scope, key: key.digest)
            let query = try prepare("SELECT payload FROM records WHERE namespace='cover-image' AND scope=? AND key=?", strings: [scope, key.digest])
            defer { sqlite3_finalize(query) }
            let status = sqlite3_step(query)
            guard status == SQLITE_ROW || status == SQLITE_DONE else { throw databaseError() }
            var cached: SourceCoverRecord?
            if status == SQLITE_ROW, let metadata {
                let bytes = data(query, column: 0)
                if !bytes.isEmpty, bytes.count <= SourceCoverProcessor.maximumThumbnailBytes {
                    cached = .init(data: bytes, storedAt: metadata.storedAt)
                    // Delete/insert changes the rowid ordering, while keeping the image blob untouched.
                    try touchCover(scope: scope, key: key.digest, metadata: metadata)
                }
            }
            return .init(key: key, generation: generation, cached: cached)
        }
    }
    private func touchCover(scope: String, key: String, metadata: SourceCoverMetadata) throws {
        let query = try prepare("DELETE FROM records WHERE namespace='cover-access' AND scope=? AND key=?", strings: [scope, key])
        defer { sqlite3_finalize(query) }
        try done(query)
        try put("cover-access", scope: scope, key: key, value: metadata)
    }
    func saveCover(_ bytes: Data, request: SourceCoverRequest, gate: SourceCommitGate, now: Date = Date()) throws {
        guard !bytes.isEmpty, bytes.count <= SourceCoverProcessor.maximumThumbnailBytes, bytes.count <= coverStorageBytes else {
            throw SourceDomainError(.resourceLimit, "封面超过缓存容量。")
        }
        try transaction(gate: gate) {
            guard try coverGeneration() == request.generation else { throw SourceDomainError(.stale, "封面缓存已经清理，请重新加载。") }
            let scope = try scopeKey(request.key.scope), key = request.key.digest
            try putPayload("cover-image", scope: scope, key: key, payload: bytes)
            try touchCover(scope: scope, key: key, metadata: .init(storedAt: now))
            var usage = try coverStorageUsage()
            while usage.bytes > coverStorageBytes || usage.count > coverStorageCount {
                let query = try prepare("SELECT scope,key FROM records WHERE namespace='cover-access' ORDER BY rowid LIMIT 1", strings: [])
                guard sqlite3_step(query) == SQLITE_ROW else { sqlite3_finalize(query); throw databaseError() }
                let oldestScope = string(query, column: 0), oldestKey = string(query, column: 1)
                sqlite3_finalize(query)
                let removal = try prepare("DELETE FROM records WHERE namespace IN ('cover-image','cover-access') AND scope=? AND key=?", strings: [oldestScope, oldestKey])
                do { try done(removal) } catch { sqlite3_finalize(removal); throw error }
                sqlite3_finalize(removal)
                usage = try coverStorageUsage()
            }
        }
    }
    @discardableResult
    public func clearCoverCache() throws -> Int {
        try transaction {
            let count = try coverStorageUsage().count
            try Self.execute(handle, "DELETE FROM records WHERE namespace IN ('cover-image','cover-access')")
            try put("cover-control", scope: "", key: "generation", value: UUID().uuidString)
            return count
        }
    }

    public func books(scope: SourceScope) throws -> [SourceSavedBook] { try records("book", scope: scopeKey(scope), as: SourceSavedBook.self) }
    public func saveBook(_ value: SourceSavedBook, gate: SourceCommitGate? = nil) throws {
        guard value.key.bookID == value.details.ref.id else { throw SourceDomainError(.invalidInput, "Book identity mismatch") }
        try put("book", scope: scopeKey(value.key.scope), key: value.key.bookID, value: value, gate: gate)
    }
    public func catalog(book: SourceBookKey) throws -> SourceCatalog? {
        try transaction { try catalogIndex(book: book)?.catalog }
    }

    /// Only called within a transaction. A small per-record version lookup avoids reading a
    /// whole catalog after unrelated chapter/anchor writes, including on another connection.
    private func catalogIndex(book: SourceBookKey) throws -> CatalogIndex? {
        let fields = try ["catalog", scopeKey(book.scope), book.bookID]
        let versionQuery = try prepare("SELECT record_version FROM records WHERE namespace=? AND scope=? AND key=?", strings: fields)
        defer { sqlite3_finalize(versionQuery) }
        let version: String
        switch sqlite3_step(versionQuery) {
        case SQLITE_DONE: removeCatalogIndex(book); return nil
        case SQLITE_ROW: version = string(versionQuery, column: 0)
        default: throw databaseError()
        }
        guard !version.isEmpty else { throw SourceDomainError(.invalidData, "Catalog record version is missing") }
        if let cached = catalogCache[book], cached.recordVersion == version {
            catalogOrder.removeAll { $0 == book }; catalogOrder.append(book)
            return cached
        }
        removeCatalogIndex(book)
        let query = try prepare("SELECT payload FROM records WHERE namespace=? AND scope=? AND key=?", strings: fields)
        defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_ROW else { throw databaseError() }
        let payload = data(query, column: 0)
        var catalog = try SourceCoding.decode(SourceCatalog.self, from: payload)
        catalogDecodes += 1
        guard catalog.identity.scope == book.scope, catalog.book.id == book.bookID else {
            throw SourceDomainError(.invalidData, "Corrupt catalog identity")
        }
        let fingerprint = SourceCoding.digest(try SourceCoding.encode(catalog))
        catalog.archiveDigest = fingerprint
        var references: [String: SourceWire.SourceRef] = [:]
        references.reserveCapacity(catalog.chapters.count)
        for chapter in catalog.chapters {
            guard references.updateValue(chapter.ref, forKey: chapter.ref.id) == nil else {
                throw SourceDomainError(.invalidData, "Repeated chapter identity in stored catalog")
            }
        }
        let index = CatalogIndex(catalog: catalog, recordVersion: version, digest: fingerprint,
                                 references: references, encodedBytes: payload.count)
        if catalogCacheLimits.maximumCatalogs > 0,
           index.references.count <= catalogCacheLimits.maximumChapters,
           index.encodedBytes <= catalogCacheLimits.maximumEncodedBytes {
            while !catalogOrder.isEmpty {
                let usage = catalogCacheStatistics()
                if usage.catalogs < catalogCacheLimits.maximumCatalogs &&
                    usage.chapters + index.references.count <= catalogCacheLimits.maximumChapters &&
                    usage.encodedBytes + index.encodedBytes <= catalogCacheLimits.maximumEncodedBytes { break }
                removeCatalogIndex(catalogOrder[0])
            }
            catalogCache[book] = index; catalogOrder.append(book)
        }
        return index
    }
    private func removeCatalogIndex(_ key: SourceBookKey) {
        catalogCache.removeValue(forKey: key); catalogOrder.removeAll { $0 == key }
    }
    /// May be called on memory pressure; it never removes persisted catalogs or chapters.
    public func clearCatalogMemoryCache() { catalogCache.removeAll(); catalogOrder.removeAll() }
    func catalogCacheStatistics() -> SourceCatalogCacheStatistics {
        .init(catalogs: catalogCache.count, chapters: catalogCache.values.reduce(0) { $0 + $1.references.count },
              encodedBytes: catalogCache.values.reduce(0) { $0 + $1.encodedBytes }, decodes: catalogDecodes)
    }
    @discardableResult
    public func saveCatalog(_ value: SourceCatalog, gate: SourceCommitGate? = nil) throws -> SourceCatalog {
        try transaction(gate: gate) {
            let key = try SourceBookKey(scope: value.identity.scope, bookID: value.book.id)
            let previous = try catalogIndex(book: key)?.catalog
            var saved = value
            if let previous, let revision = value.revision, !revision.isEmpty,
               previous.identity == value.identity, previous.book == value.book,
               previous.revision == revision, previous.chapters == value.chapters,
               let epoch = previous.cacheEpoch {
                saved.cacheEpoch = epoch
            } else { saved.cacheEpoch = UUID() }
            try put("catalog", scope: scopeKey(key.scope), key: key.bookID, value: saved)
            guard let persisted = try catalogIndex(book: key)?.catalog else { throw databaseError() }
            return persisted
        }
    }

    public func chapterStorageUsage() throws -> SourceChapterStorageUsage {
        let query = try prepare("SELECT cache_bytes,cache_count,offline_bytes,offline_count,cache_limit,offline_limit FROM chapter_usage WHERE id=1", strings: [])
        defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_ROW else { throw databaseError() }
        let values = (0..<6).map { Int(sqlite3_column_int64(query, Int32($0))) }
        guard values.allSatisfy({ $0 >= 0 }) else { throw SourceDomainError(.invalidData, "Corrupt chapter storage accounting") }
        return .init(readingCacheBytes: values[0], readingCacheCount: values[1], offlineBytes: values[2], offlineCount: values[3],
                     limits: .init(readingCacheBytes: values[4], offlineBytes: values[5]))
    }
    public func setChapterStorageLimits(_ limits: SourceChapterStorageLimits) throws {
        try transaction {
            let usage = try chapterStorageUsage()
            guard usage.offlineBytes <= limits.offlineBytes else {
                throw SourceDomainError(.resourceLimit, "离线正文已超过所选上限，请先移除部分下载。")
            }
            let update = try prepare("UPDATE chapter_usage SET cache_limit=?,offline_limit=? WHERE id=1",
                                     strings: [String(limits.readingCacheBytes), String(limits.offlineBytes)])
            defer { sqlite3_finalize(update) }
            try done(update)
            try trimReadingCache()
        }
    }
    /// User-requested removal also invalidates pending fetches, so late results cannot refill it.
    @discardableResult
    public func removeChapterStorage(_ selection: SourceChapterStorageRemoval) throws -> Int {
        try transaction {
            let retained = selection == .offlineDownloads ? "1" : "0"
            let deletion = try prepare("DELETE FROM records WHERE namespace='chapter' AND (scope,key) IN (SELECT scope,key FROM chapter_storage WHERE retained=?)", strings: [retained])
            defer { sqlite3_finalize(deletion) }
            try done(deletion)
            let count = Int(sqlite3_changes(handle))
            try Self.execute(handle, "UPDATE chapter_usage SET generation=lower(hex(randomblob(16))) WHERE id=1")
            return count
        }
    }
    private func storageGeneration() throws -> String {
        let query = try prepare("SELECT generation FROM chapter_usage WHERE id=1", strings: [])
        defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_ROW else { throw databaseError() }
        return string(query, column: 0)
    }
    private func chapterStorage(_ key: SourceChapterKey) throws -> (bytes: Int, retained: Bool)? {
        let query = try prepare("SELECT bytes,retained FROM chapter_storage WHERE scope=? AND key=?", strings: [scopeKey(key.book.scope), chapterKey(key)])
        defer { sqlite3_finalize(query) }
        switch sqlite3_step(query) {
        case SQLITE_DONE: return nil
        case SQLITE_ROW: return (Int(sqlite3_column_int64(query, 0)), sqlite3_column_int(query, 1) != 0)
        default: throw databaseError()
        }
    }
    private func touchChapter(_ key: SourceChapterKey, retainOffline: Bool = false) throws {
        guard let stored = try chapterStorage(key) else { throw SourceDomainError(.invalidData, "Chapter storage metadata is missing") }
        if retainOffline && !stored.retained {
            let usage = try chapterStorageUsage()
            guard usage.offlineBytes + stored.bytes <= usage.limits.offlineBytes else {
                throw SourceDomainError(.resourceLimit, "离线正文空间已满，请在缓存与下载中清理后重试。")
            }
        }
        // prepare(strings:) binds text; scalar MAX has no column affinity for parameters.
        // Cast before comparing so touching a download never demotes its retention flag.
        try Self.execute(handle, "UPDATE chapter_usage SET access_clock=access_clock+1 WHERE id=1")
        let update = try prepare("UPDATE chapter_storage SET last_access=(SELECT access_clock FROM chapter_usage WHERE id=1),retained=MAX(retained,CAST(? AS INTEGER)) WHERE scope=? AND key=?",
                                 strings: [retainOffline ? "1" : "0", scopeKey(key.book.scope), chapterKey(key)])
        defer { sqlite3_finalize(update) }
        try done(update)
    }
    private func persistChapter(_ value: SourceCachedChapter, retainOffline: Bool) throws {
        let previous = try chapterStorage(value.key)
        let retained = retainOffline || previous?.retained == true
        let payload = try SourceCoding.encode(value)
        let usage = try chapterStorageUsage()
        if retained {
            let oldOfflineBytes = previous.flatMap { $0.retained ? $0.bytes : nil } ?? 0
            let growth = payload.count - oldOfflineBytes
            guard growth <= 0 || usage.offlineBytes + growth <= usage.limits.offlineBytes else {
                throw SourceDomainError(.resourceLimit, "离线正文空间已满，请在缓存与下载中清理后重试。")
            }
        } else {
            guard payload.count <= usage.limits.readingCacheBytes else {
                throw SourceDomainError(.resourceLimit, "本章超过阅读缓存上限，请提高上限后重试。")
            }
        }
        try putPayload("chapter", scope: scopeKey(value.key.book.scope), key: chapterKey(value.key), payload: payload)
        let update = try prepare("UPDATE chapter_storage SET retained=? WHERE scope=? AND key=?",
                                 strings: [retained ? "1" : "0", scopeKey(value.key.book.scope), chapterKey(value.key)])
        defer { sqlite3_finalize(update) }
        try done(update)
        try touchChapter(value.key)
        try trimReadingCache(protecting: value.key)
    }
    private func trimReadingCache(protecting key: SourceChapterKey? = nil) throws {
        while true {
            try Task.checkCancellation()
            let usage = try chapterStorageUsage()
            if usage.readingCacheBytes <= usage.limits.readingCacheBytes { return }
            let fields = try key.map { try [scopeKey($0.book.scope), chapterKey($0)] } ?? []
            let excluded = key == nil ? "" : " AND NOT(scope=? AND key=?)"
            let candidate = try prepare("SELECT scope,key FROM chapter_storage WHERE retained=0" + excluded + " ORDER BY last_access,scope,key LIMIT 1", strings: fields)
            let row: (String, String)
            if sqlite3_step(candidate) == SQLITE_ROW { row = (string(candidate, column: 0), string(candidate, column: 1)) }
            else { sqlite3_finalize(candidate); throw SourceDomainError(.invalidData, "Cannot reconcile chapter cache budget") }
            sqlite3_finalize(candidate)
            let deletion = try prepare("DELETE FROM records WHERE namespace='chapter' AND scope=? AND key=?", strings: [row.0, row.1])
            defer { sqlite3_finalize(deletion) }
            try done(deletion)
            guard sqlite3_changes(handle) == 1 else { throw SourceDomainError(.invalidData, "Orphaned chapter storage metadata") }
        }
    }

    /// Without an expected request this is a diagnostic/cache lookup. Production online reads
    /// use prepareChapter so request validation and cache lookup share the same transaction.
    public func chapter(_ key: SourceChapterKey, identity: SourceExecutionIdentity, allowPreviousExtraction: Bool = false, retainOffline: Bool = false, gate: SourceCommitGate? = nil) throws -> SourceCachedChapter? {
        guard key.book.scope == identity.scope else { throw SourceDomainError(.invalidInput, "Cache scope mismatch") }
        return try transaction(gate: gate) {
            guard let cached = try storedChapter(key) else { return nil }
            if !allowPreviousExtraction {
                guard cached.identity == identity, let provenance = cached.provenance,
                      try matchesCatalog(provenance, identity: identity, index: catalogIndex(book: key.book)) else { return nil }
            }
            let normalized = try normalizeCachedChapter(cached)
            try touchChapter(key, retainOffline: retainOffline)
            return normalized
        }
    }

    func prepareChapter(identity: SourceExecutionIdentity, book: SourceWire.SourceRef, chapter: SourceWire.SourceRef,
                        expectedCatalog: SourceCatalog?, reload: Bool, retainOffline: Bool = false, gate: SourceCommitGate) throws -> SourceChapterPreparation {
        let key = try SourceChapterKey(book: .init(scope: identity.scope, bookID: book.id), chapterID: chapter.id)
        return try transaction(gate: gate) {
            let current = try catalogIndex(book: key.book)
            if let expectedCatalog {
                let expectedDigest = try expectedCatalog.archiveDigest ?? SourceCoding.digest(SourceCoding.encode(expectedCatalog))
                guard expectedDigest == current?.digest else {
                    throw SourceDomainError(.catalogChanged, "目录已更新，请返回书籍详情重新打开章节。")
                }
            }
            let provenance = SourceChapterProvenance(book: book, chapter: chapter, catalogEpoch: current?.epoch)
            guard matchesCatalog(provenance, identity: identity, index: current) else {
                throw SourceDomainError(.catalogChanged, "书源、目录或章节引用已改变，请刷新目录后重试。")
            }
            let cached = try storedChapter(key)
            if !reload, let cached, cached.identity == identity, cached.provenance == provenance {
                let normalized = try normalizeCachedChapter(cached)
                try touchChapter(key, retainOffline: retainOffline)
                return .cached(normalized)
            }
            return .fetch(SourceChapterRequest(key: key, identity: identity, provenance: provenance,
                                               catalogDigest: current?.digest, previousCacheDigest: try digest(cached),
                                               retainOffline: retainOffline, storageGeneration: try storageGeneration()))
        }
    }

    /// Compare the directory AND the previously observed cache in one SQLite transaction.
    /// A response captured before another connection's commit cannot overwrite that commit.
    func saveChapter(_ value: SourceCachedChapter, request: SourceChapterRequest, gate: SourceCommitGate) throws {
        guard value.key == request.key, value.identity == request.identity, value.provenance == request.provenance,
              value.key.book.scope == value.identity.scope else { throw SourceDomainError(.invalidInput, "Chapter request identity mismatch") }
        try transaction(gate: gate) {
            guard try storageGeneration() == request.storageGeneration else {
                throw SourceDomainError(.stale, "正文存储已被清理，请重新打开章节。")
            }
            guard try catalogIndex(book: value.key.book)?.digest == request.catalogDigest else {
                throw SourceDomainError(.catalogChanged, "读取期间目录已更新，请重新打开章节。")
            }
            guard try digest(storedChapter(value.key)) == request.previousCacheDigest else {
                throw SourceDomainError(.stale, "章节缓存已由另一读取更新，请重试。")
            }
            try persistChapter(value, retainOffline: request.retainOffline)
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
    private func matchesCatalog(_ provenance: SourceChapterProvenance, identity: SourceExecutionIdentity, index: CatalogIndex?) -> Bool {
        guard let index else { return provenance.catalogEpoch == nil }
        return index.catalog.identity == identity && index.catalog.book == provenance.book && index.epoch == provenance.catalogEpoch &&
            index.references[provenance.chapter.id] == provenance.chapter
    }
    private func normalizeCachedChapter(_ value: SourceCachedChapter) throws -> SourceCachedChapter {
        guard value.document.normalizationVersion != ChapterDocument.currentVersion else { return value }
        let normalized = SourceCachedChapter(key: value.key, identity: value.identity, content: value.content,
            document: try ChapterNormalizer.normalize(value.content), storedAt: value.storedAt, provenance: value.provenance)
        do { try persistChapter(normalized, retainOffline: false) }
        catch let error as SourceDomainError where error.code == .resourceLimit {
            // Reading preserved raw content remains possible even when an upgraded document
            // cannot fit the current quota. Retry persistence after space becomes available.
        }
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
        try putPayload(namespace, scope: scope, key: key, payload: SourceCoding.encode(value), gate: gate)
    }
    private func putPayload(_ namespace: String, scope: String, key: String, payload: Data, gate: SourceCommitGate? = nil) throws {
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
