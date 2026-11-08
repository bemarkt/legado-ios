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
        var id: String { installation.id.uuidString + ":" + identity.scope.accountID + ":" + book.ref.id }
    }
    struct ShelfBook: Identifiable {
        let installation: SourceInstallation
        let book: SourceSavedBook
        var id: String { installation.id.uuidString + ":" + book.key.scope.accountID + ":" + book.key.bookID }
    }
    @Published private(set) var activeAccounts: [UUID: SourceAccount] = [:]
    @Published private(set) var installations: [SourceInstallation] = []
    @Published private(set) var shelf: [ShelfBook] = []
    @Published private(set) var results: [SearchHit] = []
    @Published private(set) var searching = false
    @Published private(set) var searchFailures: [String] = []
    @Published private(set) var canLoadMore = false
    @Published var message: String?
    private let databaseURL: URL
    let credentials: SourceCredentialVault
    private var reloadGeneration = UUID()
    private var guestGates: [UUID: SourceCommitGate] = [:]
    private var credentialEditGates: [UUID: SourceCommitGate] = [:]
    private var selectingAccounts = Set<UUID>()
    init(databaseURL: URL = SourceArchive.defaultURL(), credentials: SourceCredentialVault = .shared) {
        self.databaseURL = databaseURL; self.credentials = credentials
    }
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
        let generation = UUID(); reloadGeneration = generation
        do {
            let (archive, _) = try services()
            let installed = try await archive.installations()
            var shelf: [ShelfBook] = []
            var accounts: [UUID: SourceAccount] = [:]
            for installation in installed {
                let selected = try await archive.accountSettings(installationID: installation.id).selected
                accounts[installation.id] = selected
                let scope = try SourceScope(installationID: installation.id, accountID: selected.id)
                for book in try await archive.books(scope: scope) { shelf.append(.init(installation: installation, book: book)) }
            }
            guard reloadGeneration == generation else { return }
            activeAccounts = accounts
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
    func selectedScope(_ installation: SourceInstallation) async throws -> SourceScope {
        let selected = try await services().0.accountSettings(installationID: installation.id).selectedID
        return try .init(installationID: installation.id, accountID: selected)
    }
    func provider(_ installation: SourceInstallation, scope expectedScope: SourceScope? = nil) async throws -> WebKitSourceProvider {
        let (archive, _) = try services()
        let scope = try await selectedScope(installation)
        guard expectedScope == nil || expectedScope == scope else { throw SourceDomainError(.stale, "账号已切换，请从当前书架重新打开。") }
        let activityGate: SourceCommitGate?
        if scope.accountID == "guest" {
            let gate = guestGates[installation.id] ?? SourceCommitGate()
            guestGates[installation.id] = gate; activityGate = gate
        } else { activityGate = nil }
        let captured = try await archive.executionSnapshot(scope: scope)
        let snapshot = try await inspect(captured.installation.source)
        let session = scope.accountID == "guest" ? nil : try await credentials.session(scope: scope, allowedOrigins: Set(snapshot.inspection.metadata.origins))
        guard try await selectedScope(installation) == scope else { throw SourceDomainError(.stale, "账号已切换，请重试。") }
        try activityGate?.check()
        return try WebKitSourceProvider(snapshot: snapshot, installation: captured.installation, accountID: scope.accountID,
                                       configuration: captured.configuration, archive: archive, credentials: session, activityGate: activityGate)
    }
    func saveConfiguration(_ configuration: SourceJSON, installation: SourceInstallation, scope: SourceScope) async throws {
        guard try await selectedScope(installation) == scope else { throw SourceDomainError(.stale, "账号已切换，请重新打开选项。") }
        let snapshot = try await inspect(installation.source)
        let value = try snapshot.configuration(overrides: configuration)
        try await services().0.saveConfiguration(value, scope: scope, expectedSourceDigest: installation.digest, requireSelectedAccount: true)
        cancelSearch(clearResults: true)
    }
    func selectAccount(_ accountID: String, installation: SourceInstallation) async throws {
        guard selectingAccounts.insert(installation.id).inserted else { throw SourceDomainError(.unavailable, "正在切换账号，请稍后重试。") }
        defer { selectingAccounts.remove(installation.id) }
        let previous = try await selectedScope(installation)
        guard previous.accountID != accountID else { return }
        cancelSearch(clearResults: true); reloadGeneration = UUID()
        credentialEditGates.removeValue(forKey: installation.id)?.invalidate()
        guestGates.removeValue(forKey: installation.id)?.invalidate()
        await credentials.suspend(scope: previous)
        try await services().0.selectAccount(accountID, installationID: installation.id)
        await reload()
    }
    func credentialSession(_ installation: SourceInstallation, accountID: String) async throws -> SourceCredentialSession {
        let scope = try await selectedScope(installation)
        guard scope.accountID == accountID, accountID != "guest" else { throw SourceDomainError(.stale, "请先选择独立账号。") }
        let captured = try await services().0.executionSnapshot(scope: scope)
        guard captured.installation.digest == installation.digest else { throw SourceDomainError(.stale, "书源已更新，请重新打开账号设置。") }
        let session = try await credentials.session(scope: scope, allowedOrigins: Set(captured.installation.origins))
        guard try await selectedScope(installation) == scope else { throw SourceDomainError(.stale, "账号已切换，请重新打开。") }
        try session.commitGate.check()
        return session
    }
    func credentialContext(_ installation: SourceInstallation, accountID: String) async throws -> NativeSourceCredentialContext {
        let gate = credentialEditGates[installation.id] ?? SourceCommitGate()
        credentialEditGates[installation.id] = gate
        let session = try await credentialSession(installation, accountID: accountID)
        try gate.check()
        return NativeSourceCredentialContext(installation: installation, session: session, changeGate: gate)
    }
    func validateCredentialContext(_ context: NativeSourceCredentialContext) async throws {
        try context.changeGate.check(); try context.session.commitGate.check()
        let current = try await services().0.executionSnapshot(scope: context.session.scope)
        guard current.installation.digest == context.installation.digest,
              try await selectedScope(current.installation) == context.session.scope else {
            throw SourceDomainError(.stale, "账号或书源已改变，请重新打开登录页面。")
        }
        try context.changeGate.check(); try context.session.commitGate.check()
    }
    func saveLoginCookies(_ cookies: [SourceCredentialCookie], origin: String, context: NativeSourceCredentialContext) async throws {
        try await validateCredentialContext(context)
        try await credentials.replaceBrowserCookies(cookies, session: context.session, replacingOrigins: [origin], changeGate: context.changeGate)
        await credentialsChanged()
    }
    func saveBearer(_ token: String?, origin: String, context: NativeSourceCredentialContext) async throws {
        try await validateCredentialContext(context)
        try await credentials.setBearer(token, origin: origin, session: context.session, changeGate: context.changeGate)
        await credentialsChanged()
    }
    func clearLogin(context: NativeSourceCredentialContext) async throws {
        try await validateCredentialContext(context)
        try await credentials.clear(session: context.session, changeGate: context.changeGate)
        await credentialsChanged()
    }
    func credentialsChanged() async { cancelSearch(clearResults: true); await reload() }
    func replace(_ installation: SourceInstallation, with snapshot: SourceSnapshot, resetConfiguration: Bool,
                 originURL: String?, locallyModified: Bool) async throws {
        guard snapshot.inspection.unsupportedRequirements.isEmpty else { throw SourceFailure(code: "UNSUPPORTED", message: "此书源要求尚未支持的能力") }
        let (archive, _) = try services()
        let reviewed = try await archive.accountConfigurations(installationID: installation.id)
        if !resetConfiguration {
            for configuration in reviewed.values { _ = try snapshot.configuration(overrides: configuration) }
        }
        let metadata = snapshot.inspection.metadata
        let updated = try SourceInstallation(id: installation.id, publisherID: metadata.id, name: metadata.name, version: metadata.version,
            source: snapshot.source, origins: metadata.origins, createdAt: installation.createdAt,
            originURL: originURL, locallyModified: locallyModified)
        credentialEditGates.removeValue(forKey: installation.id)?.invalidate()
        try await archive.saveInstallation(updated, replacing: installation.digest, reviewedConfigurations: reviewed, resetAllAccountConfigurations: resetConfiguration)
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
        let provider = try await provider(hit.installation, scope: hit.identity.scope)
        guard provider.descriptor.identity == hit.identity else {
            throw SourceDomainError(.stale, "书源或选项已经更新，请重新搜索后加入书架")
        }
        _ = try await services().1.addBook(provider: provider, ref: hit.book.ref)
        await reload()
    }
}
