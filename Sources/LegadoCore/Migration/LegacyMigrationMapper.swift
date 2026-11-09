import Foundation
import CryptoKit
import SQLite3

/// Builds an isolated, versioned draft. Original data and any active native library remain untouched.
/// A ready report is the sole publication point. A failed attempt is preserved; retries build a fresh draft.
public enum LegacyMigrationMapper {
    public enum Checkpoint: String, Sendable { case sourcesMapped, booksMapped, cachesMapped, beforePublish, published }
    private struct Request: Codable, Equatable { let version: Int; let snapshotDigest: String }
    public static func prepare(snapshotAt snapshotURL: URL, destination: URL,
                               checkpoint: @Sendable (Checkpoint) throws -> Void = { _ in }) async throws -> LegacyMigrationReport {
        let snapshot = try LegacyMigrationSnapshot.verify(at: snapshotURL)
        let snapshotDigest = SourceCoding.digest(try SourceCoding.encode(snapshot))
        let target = destination.standardizedFileURL.resolvingSymlinksInPath()
        let original = snapshotURL.standardizedFileURL.resolvingSymlinksInPath()
        guard target.isFileURL, !overlaps(target, original) else { throw SourceDomainError(.invalidInput, "映射目录必须独立于恢复副本。") }
        let manager = FileManager.default, marker = target.appendingPathComponent("migration-request.json")
        let existed = manager.fileExists(atPath: target.path)
        if existed, !manager.fileExists(atPath: marker.path), !(try manager.contentsOfDirectory(atPath: target.path)).allSatisfy({ ["migration-lock.sqlite3", "migration-lock.sqlite3-journal", "migration-lock.sqlite3-wal", "migration-lock.sqlite3-shm"].contains($0) }) {
            throw SourceDomainError(.storageConflict, "目标目录不属于此迁移，请使用新的目录。")
        }
        try manager.createDirectory(at: target, withIntermediateDirectories: true)
        let lease = try Lease(url: target.appendingPathComponent("migration-lock.sqlite3"))
        defer { lease.release() }
        let request = Request(version: 1, snapshotDigest: snapshotDigest)
        if manager.fileExists(atPath: marker.path) {
            guard try SourceCoding.decode(Request.self, from: Data(contentsOf: marker)) == request else {
                throw SourceDomainError(.storageConflict, "迁移输入已改变，请创建新的迁移任务。")
            }
        } else { try SourceCoding.encode(request).write(to: marker, options: .atomic) }
        if manager.fileExists(atPath: target.appendingPathComponent("report.json").path) {
            return try verify(at: target, snapshotAt: original)
        }
        let attempt = UUID().uuidString, draft = target.appendingPathComponent(attempt, isDirectory: true)
        try manager.createDirectory(at: draft, withIntermediateDirectories: false)
        let archive = try SourceArchive(url: draft.appendingPathComponent("native.sqlite3"))
        let reader = try LegacyMigrationReader(url: LegacyMigrationSnapshot.databaseURL(at: original, manifest: snapshot), tables: Set(snapshot.tables.keys))
        var report = LegacyMigrationReport(version: 1, snapshotID: snapshot.id, snapshotDigest: snapshotDigest, attempt: attempt,
            tables: snapshot.tables.mapValues { .init(total: $0) }, records: [], sources: [], books: [], annotations: [], createdAt: snapshot.createdAt)
        var worker = Worker(snapshot: snapshot, sourceRoot: original.appendingPathComponent(snapshot.attempt), reader: reader, archive: archive, report: report)
        try await worker.sources(); try checkpoint(.sourcesMapped)
        try await worker.books(); try checkpoint(.booksMapped)
        try await worker.caches(); try await worker.positionsAndAnnotations(); try await worker.state(); try checkpoint(.cachesMapped)
        report = worker.report
        report.records = worker.outcomes.values.sorted { $0.id < $1.id }
        for row in report.records where report.tables[row.table] != nil {
            if row.disposition == .mapped { report.tables[row.table]!.mapped += 1 }
            if row.disposition == .needsReview { report.tables[row.table]!.needsReview += 1 }
        }
        guard report.tables.values.allSatisfy({ $0.retained >= 0 }) else { throw SourceDomainError(.invalidData, "迁移逐行计数不一致。") }
        try await archive.sealMigrationDraft()
        let fingerprint = try fingerprint(draft.appendingPathComponent("native.sqlite3"))
        report.archiveSHA256 = fingerprint.digest; report.archiveBytes = fingerprint.bytes
        // Detect changes to the immutable recovery material before publishing a usable draft.
        guard try LegacyMigrationSnapshot.verify(at: original) == snapshot else { throw SourceDomainError(.stale, "恢复副本已改变。") }
        try checkpoint(.beforePublish); try Task.checkCancellation()
        try SourceCoding.encode(report).write(to: target.appendingPathComponent("report.json"), options: .atomic)
        try checkpoint(.published)
        return report
    }
    public static func verify(at destination: URL, snapshotAt snapshotURL: URL) throws -> LegacyMigrationReport {
        let report = try SourceCoding.decode(LegacyMigrationReport.self, from: boundedData(destination.appendingPathComponent("report.json"), limit: 64 * 1024 * 1024))
        let snapshot = try LegacyMigrationSnapshot.verify(at: snapshotURL)
        let marker = try SourceCoding.decode(Request.self, from: boundedData(destination.appendingPathComponent("migration-request.json"), limit: 4096))
        guard report.version == 1, marker.version == 1, UUID(uuidString: report.attempt) != nil,
              report.snapshotID == snapshot.id, report.snapshotDigest == SourceCoding.digest(try SourceCoding.encode(snapshot)),
              marker.snapshotDigest == report.snapshotDigest,
              report.tables.mapValues(\.total) == snapshot.tables,
              report.tables.values.allSatisfy({ $0.mapped >= 0 && $0.needsReview >= 0 && $0.retained >= 0 }),
              Set(report.records.map(\.id)).count == report.records.count else { throw SourceDomainError(.invalidData, "迁移报告与恢复副本不一致。") }
        let fingerprint = try fingerprint(archiveURL(at: destination, report: report))
        guard fingerprint.digest == report.archiveSHA256, fingerprint.bytes == report.archiveBytes else {
            throw SourceDomainError(.invalidData, "迁移草稿已改变，不能继续采用。")
        }
        return report
    }
    public static func archiveURL(at destination: URL, report: LegacyMigrationReport) -> URL {
        destination.appendingPathComponent(report.attempt).appendingPathComponent("native.sqlite3")
    }
    /// Preview always gets a new writable copy. Inspecting it cannot change the verified migration draft.
    public static func makePreview(at destination: URL, snapshotAt snapshotURL: URL) throws -> URL {
        let report = try verify(at: destination, snapshotAt: snapshotURL)
        let directory = destination.appendingPathComponent("preview-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let target = directory.appendingPathComponent("native.sqlite3")
        try FileManager.default.copyItem(at: archiveURL(at: destination, report: report), to: target)
        guard try fingerprint(target).digest == report.archiveSHA256 else { throw SourceDomainError(.invalidData, "预览副本校验失败。") }
        return target
    }
    private static func overlaps(_ a: URL, _ b: URL) -> Bool {
        a.path == b.path || a.path.hasPrefix(b.path + "/") || b.path.hasPrefix(a.path + "/")
    }
    static func boundedData(_ url: URL, limit: Int) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? -1
        guard size >= 0, size <= limit else { throw SourceDomainError(.resourceLimit, "迁移文件超过读取上限。") }
        let data = try Data(contentsOf: url)
        guard data.count <= limit else { throw SourceDomainError(.resourceLimit, "迁移文件超过读取上限。") }
        return data
    }
    static func fingerprint(_ url: URL) throws -> (digest: String, bytes: Int64) {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var digest = SHA256(), count: Int64 = 0
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation(); count += Int64(data.count); digest.update(data: data)
        }
        return (digest.finalize().map { String(format: "%02x", $0) }.joined(), count)
    }
    private static func stableUUID(_ value: String) -> UUID {
        let hex = SourceCoding.digest(Data(value.utf8)), characters = Array(hex.prefix(32))
        let text = String(characters[0..<8]) + "-" + String(characters[8..<12]) + "-" + String(characters[12..<16]) + "-" + String(characters[16..<20]) + "-" + String(characters[20..<32])
        return UUID(uuidString: text)!
    }
    /// SQLite releases this exclusive writer lease even after SIGKILL; no stale sentinel blocks retries.
    private final class Lease: @unchecked Sendable {
        private var handle: OpaquePointer?
        init(url: URL) throws {
            var pointer: OpaquePointer?
            guard sqlite3_open_v2(url.path, &pointer, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let pointer else {
                if let pointer { sqlite3_close(pointer) }
                throw SourceDomainError(.unavailable, "无法创建迁移锁。")
            }
            guard sqlite3_exec(pointer, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
                sqlite3_close(pointer); throw SourceDomainError(.storageConflict, "此迁移正在进行，请等待当前任务结束。")
            }
            handle = pointer
        }
        func release() { if let handle { sqlite3_exec(handle, "ROLLBACK", nil, nil, nil); sqlite3_close(handle); self.handle = nil } }
        deinit { release() }
    }

    private struct Worker {
        let snapshot: LegacyMigrationManifest
        let sourceRoot: URL
        let reader: LegacyMigrationReader
        let archive: SourceArchive
        var report: LegacyMigrationReport
        var outcomes: [String: LegacyMigrationReport.Record] = [:]
        var sourceMap: [String: LegacyMigrationReport.Source] = [:]
        struct BookWork {
            let row: LegacyMigrationReader.Row
            let legacy: Book
            let native: SourceWire.SourceRef
            let identity: SourceExecutionIdentity
            let key: SourceBookKey
            let chapters: [String: SourceWire.Chapter]
            let legacyChapters: [Int: BookChapter]
            let reportIndex: Int
        }
        var bookMap: [String: BookWork] = [:]
        var cachedDocuments: [SourceChapterKey: Bool] = [:]
        mutating func record(_ table: String, _ row: LegacyMigrationReader.Row, _ disposition: LegacyMigrationReport.Disposition, _ reason: LegacyMigrationReport.Reason) throws {
            guard outcomes.count < 250_000 else { throw SourceDomainError(.resourceLimit, "迁移记录超过上限。") }
            let value = LegacyMigrationReport.Record(table: table, rowID: row.id, payloadDigest: row.digest, disposition: disposition, reason: reason)
            outcomes[value.id] = value
        }
        mutating func sources() async throws {
            var after: Int64?
            while true {
                let rows = try await reader.rows("book_sources", after: after)
                guard !rows.isEmpty else { break }; after = rows.last!.id
                for row in rows {
                    try Task.checkCancellation()
                    let document: LegadoSourceDocument
                    do {
                        guard let payload = row.payload, let text = String(data: payload, encoding: .utf8),
                              let parsed = try LegadoSourceDocument.inspect(text).first,
                              parsed.bookSource.id == row.fields["book_source_url"] else { throw SourceDomainError(.invalidData, "旧书源键不一致。") }
                        document = parsed
                    } catch {
                        try record("book_sources", row, .needsReview, .unsupportedSource); continue
                    }
                    let id = stableUUID(snapshot.id.uuidString + "source:" + document.bookSource.id)
                    let installation = try document.installation(id: id, origins: document.suggestedOrigins, createdAt: snapshot.createdAt, locallyModified: true)
                    try await archive.saveInstallation(installation)
                    let scope = try await archive.prepareMigrationAccount(id: stableUUID(id.uuidString + ":legacy-account"), installationID: id, createdAt: snapshot.createdAt)
                    let mapped = LegacyMigrationReport.Source(legacyID: document.bookSource.id, installation: installation, scope: scope,
                        enabled: document.bookSource.enabled, group: document.bookSource.bookSourceGroup)
                    report.sources.append(mapped); sourceMap[mapped.legacyID] = mapped
                    try record("book_sources", row, .mapped, .imported)
                }
            }
        }
        mutating func books() async throws {
            var after: Int64?
            while true {
                let rows = try await reader.rows("books", after: after)
                guard !rows.isEmpty else { break }; after = rows.last!.id
                for row in rows {
                    try Task.checkCancellation()
                    guard let book = try? row.decode(Book.self), !book.bookUrl.isEmpty,
                          book.bookUrl == row.fields["book_url"], !book.name.isEmpty else {
                        try record("books", row, .needsReview, .malformedRecord); continue
                    }
                    if book.origin == "local" { try record("books", row, .retained, .localFeature); continue }
                    guard let source = sourceMap[book.origin] else { try record("books", row, .needsReview, .missingSource); continue }
                    var chapterRows: [LegacyMigrationReader.Row] = [], cursor: Int64?
                    while true {
                        let batch = try await reader.rows("chapters", after: cursor, bookURL: book.bookUrl)
                        guard !batch.isEmpty else { break }; cursor = batch.last!.id; chapterRows += batch
                        guard chapterRows.count <= 100_000 else { throw SourceDomainError(.resourceLimit, "单本旧目录超过迁移上限。") }
                    }
                    var chapters: [BookChapter] = [], invalid = false
                    for item in chapterRows {
                        guard let chapter = try? item.decode(BookChapter.self), chapter.bookUrl == book.bookUrl,
                              chapter.url == item.fields["url"], String(chapter.index) == item.fields["chapter_index"] else {
                            try record("chapters", item, .needsReview, .malformedRecord); invalid = true; continue
                        }
                        chapters.append(chapter)
                    }
                    let refs: (book: SourceWire.SourceRef, chapters: [SourceWire.Chapter])
                    do {
                        guard !invalid else { throw SourceDomainError(.invalidData, "旧目录有损坏记录。") }
                        refs = try LegadoSourceProvider.migrationReferences(book: book, chapters: chapters, scope: source.scope)
                    } catch { try record("books", row, .needsReview, .invalidCatalog); continue }
                    let key = try SourceBookKey(scope: source.scope, bookID: refs.book.id)
                    let identity = try SourceExecutionIdentity(scope: source.scope, sourceDigest: source.installation.digest,
                        configuration: .object([:]), approvedOrigins: source.installation.origins)
                    let details = SourceWire.BookDetails(ref: refs.book, title: book.name, author: book.author,
                        cover: (book.customCoverUrl ?? book.coverUrl).map { .init(url: $0) }, description: book.customIntro ?? book.intro)
                    try await archive.saveBook(.init(key: key, details: details, addedAt: snapshot.createdAt))
                    _ = try await archive.saveCatalog(.init(identity: identity, book: refs.book, chapters: refs.chapters,
                        revision: "migration:" + snapshot.id.uuidString, fetchedAt: snapshot.createdAt))
                    let ordered = chapters.filter { !$0.isVolume }.sorted { $0.index < $1.index }
                    let byURL = Dictionary(uniqueKeysWithValues: zip(ordered.map(\.url), refs.chapters))
                    bookMap[book.bookUrl] = BookWork(row: row, legacy: book, native: refs.book, identity: identity, key: key,
                        chapters: byURL, legacyChapters: Dictionary(uniqueKeysWithValues: chapters.map { ($0.index, $0) }), reportIndex: report.books.count)
                    report.books.append(.init(legacyURL: book.bookUrl, key: key, title: book.name, order: book.order, group: book.group, chapterCount: refs.chapters.count))
                    try record("books", row, .mapped, .imported)
                    for item in chapterRows { try record("chapters", item, .mapped, .imported) }
                }
            }
        }
        struct CacheCandidate {
            let file: LegacyMigrationManifest.File
            let row: LegacyMigrationReader.Row
            let bookURL: String
            let chapterURL: String
        }
        mutating func caches() async throws {
            let files = snapshot.files.filter { $0.relativePath.hasPrefix("external/chapters/") }
            var candidates: [CacheCandidate] = [], counts: [String: Int] = [:]
            func key(_ book: String, _ chapter: String) -> String { SourceCoding.digest(Data((book + "\0" + chapter).utf8)) }
            for (index, file) in files.enumerated() {
                let row = LegacyMigrationReader.Row(id: Int64(index + 1), fields: [:], payload: nil)
                guard file.bytes <= Int64(ChapterContentCache.maximumEntryBytes),
                      let bytes = try? boundedData(sourceRoot.appendingPathComponent(file.relativePath), limit: ChapterContentCache.maximumEntryBytes),
                      let cached = try? SourceCoding.decode(CachedChapterContent.self, from: bytes) else {
                    try record("external/chapters", row, .needsReview, .malformedRecord); report.cacheFilesRetained += 1; continue
                }
                let candidate = CacheCandidate(file: file, row: row, bookURL: cached.bookURL, chapterURL: cached.chapterURL)
                candidates.append(candidate); counts[key(cached.bookURL, cached.chapterURL), default: 0] += 1
            }
            let ruleFile = sourceRoot.appendingPathComponent("files/replace-rules")
            let capturedRules: [ReplaceRule]?
            if snapshot.files.contains(where: { $0.relativePath == "files/replace-rules" }) {
                capturedRules = try? SourceCoding.decode([ReplaceRule].self, from: boundedData(ruleFile, limit: 16_777_216))
            } else if snapshot.missingExternalFiles?.contains("replace-rules") == true { capturedRules = [] }
            else { capturedRules = nil }
            for candidate in candidates {
                try Task.checkCancellation()
                guard counts[key(candidate.bookURL, candidate.chapterURL)] == 1 else {
                    try record("external/chapters", candidate.row, .needsReview, .ambiguousCache); report.cacheFilesRetained += 1; continue
                }
                guard let book = bookMap[candidate.bookURL], let chapter = book.chapters[candidate.chapterURL],
                      let oldChapter = book.legacyChapters.values.first(where: { $0.url == candidate.chapterURL }) else {
                    try record("external/chapters", candidate.row, .retained, .orphanedRecord); report.cacheFilesRetained += 1; continue
                }
                let data = try boundedData(sourceRoot.appendingPathComponent(candidate.file.relativePath), limit: ChapterContentCache.maximumEntryBytes)
                let cached = try SourceCoding.decode(CachedChapterContent.self, from: data)
                guard cached.sourceID == nil || cached.sourceID == book.legacy.origin else {
                    try record("external/chapters", candidate.row, .needsReview, .foreignCache); report.cacheFilesRetained += 1; continue
                }
                guard cached.supplementalContent?.isEmpty != false else {
                    try record("external/chapters", candidate.row, .needsReview, .supplementalContent); report.cacheFilesRetained += 1; continue
                }
                let rules = book.legacy.readConfig?.useReplaceRule == false ? [] : capturedRules
                // Never execute JavaScript from a replacement rule while inspecting/mapping data.
                let rulesKnown = rules.map { $0.allSatisfy { !$0.isEnabled || !$0.replacement.hasPrefix("@js:") } } ?? false
                let processed = rulesKnown ? ContentSanitizer().process(book: book.legacy, chapter: oldChapter, content: cached.content, rules: rules ?? []) : nil
                let text = processed?.content ?? cached.content
                let content = SourceWire.ChapterContent(title: cached.title ?? chapter.title, revision: "migration:" + candidate.file.sha256,
                    body: .text(.init(text: text)))
                guard let document = try? ChapterNormalizer.normalize(content) else {
                    try record("external/chapters", candidate.row, .needsReview, .malformedRecord); report.cacheFilesRetained += 1; continue
                }
                let gate = SourceCommitGate()
                let preparation = try await archive.prepareChapter(identity: book.identity, book: book.native, chapter: chapter.ref,
                    expectedCatalog: nil, reload: false, retainOffline: true, gate: gate)
                guard case .fetch(let request) = preparation else { throw SourceDomainError(.storageConflict, "迁移正文出现重复写入。") }
                let chapterKey = try SourceChapterKey(book: book.key, chapterID: chapter.ref.id)
                let stored = SourceCachedChapter(key: chapterKey, identity: book.identity, content: content, document: document,
                    storedAt: Date(timeIntervalSince1970: Double(cached.savedAt) / 1000), provenance: request.provenance)
                try await archive.saveChapter(stored, request: request, gate: gate)
                cachedDocuments[chapterKey] = rulesKnown && processed?.diagnostics.isEmpty == true && document.plainText == text
                report.books[book.reportIndex].cachedChapters += 1; report.cacheFilesMapped += 1
                try record("external/chapters", candidate.row, .mapped, .imported)
            }
        }
        func anchor(book: BookWork, index: Int, position: Int, quote: String? = nil) async throws -> SourceReadingAnchor? {
            guard let old = book.legacyChapters[index], !old.isVolume, let chapter = book.chapters[old.url] else { return nil }
            let key = try SourceChapterKey(book: book.key, chapterID: chapter.ref.id)
            guard let cached = try await archive.chapter(key, identity: book.identity, allowPreviousExtraction: true) else { return nil }
            let text = cached.document.plainText as NSString
            if cachedDocuments[key] == true, position >= 0, position <= text.length {
                let anchor = SourceReadingAnchor(chapter: key, document: cached.document, offsetUTF16: position)
                // Reject offsets inside a composed character instead of silently shifting them.
                if anchor.offsetUTF16 == position { return anchor }
            }
            // A bookmark quote can recover a location only when it occurs exactly once in this exact chapter.
            if let quote, !quote.isEmpty {
                let first = text.range(of: quote, options: .literal)
                if first.location != NSNotFound {
                    let end = first.location + first.length
                    let second = text.range(of: quote, options: .literal, range: NSRange(location: end, length: text.length - end))
                    if second.location == NSNotFound { return .init(chapter: key, document: cached.document, offsetUTF16: first.location) }
                }
            }
            return nil
        }
        mutating func positionsAndAnnotations() async throws {
            for book in bookMap.values {
                if let anchor = try await anchor(book: book, index: book.legacy.durChapterIndex, position: book.legacy.durChapterPos) {
                    try await archive.saveAnchor(anchor); report.books[book.reportIndex].progressMapped = true
                } else if book.legacy.durChapterTime > 0 || book.legacy.durChapterPos > 0 || book.legacy.durChapterIndex > 0 {
                    // The book remains imported; this additional row records the unresolved progress separately.
                    try record("reading-progress", book.row, .needsReview, .positionChanged)
                }
            }
            var after: Int64?
            while true {
                let rows = try await reader.rows("bookmarks", after: after)
                guard !rows.isEmpty else { break }; after = rows.last!.id
                for row in rows {
                    guard let bookmark = try? row.decode(Bookmark.self), String(bookmark.time) == row.fields["time"] else {
                        try record("bookmarks", row, .needsReview, .malformedRecord); continue
                    }
                    let matches = bookMap.values.filter { $0.legacy.name == bookmark.bookName && $0.legacy.author == bookmark.bookAuthor }
                    var resolved: SourceReadingAnchor?
                    if matches.count == 1, bookmark.epubLocation == nil {
                        resolved = try await anchor(book: matches[0], index: bookmark.chapterIndex, position: bookmark.chapterPosition, quote: bookmark.bookText)
                    }
                    report.annotations.append(.init(rowID: row.id, bookmark: bookmark, anchor: resolved))
                    try record("bookmarks", row, resolved == nil ? .needsReview : .mapped, resolved == nil ? .ambiguousBookmark : .imported)
                }
            }
        }
        mutating func state() async throws {
            var after: Int64?
            while true {
                let rows = try await reader.rows("caches", after: after)
                guard !rows.isEmpty else { break }; after = rows.last!.id
                for row in rows {
                    guard let key = row.fields["key"] else { try record("caches", row, .needsReview, .malformedRecord); continue }
                    let matches = sourceMap.values.filter { key.hasPrefix("v_" + $0.legacyID + "_") }
                    guard matches.count == 1, let source = matches.first else {
                        let login = key.hasPrefix("login") || key.hasPrefix("sourceCookies_")
                        try record("caches", row, login ? .needsReview : .retained, login ? .reauthentication : .preservedFeature); continue
                    }
                    let name = String(key.dropFirst(("v_" + source.legacyID + "_").count))
                    guard !["loginHeader", "loginInfo"].contains(name) else { try record("caches", row, .needsReview, .reauthentication); continue }
                    let deadline = Int64(row.fields["deadline"] ?? "") ?? -1
                    guard deadline == 0, let value = row.fields["value"], !name.isEmpty, name.utf8.count <= 512 else {
                        try record("caches", row, .retained, .preservedFeature); continue
                    }
                    _ = try await archive.setState(scope: source.scope, key: "legado.source." + SourceCoding.digest(Data(name.utf8)), value: .string(value))
                    try record("caches", row, .mapped, .imported)
                }
            }
            after = nil
            while true {
                let rows = try await reader.rows("cookies", after: after)
                guard !rows.isEmpty else { break }; after = rows.last!.id
                for row in rows { try record("cookies", row, .needsReview, .reauthentication) }
            }
        }
    }
}
