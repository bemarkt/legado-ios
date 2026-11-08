import Foundation
import SwiftUI

@MainActor
final class NativeSourceLibrary: ObservableObject {
    private struct SearchSource: Sendable {
        let installation: SourceInstallation
        var pager: SourceSearchPager?
    }
    private struct SearchDelivery: Sendable {
        let source: SearchSource
        let batch: SourceSearchPager.Batch?
        let error: String?
        let canContinue: Bool
    }
    struct SearchHit: Identifiable {
        let installation: SourceInstallation
        let book: SourceWire.BookSummary
        let identity: SourceExecutionIdentity
        var id: String { installation.id.uuidString + ":" + book.ref.id }
    }
    struct ShelfBook: Identifiable {
        let installation: SourceInstallation
        let book: SourceSavedBook
        var id: String { installation.id.uuidString + ":" + book.key.bookID }
    }
    @Published private(set) var installations: [SourceInstallation] = []
    @Published private(set) var shelf: [ShelfBook] = []
    @Published private(set) var results: [SearchHit] = []
    @Published private(set) var searching = false
    @Published private(set) var searchFailures: [String] = []
    @Published private(set) var canLoadMore = false
    @Published var message: String?
    private let databaseURL: URL
    init(databaseURL: URL = SourceArchive.defaultURL()) { self.databaseURL = databaseURL }
    private var database: SourceArchive?
    private var service: SourceLibraryService?
    private var inspected: [String: SourceSnapshot] = [:]
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = UUID()
    private var searchSources: [UUID: SearchSource] = [:]
    private var searchErrors: [UUID: String] = [:]
    private var activeQuery = ""
    private var resultIDs = Set<String>()
    private var anchorWrite: Task<Void, Never>?
    private var anchorGeneration = UUID()

