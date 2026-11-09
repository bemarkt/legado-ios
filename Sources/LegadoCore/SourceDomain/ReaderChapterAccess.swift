import Foundation

/// The renderer asks for a stable chapter identifier, never a website rule or network URL.
/// The access implementation owns credentials, cache policy and cancellation.
public protocol ReaderChapterAccess: Sendable {
    func load(chapterID: String, reload: Bool) async throws -> ReaderChapterSnapshot
}

public struct ReaderChapterSnapshot: Sendable {
    public let title: String?
    public let text: String
    public let document: ChapterDocument?
    public let loadedFromCache: Bool
    public init(title: String?, text: String, document: ChapterDocument? = nil, loadedFromCache: Bool = false) {
        self.title = title; self.text = text; self.document = document; self.loadedFromCache = loadedFromCache
    }
}

/// One reading session over a fixed catalog. Simultaneous renderer/speech requests share work;
/// cancelling one consumer does not cancel another, and reload supersedes an older ordinary read.
public actor SourceReaderChapterAccess: ReaderChapterAccess {
    public typealias ProviderFactory = @Sendable () async throws -> any SourceProvider
    private struct Flight {
        let id: UUID
        let reload: Bool
        var waiters: [UUID: CheckedContinuation<ReaderChapterSnapshot, Error>]
        let task: Task<Void, Never>
    }
    private let catalog: SourceCatalog
    private let chapters: [String: SourceWire.Chapter]
    private let archive: SourceArchive
    private let service: SourceLibraryService
    private let provider: ProviderFactory
    private let offlineOnly: Bool
    private var flights: [String: Flight] = [:]
    private var closed = false

    public init(catalog: SourceCatalog, archive: SourceArchive, offlineOnly: Bool, provider: @escaping ProviderFactory) {
        self.catalog = catalog; self.archive = archive; self.offlineOnly = offlineOnly; self.provider = provider
        service = SourceLibraryService(archive: archive)
        chapters = Dictionary(catalog.chapters.map { ($0.ref.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public func load(chapterID: String, reload: Bool = false) async throws -> ReaderChapterSnapshot {
        try Task.checkCancellation()
        guard !closed else { throw SourceDomainError(.stale, "阅读会话已关闭。") }
        guard let chapter = chapters[chapterID] else { throw SourceDomainError(.invalidInput, "章节不在本次阅读目录中。") }
        let waiter = UUID()
        let snapshot: ReaderChapterSnapshot = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                if reload && !offlineOnly, let flight = flights[chapterID], !flight.reload {
                    finish(chapterID, id: flight.id, result: .failure(SourceDomainError(.stale, "本章已有更新的刷新请求。")))
                    flight.task.cancel()
                }
                if flights[chapterID] != nil {
                    flights[chapterID]?.waiters[waiter] = continuation
                    return
                }
                let id = UUID()
                let task = Task { [catalog, archive, service, provider, offlineOnly] in
                    let result: Result<ReaderChapterSnapshot, Error>
                    do {
                        let read: SourceChapterRead
                        if offlineOnly {
                            // Offline reading needs neither a running source engine nor an unlocked website credential.
                            let key = try SourceChapterKey(book: .init(scope: catalog.identity.libraryScope, bookID: catalog.book.id), chapterID: chapterID)
                            guard let cached = try await archive.chapter(key, identity: catalog.identity, allowPreviousExtraction: true) else {
                                throw SourceDomainError(.notDownloaded, "本章没有离线副本。")
                            }
                            read = .init(chapter: cached, origin: .offline)
                        } else {
                            let current = try await provider()
                            try Task.checkCancellation()
                            guard current.descriptor.identity == catalog.identity else {
                                throw SourceDomainError(.stale, "书源或网站登录已改变，请返回书籍详情刷新目录。")
                            }
                            read = try await service.readChapter(provider: current, book: catalog.book, chapter: chapter.ref,
                                policy: reload ? .reload : .current, catalog: catalog)
                        }
                        try Task.checkCancellation()
                        result = .success(.init(title: read.chapter.content.title ?? chapter.title,
                            text: read.chapter.document.plainText, document: read.chapter.document, loadedFromCache: read.origin != .network))
                    } catch { result = .failure(error) }
                    finish(chapterID, id: id, result: result)
                }
                flights[chapterID] = Flight(id: id, reload: reload, waiters: [waiter: continuation], task: task)
            }
        } onCancel: { Task { await self.cancel(chapterID, waiter: waiter) } }
        // Completion and onCancel can race for the actor. Never deliver a value to a
        // cancelled consumer even if the shared read finished before its removal ran.
        try Task.checkCancellation()
        return snapshot
    }

    private func cancel(_ chapterID: String, waiter: UUID) {
        guard var flight = flights[chapterID], let continuation = flight.waiters.removeValue(forKey: waiter) else { return }
        if flight.waiters.isEmpty { flights[chapterID] = nil; flight.task.cancel() }
        else { flights[chapterID] = flight }
        continuation.resume(throwing: CancellationError())
    }
    private func finish(_ chapterID: String, id: UUID, result: Result<ReaderChapterSnapshot, Error>) {
        guard let flight = flights[chapterID], flight.id == id else { return }
        flights[chapterID] = nil
        for continuation in flight.waiters.values { continuation.resume(with: result) }
    }
    public func close() {
        closed = true
        let pending = flights; flights.removeAll()
        for flight in pending.values {
            flight.task.cancel()
            for continuation in flight.waiters.values { continuation.resume(throwing: CancellationError()) }
        }
    }

    #if DEBUG
    // Lets concurrency regressions synchronize on admitted consumers and drain an
    // intentionally uncooperative provider without sleeps or scheduler assumptions.
    func pendingRead(for chapterID: String) -> (consumers: Int, task: Task<Void, Never>)? {
        flights[chapterID].map { ($0.waiters.count, $0.task) }
    }
    #endif
}
