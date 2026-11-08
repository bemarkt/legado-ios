import Foundation
import SwiftUI

@MainActor
final class NativeSourceLibrary: ObservableObject {
    struct SearchHit: Identifiable {
        let installation: SourceInstallation
        let book: SourceWire.BookSummary
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
    @Published var message: String?
    private let databaseURL: URL
    init(databaseURL: URL = SourceArchive.defaultURL()) { self.databaseURL = databaseURL }
    private var database: SourceArchive?
    private var service: SourceLibraryService?
    private var inspected: [String: SourceSnapshot] = [:]
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = UUID()
    private var anchorWrite: Task<Void, Never>?
    private var anchorGeneration = UUID()

    func services() throws -> (SourceArchive, SourceLibraryService) {
        if let database, let service { return (database, service) }
        let database = try SourceArchive(url: databaseURL)
        let service = SourceLibraryService(archive: database)
        self.database = database; self.service = service
        return (database, service)
    }
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
        cancelSearch()
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
        cancelSearch()
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { results = []; return }
        let generation = UUID(); searchGeneration = generation
        searching = true; results = []; searchFailures = []
        searchTask = Task {
            defer { if searchGeneration == generation { searching = false; searchTask = nil } }
            var providers: [any SourceProvider] = []
            let sources = installations
            for installation in sources {
                do { providers.append(try await provider(installation)) }
                catch { if searchGeneration == generation { searchFailures.append(installation.name + ": " + error.localizedDescription) } }
                if Task.isCancelled || searchGeneration != generation { return }
            }
            for await update in SourceSearchService.search(query, providers: providers) {
                guard !Task.isCancelled, searchGeneration == generation else { return }
                guard let installation = sources.first(where: { $0.id == update.descriptor.identity.scope.installationID }) else { continue }
                if let page = update.page {
                    for book in page.items {
                        let hit = SearchHit(installation: installation, book: book)
                        if !results.contains(where: { $0.id == hit.id }) { results.append(hit) }
                    }
                }
                if let error = update.error { searchFailures.append(installation.name + ": " + error) }
            }
        }
    }
    func cancelSearch(clearResults: Bool = false) {
        searchGeneration = UUID(); searchTask?.cancel(); searchTask = nil; searching = false
        if clearResults { results = []; searchFailures = [] }
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
        guard provider.descriptor.identity.sourceDigest == hit.installation.digest else {
            throw SourceDomainError(.stale, "书源已经更新，请重新搜索后加入书架")
        }
        _ = try await services().1.addBook(provider: provider, ref: hit.book.ref)
        await reload()
    }
}
