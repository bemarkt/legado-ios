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
    private var database: SourceArchive?
    private var service: SourceLibraryService?
    private var inspected: [String: SourceSnapshot] = [:]
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = UUID()
    private var anchorWrite: Task<Void, Never>?
    private var anchorGeneration = UUID()

    func services() throws -> (SourceArchive, SourceLibraryService) {
        if let database, let service { return (database, service) }
        let database = try SourceArchive(url: SourceArchive.defaultURL())
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
    func install(_ snapshot: SourceSnapshot) async throws {
        guard snapshot.inspection.unsupportedRequirements.isEmpty else { throw SourceFailure(code: "UNSUPPORTED", message: "此书源要求尚未支持的能力") }
        let metadata = snapshot.inspection.metadata
        let installation = try SourceInstallation(publisherID: metadata.id, name: metadata.name, version: metadata.version,
                                                  source: snapshot.source, origins: metadata.origins)
        try await services().0.saveInstallation(installation)
        await reload()
    }
    func provider(_ installation: SourceInstallation) async throws -> WebKitSourceProvider {
        let (archive, _) = try services()
        let snapshot = try await inspect(installation.source)
        let scope = try SourceScope(installationID: installation.id)
        let configuration = try await archive.configuration(scope: scope)
        return try WebKitSourceProvider(snapshot: snapshot, installation: installation, configuration: configuration, archive: archive)
    }
    func saveConfiguration(_ configuration: SourceJSON, installation: SourceInstallation) async throws {
        let snapshot = try await inspect(installation.source)
        let value = try snapshot.configuration(overrides: configuration)
        try await services().0.saveConfiguration(value, scope: .init(installationID: installation.id))
        cancelSearch()
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
        _ = try await services().1.addBook(provider: provider, ref: hit.book.ref)
        await reload()
    }
}