    func services() throws -> (SourceArchive, SourceLibraryService) {
        if let database, let service { return (database, service) }
        let database = try SourceArchive(url: databaseURL)
        let service = SourceLibraryService(archive: database)
        self.database = database; self.service = service
        return (database, service)
    }
    func releaseCatalogMemory() async { await database?.clearCatalogMemoryCache() }
    func reload() async {
        do {
            let (archive, _) = try services()
            let installed = try await archive.installations()
            var shelf: [ShelfBook] = []
            for installation in installed {
                let scope = try SourceScope(installationID: installation.id)
                for book in try await archive.books(scope: scope) { shelf.append(.init(installation: installation, book: book)) }
            }
            installations = installed.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            self.shelf = shelf.sorted { $0.book.addedAt > $1.book.addedAt }
        } catch { message = error.localizedDescription }
    }
    func inspect(_ text: String) async throws -> SourceSnapshot {
        let digest = SourceCoding.digest(Data(text.utf8))
        if let snapshot = inspected[digest] { return snapshot }
        let snapshot = try await SourceInspector().inspect(Data(text.utf8))
        if inspected.count >= 16 { inspected.removeAll() }
        inspected[digest] = snapshot
        return snapshot
    }
    func install(_ snapshot: SourceSnapshot, originURL: String? = nil) async throws {
        guard snapshot.inspection.unsupportedRequirements.isEmpty else { throw SourceFailure(code: "UNSUPPORTED", message: "此书源要求尚未支持的能力") }
        let metadata = snapshot.inspection.metadata
        let installation = try SourceInstallation(publisherID: metadata.id, name: metadata.name, version: metadata.version,
                                                  source: snapshot.source, origins: metadata.origins, originURL: originURL)
        try await services().0.saveInstallation(installation)
        await reload()
    }
    func provider(_ installation: SourceInstallation) async throws -> WebKitSourceProvider {
        let (archive, _) = try services()
        let scope = try SourceScope(installationID: installation.id)
        let captured = try await archive.executionSnapshot(scope: scope)
        let snapshot = try await inspect(captured.installation.source)
        return try WebKitSourceProvider(snapshot: snapshot, installation: captured.installation, configuration: captured.configuration, archive: archive)
    }
    func saveConfiguration(_ configuration: SourceJSON, installation: SourceInstallation) async throws {
        let snapshot = try await inspect(installation.source)
        let value = try snapshot.configuration(overrides: configuration)
        try await services().0.saveConfiguration(value, scope: .init(installationID: installation.id), expectedSourceDigest: installation.digest)
        cancelSearch(clearResults: true)
    }
    func replace(_ installation: SourceInstallation, with snapshot: SourceSnapshot, resetConfiguration: Bool,
                 originURL: String?, locallyModified: Bool) async throws {
        guard snapshot.inspection.unsupportedRequirements.isEmpty else { throw SourceFailure(code: "UNSUPPORTED", message: "此书源要求尚未支持的能力") }
        let (archive, _) = try services()
        let scope = try SourceScope(installationID: installation.id)
        if !resetConfiguration { _ = try snapshot.configuration(overrides: await archive.configuration(scope: scope)) }
        let metadata = snapshot.inspection.metadata
        let updated = try SourceInstallation(id: installation.id, publisherID: metadata.id, name: metadata.name, version: metadata.version,
            source: snapshot.source, origins: metadata.origins, createdAt: installation.createdAt,
            originURL: originURL, locallyModified: locallyModified)
        try await archive.saveInstallation(updated, replacing: installation.digest, resetConfigurationFor: resetConfiguration ? scope : nil)
        cancelSearch(clearResults: true)
        await reload()
    }
    func downloadSource(_ address: String) async throws -> (source: String, url: String) {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme == "https",
              url.user == nil, url.password == nil, url.fragment == nil, let origin = SourceHTTPPolicy.origin(url) else {
            throw SourceFailure(code: "INVALID_INPUT", message: "请输入不含账号密码或片段的 HTTPS 原始文件地址")
        }
        let response = try await SourceHTTP.fetch(.init(url: url.absoluteString, method: "GET", headers: [:], body: nil, redirect: "follow"),
            policy: .init(origins: [origin], allowLoopbackHTTP: false, maximumBytes: 2_097_152, maximumRedirects: 3, timeout: 20))
        guard response.status == 200, let data = Data(base64Encoded: response.body), let text = String(data: data, encoding: .utf8) else {
            throw SourceFailure(code: "NETWORK", message: "未取得有效的 UTF-8 书源文件（HTTP \(response.status)）")
        }
        return (text, response.url)
    }
    func search(_ query: String) {
        cancelSearch(clearResults: true)
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        activeQuery = query
        searchSources = Dictionary(uniqueKeysWithValues: installations.map { ($0.id, SearchSource(installation: $0)) })
        loadMore()
    }
    func loadMore() {
        guard !searching, !searchSources.isEmpty else { return }
        let generation = UUID(); searchGeneration = generation
        let query = activeQuery
        let sources = installations.compactMap { searchSources[$0.id] }
        searching = true; canLoadMore = false
        searchTask = Task {
            defer {
                if searchGeneration == generation {
                    searching = false; searchTask = nil; canLoadMore = !searchSources.isEmpty
                }
            }
            // Initial inspection and subsequent pages share the same bounded pool.
            await withTaskGroup(of: SearchDelivery.self) { group in
                var next = 0
                func enqueue(_ source: SearchSource) {
                    group.addTask {
                        var source = source
                        do {
                            try Task.checkCancellation()
                            if source.pager == nil {
                                let provider = try await self.provider(source.installation)
                                guard provider.descriptor.supportsSearch else {
                                    return SearchDelivery(source: source, batch: nil, error: nil, canContinue: false)
                                }
                                source.pager = try SourceSearchPager(provider: provider, query: query)
                            }
                            guard let pager = source.pager else { throw SourceDomainError(.unavailable, "Search was not initialized") }
                            let batch = try await pager.next()
                            try Task.checkCancellation()
                            return SearchDelivery(source: source, batch: batch, error: nil, canContinue: batch.hasMore)
                        } catch is CancellationError { return SearchDelivery(source: source, batch: nil, error: nil, canContinue: false) }
                        catch {
                            let canContinue: Bool
                            if let pager = source.pager { canContinue = await pager.hasMore }
                            else { canContinue = true }
                            return SearchDelivery(source: source, batch: nil, error: error.localizedDescription, canContinue: canContinue)
                        }
                    }
                }
                while next < min(2, sources.count) { enqueue(sources[next]); next += 1 }
                for await update in group {
                    guard !Task.isCancelled, searchGeneration == generation else { group.cancelAll(); return }
                    let installation = update.source.installation
                    if let batch = update.batch, let pager = update.source.pager {
                        for book in batch.items {
                            let hit = SearchHit(installation: installation, book: book, identity: pager.descriptor.identity)
                            if resultIDs.insert(hit.id).inserted { results.append(hit) }
                        }
                    }
                    if let error = update.error { searchErrors[installation.id] = installation.name + ": " + error }
                    else { searchErrors.removeValue(forKey: installation.id) }
                    searchFailures = installations.compactMap { searchErrors[$0.id] }
                    if update.canContinue { searchSources[installation.id] = update.source }
                    else { searchSources.removeValue(forKey: installation.id) }
                    if next < sources.count { enqueue(sources[next]); next += 1 }
                }
            }
        }
    }
    func cancelSearch(clearResults: Bool = false) {
        searchGeneration = UUID(); searchTask?.cancel(); searchTask = nil; searching = false
        // A cancelled delivery may have advanced its pager before reaching the UI; never resume those cursors.
        searchSources = [:]; canLoadMore = false
        if clearResults { results = []; resultIDs = []; searchFailures = []; searchErrors = [:] }
    }
    /// Serialize position writes so a departing chapter cannot overwrite the next chapter's anchor.
    func savePosition(_ anchor: SourceReadingAnchor) {
        guard let archive = try? services().0 else { return }
        let previous = anchorWrite, generation = UUID()
        anchorGeneration = generation
        anchorWrite = Task {
            await previous?.value
            defer { if anchorGeneration == generation { anchorWrite = nil } }
            do { try await archive.saveAnchor(anchor) }
            catch { message = error.localizedDescription }
        }
    }
    func pendingPositionWrites() async { await anchorWrite?.value }
    func add(_ hit: SearchHit) async throws {
        let provider = try await provider(hit.installation)
        guard provider.descriptor.identity == hit.identity else {
            throw SourceDomainError(.stale, "书源或选项已经更新，请重新搜索后加入书架")
        }
        _ = try await services().1.addBook(provider: provider, ref: hit.book.ref)
        await reload()
    }
}
