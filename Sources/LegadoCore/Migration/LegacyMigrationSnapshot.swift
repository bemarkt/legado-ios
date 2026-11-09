import Foundation
import CryptoKit
import SQLite3

/// Private, local recovery material. It may contain credentials and must never be exported as a source.
public struct LegacyMigrationManifest: Codable, Sendable, Equatable {
    public struct File: Codable, Sendable, Equatable {
        public let relativePath: String
        public let bytes: Int64
        public let sha256: String
    }
    public let version: Int
    public let id: UUID
    public let requestDigest: String
    public let attempt: String
    public let schemaVersion: Int
    public let tables: [String: Int64]
    public let files: [File]
    public let missingExternalDirectories: [String]
    public let createdAt: Date
    public let missingExternalFiles: [String]?
}

/// Copy-first snapshot: SQLite's online backup includes committed WAL data; the source is opened read-only.
/// A ready manifest is published only after every copied byte and database integrity check succeeds.
public enum LegacyMigrationSnapshot {
    public enum Checkpoint: String, Sendable { case databaseCopied, externalFileCopied, beforePublish, published }
    private struct Request: Codable, Equatable {
        let version: Int
        let database: String
        let external: [String: String]
        let defaultsDigest: String?
        let files: [String: String]?
    }
    public static func capture(databaseURL: URL, externalDirectories: [String: URL] = [:], externalFiles: [String: URL] = [:], defaults: Data? = nil,
                               destination: URL, maximumBytes: Int64 = 8 * 1024 * 1024 * 1024,
                               checkpoint: @Sendable (Checkpoint) throws -> Void = { _ in }) throws -> LegacyMigrationManifest {
        try Task.checkCancellation()
        let manager = FileManager.default
        let source = databaseURL.standardizedFileURL.resolvingSymlinksInPath(), target = destination.standardizedFileURL.resolvingSymlinksInPath()
        guard databaseURL.isFileURL, destination.isFileURL, source != target, maximumBytes > 0,
              externalDirectories.count <= 16, externalDirectories.keys.allSatisfy(validLabel),
              externalFiles.count <= 64, externalFiles.keys.allSatisfy(validLabel),
              externalFiles.values.allSatisfy({ $0.isFileURL && !contains(target, $0.standardizedFileURL.resolvingSymlinksInPath()) }),
              externalDirectories.values.allSatisfy({ $0.isFileURL && !contains($0.standardizedFileURL.resolvingSymlinksInPath(), target) && !contains(target, $0.standardizedFileURL.resolvingSymlinksInPath()) }),
              !contains(target, source) else { throw SourceDomainError(.invalidInput, "迁移副本必须使用独立目录，不能覆盖旧数据。") }
        let request = Request(version: 1, database: SourceCoding.digest(Data(source.path.utf8)),
                              external: externalDirectories.mapValues { SourceCoding.digest(Data($0.standardizedFileURL.resolvingSymlinksInPath().path.utf8)) },
                              defaultsDigest: defaults.map(SourceCoding.digest),
                              files: externalFiles.isEmpty ? nil : externalFiles.mapValues { SourceCoding.digest(Data($0.standardizedFileURL.resolvingSymlinksInPath().path.utf8)) })
        let requestData = try SourceCoding.encode(request), requestDigest = SourceCoding.digest(requestData)
        let marker = target.appendingPathComponent("request.json"), ready = target.appendingPathComponent("manifest.json")
        if manager.fileExists(atPath: target.path) {
            guard manager.fileExists(atPath: marker.path), try SourceCoding.decode(Request.self, from: Data(contentsOf: marker)) == request else {
                throw SourceDomainError(.storageConflict, "目标目录不属于此迁移任务，请选择新的副本目录。")
            }
            if manager.fileExists(atPath: ready.path) { return try verify(at: target, expectedRequestDigest: requestDigest) }
        } else {
            try manager.createDirectory(at: target, withIntermediateDirectories: true)
            try requestData.write(to: marker, options: .atomic)
        }
        let attempt = UUID().uuidString
        let directory = target.appendingPathComponent(attempt, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        // Interrupted attempts remain as private recovery material; a retry never appends to a partial database.
        let database = directory.appendingPathComponent("legacy.sqlite3")
        let input = try open(source, writable: false); defer { sqlite3_close(input) }
        let sourceVersion = try dataVersion(input)
        let inventory = try backup(input: input, destination: database, maximumBytes: maximumBytes)
        try finishStandaloneDatabase(database)
        try checkpoint(.databaseCopied); try Task.checkCancellation()
        var files = [try file(database, relative: "legacy.sqlite3")]
        var bytes = files[0].bytes, missing: [String] = [], missingFiles: [String] = []
        var directoryChecks: [(URL, [String: String])] = [], fileChecks: [(URL, String)] = []
        for name in externalDirectories.keys.sorted() {
            let input = externalDirectories[name]!.standardizedFileURL.resolvingSymlinksInPath()
            guard manager.fileExists(atPath: input.path) else { missing.append(name); continue }
            let before = try fileInventory(input)
            directoryChecks.append((input, before))
            for relative in before.keys.sorted() {
                try Task.checkCancellation()
                guard files.count < 250_000 else { throw SourceDomainError(.resourceLimit, "迁移文件数量超过限制。") }
                let origin = input.appendingPathComponent(relative), output = directory.appendingPathComponent("external/" + name + "/" + relative)
                try manager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                let copied = try copy(origin, to: output, remaining: maximumBytes - bytes)
                let record = LegacyMigrationManifest.File(relativePath: "external/" + name + "/" + relative, bytes: copied.bytes, sha256: copied.sha256)
                files.append(record); bytes += record.bytes
                try checkpoint(.externalFileCopied)
            }
            guard try fileInventory(input) == before else { throw SourceDomainError(.stale, "复制期间外部文件已改变，请停止下载或编辑后重试。") }
        }
        for name in externalFiles.keys.sorted() {
            let input = externalFiles[name]!.standardizedFileURL.resolvingSymlinksInPath()
            guard manager.fileExists(atPath: input.path) else { missingFiles.append(name); continue }
            guard try input.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw SourceDomainError(.invalidInput, "额外迁移文件必须是普通文件。")
            }
            let relative = "files/" + name, output = directory.appendingPathComponent(relative)
            try manager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            let copied = try copy(input, to: output, remaining: maximumBytes - bytes)
            files.append(.init(relativePath: relative, bytes: copied.bytes, sha256: copied.sha256)); bytes += copied.bytes
            fileChecks.append((input, copied.sha256)); try checkpoint(.externalFileCopied)
        }
        if let defaults {
            guard defaults.count <= 16_777_216, bytes + Int64(defaults.count) <= maximumBytes else { throw SourceDomainError(.resourceLimit, "设置备份超过容量限制。") }
            let url = directory.appendingPathComponent("defaults.plist")
            try defaults.write(to: url, options: .atomic)
            files.append(try file(url, relative: "defaults.plist"))
        }
        let manifest = LegacyMigrationManifest(version: 1, id: UUID(), requestDigest: requestDigest, attempt: attempt,
            schemaVersion: inventory.version, tables: inventory.tables, files: files.sorted { $0.relativePath < $1.relativePath },
            missingExternalDirectories: missing, createdAt: Date(), missingExternalFiles: externalFiles.isEmpty ? nil : missingFiles)
        try verifyFiles(manifest, root: directory)
        try checkpoint(.beforePublish); try Task.checkCancellation()
        for (directory, before) in directoryChecks where try fileInventory(directory) != before {
            throw SourceDomainError(.stale, "发布前外部数据已改变，请停止写入后重试。")
        }
        for (url, digest) in fileChecks where try file(url, relative: "").sha256 != digest {
            throw SourceDomainError(.stale, "发布前外部文件已改变，请停止写入后重试。")
        }
        guard try dataVersion(input) == sourceVersion else { throw SourceDomainError(.stale, "复制期间旧库发生写入，请停止书架更新或下载后重试。") }
        try SourceCoding.encode(manifest).write(to: ready, options: .atomic)
        try checkpoint(.published)
        return manifest
    }

    public static func verify(at destination: URL, expectedRequestDigest: String? = nil) throws -> LegacyMigrationManifest {
        let target = destination.standardizedFileURL.resolvingSymlinksInPath()
        let data = try Data(contentsOf: target.appendingPathComponent("manifest.json"))
        guard data.count <= 64 * 1024 * 1024 else { throw SourceDomainError(.resourceLimit, "迁移记录超过容量限制。") }
        let manifest = try SourceCoding.decode(LegacyMigrationManifest.self, from: data)
        guard manifest.version == 1, UUID(uuidString: manifest.attempt) != nil,
              expectedRequestDigest == nil || manifest.requestDigest == expectedRequestDigest else { throw SourceDomainError(.invalidData, "迁移记录不匹配。") }
        let marker = try Data(contentsOf: target.appendingPathComponent("request.json"))
        guard SourceCoding.digest(marker) == manifest.requestDigest else { throw SourceDomainError(.invalidData, "迁移来源记录已改变。") }
        let directory = target.appendingPathComponent(manifest.attempt)
        try verifyFiles(manifest, root: directory)
        let inventory = try inspectDatabase(directory.appendingPathComponent("legacy.sqlite3"))
        guard inventory.version == manifest.schemaVersion, inventory.tables == manifest.tables else { throw SourceDomainError(.invalidData, "副本表数量或版本不匹配。") }
        return manifest
    }
    public static func databaseURL(at destination: URL, manifest: LegacyMigrationManifest) -> URL {
        destination.appendingPathComponent(manifest.attempt).appendingPathComponent("legacy.sqlite3")
    }
    private static func validLabel(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64 && value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
    }
    private static func contains(_ directory: URL, _ file: URL) -> Bool { file.path == directory.path || file.path.hasPrefix(directory.path + "/") }
    static func fileInventory(_ directory: URL) throws -> [String: String] {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath()
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw SourceDomainError(.invalidInput, "外部数据必须是目录。") }
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, error in enumerationError = error; return false }) else {
            throw SourceDomainError(.unavailable, "无法读取外部文件目录。")
        }
        var result: [String: String] = [:]
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true else { throw SourceDomainError(.invalidInput, "迁移外部目录包含符号链接，请明确选择实际数据目录。") }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true, result.count < 250_000 else { throw SourceDomainError(.resourceLimit, "迁移外部目录包含非普通文件或文件过多。") }
            // Foundation may enumerate /var through /private/var on Apple platforms.
            // Compare resolved path components before deriving a relative path.
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
            let parent = root.pathComponents, child = resolved.pathComponents
            guard child.count > parent.count, Array(child.prefix(parent.count)) == parent else {
                throw SourceDomainError(.invalidData, "迁移文件路径超出源目录。")
            }
            let relative = child.dropFirst(parent.count).joined(separator: "/")
            result[relative] = "\(values.fileSize ?? -1):\(values.contentModificationDate?.timeIntervalSince1970 ?? -1)"
        }
        if let enumerationError { throw enumerationError }
        return result
    }
    private static func file(_ url: URL, relative: String) throws -> LegacyMigrationManifest.File {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256(), bytes: Int64 = 0
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation(); bytes += Int64(chunk.count); hash.update(data: chunk)
        }
        return .init(relativePath: relative, bytes: bytes, sha256: hash.finalize().map { String(format: "%02x", $0) }.joined())
    }
    private static func copy(_ source: URL, to destination: URL, remaining: Int64) throws -> LegacyMigrationManifest.File {
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
        guard size >= 0, Int64(size) <= remaining else { throw SourceDomainError(.resourceLimit, "迁移副本超过容量预算。") }
        let expected = try file(source, relative: "")
        guard expected.bytes <= remaining else { throw SourceDomainError(.resourceLimit, "迁移副本超过容量预算。") }
        try FileManager.default.copyItem(at: source, to: destination)
        let actual = try file(destination, relative: "")
        let after = try file(source, relative: "")
        guard actual.bytes == expected.bytes, actual.sha256 == expected.sha256, after.sha256 == expected.sha256 else {
            throw SourceDomainError(.stale, "复制期间文件内容发生变化，请重试。")
        }
        return actual
    }
    private static func verifyFiles(_ manifest: LegacyMigrationManifest, root: URL) throws {
        guard manifest.files.count <= 250_000, Set(manifest.files.map(\.relativePath)).count == manifest.files.count else { throw SourceDomainError(.invalidData, "迁移文件清单重复或过大。") }
        let actual = try fileInventory(root)
        guard Set(actual.keys) == Set(manifest.files.map(\.relativePath)), actual["legacy.sqlite3"] != nil else { throw SourceDomainError(.invalidData, "迁移副本文件数量不符（实际 \(actual.count)，清单 \(manifest.files.count)，主库 \(actual["legacy.sqlite3"] != nil)）。") }
        for expected in manifest.files {
            let url = root.appendingPathComponent(expected.relativePath).standardizedFileURL.resolvingSymlinksInPath()
            guard !expected.relativePath.hasPrefix("/"), contains(root, url), !expected.relativePath.split(separator: "/").contains("..") else {
                throw SourceDomainError(.invalidData, "迁移文件路径超出副本目录。")
            }
            let actual = try file(url, relative: expected.relativePath)
            guard actual == expected else { throw SourceDomainError(.invalidData, "迁移副本校验失败，请使用完整的恢复材料。") }
        }
    }
    private struct Inventory { let version: Int; let tables: [String: Int64] }
    private static func open(_ url: URL, writable: Bool) throws -> OpaquePointer {
        var handle: OpaquePointer?
        let flags = (writable ? SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE : SQLITE_OPEN_READONLY) | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw SourceDomainError(.unavailable, "无法打开迁移数据库。")
        }
        sqlite3_busy_timeout(handle, 100)
        _ = sqlite3_exec(handle, "PRAGMA trusted_schema=OFF", nil, nil, nil)
        return handle
    }
    private static func backup(input: OpaquePointer, destination: URL, maximumBytes: Int64) throws -> Inventory {
        let output = try open(destination, writable: true); defer { sqlite3_close(output) }
        // Finish the SQLite backup exactly once, including failed or cancelled copies.
        guard let backup = sqlite3_backup_init(output, "main", input, "main") else { throw SourceDomainError(.unavailable, "无法创建数据库副本。") }
        var finished = false
        defer { if !finished { sqlite3_backup_finish(backup) } }
        let deadline = ContinuousClock.now.advanced(by: .seconds(120))
        while true {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw SourceDomainError(.timeout, "数据库持续繁忙，请停止写入后重试。") }
            let result = sqlite3_backup_step(backup, 128)
            let bytes = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
            guard bytes <= maximumBytes else { throw SourceDomainError(.resourceLimit, "数据库副本超过容量预算。") }
            if result == SQLITE_DONE { break }
            if result == SQLITE_BUSY || result == SQLITE_LOCKED { Thread.sleep(forTimeInterval: 0.01); continue }
            guard result == SQLITE_OK else { throw SourceDomainError(.unavailable, "数据库副本写入失败，请检查空间后重试。") }
        }
        let result = sqlite3_backup_finish(backup); finished = true
        guard result == SQLITE_OK else { throw SourceDomainError(.unavailable, "数据库副本未完成。") }
        guard sqlite3_exec(output, "PRAGMA journal_mode=DELETE", nil, nil, nil) == SQLITE_OK else { throw SourceDomainError(.unavailable, "无法完成独立数据库快照。") }
        return try inspect(output)
    }
    /// Apple's SQLite may leave an orphan SHM file after backing up a WAL database.
    /// The writer is closed before this method; only a confirmed DELETE-mode copy may discard sidecars.
    private static func finishStandaloneDatabase(_ url: URL) throws {
        let handle = try open(url, writable: false)
        do {
            var query: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "PRAGMA journal_mode", -1, &query, nil) == SQLITE_OK, let query else {
                throw SourceDomainError(.invalidData, "无法确认副本日志模式。")
            }
            let step = sqlite3_step(query)
            let mode = sqlite3_column_text(query, 0).map { String(cString: $0) }
            sqlite3_finalize(query)
            guard step == SQLITE_ROW, mode == "delete" else { throw SourceDomainError(.invalidData, "数据库副本仍依赖外部日志。") }
            _ = try inspect(handle)
            guard sqlite3_close(handle) == SQLITE_OK else { throw SourceDomainError(.unavailable, "无法关闭副本验证连接。") }
        } catch { sqlite3_close(handle); throw error }
        let manager = FileManager.default
        let wal = URL(fileURLWithPath: url.path + "-wal")
        if manager.fileExists(atPath: wal.path) {
            let values = try wal.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, values.fileSize == 0 else {
                throw SourceDomainError(.invalidData, "副本仍有待处理日志，已保留所有文件。")
            }
            try manager.removeItem(at: wal)
        }
        let shm = URL(fileURLWithPath: url.path + "-shm")
        if manager.fileExists(atPath: shm.path) {
            let values = try shm.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { throw SourceDomainError(.invalidData, "副本共享内存文件类型无效。") }
            try manager.removeItem(at: shm)
        }
        _ = try inspectDatabase(url)
        guard !manager.fileExists(atPath: wal.path), !manager.fileExists(atPath: shm.path) else {
            throw SourceDomainError(.invalidData, "独立副本重新打开后仍产生日志。")
        }
    }
    private static func dataVersion(_ handle: OpaquePointer) throws -> Int64 {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "PRAGMA data_version", -1, &statement, nil) == SQLITE_OK, let statement else {
            throw SourceDomainError(.unavailable, "无法确认旧库是否正在写入。")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw SourceDomainError(.unavailable, "旧库写入状态不可用。") }
        return sqlite3_column_int64(statement, 0)
    }
    private static func inspectDatabase(_ url: URL) throws -> Inventory {
        let handle = try open(url, writable: false); defer { sqlite3_close(handle) }
        return try inspect(handle)
    }
    private static func inspect(_ handle: OpaquePointer) throws -> Inventory {
        func strings(_ sql: String) throws -> [String] {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw SourceDomainError(.invalidData, "无法读取旧库结构。") }
            defer { sqlite3_finalize(statement) }
            var values: [String] = [], step = sqlite3_step(statement)
            while step == SQLITE_ROW {
                if let text = sqlite3_column_text(statement, 0) { values.append(String(cString: text)) }
                step = sqlite3_step(statement)
            }
            guard step == SQLITE_DONE else { throw SourceDomainError(.invalidData, "旧库读取不完整。") }
            return values
        }
        guard try strings("PRAGMA integrity_check") == ["ok"], try strings("PRAGMA foreign_key_check").isEmpty else {
            throw SourceDomainError(.invalidData, "旧库完整性或关联检查失败，已保留原数据，请先恢复有效备份。")
        }
        let version = Int(try strings("PRAGMA user_version").first ?? "") ?? -1
        guard (1...Int(LegadoDatabase.schemaVersion)).contains(version) else { throw SourceDomainError(.invalidData, "不支持此旧库版本。") }
        var tables: [String: Int64] = [:]
        for table in try strings("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name") {
            let quoted = table.replacingOccurrences(of: "\"", with: "\"\"")
            guard let count = Int64(try strings("SELECT COUNT(*) FROM \"" + quoted + "\"").first ?? "") else {
                throw SourceDomainError(.invalidData, "旧库表计数失败。")
            }
            tables[table] = count
        }
        return Inventory(version: version, tables: tables)
    }
}
