import Foundation

public actor SourceLibraryService {
    public enum ReadPolicy: Sendable, Equatable { case current, offline }
    public let archive: SourceArchive
    private var generations: [String: SourceCommitGate] = [:]
    public init(archive: SourceArchive) { self.archive = archive }

    public func addBook(provider: any SourceProvider, ref: SourceWire.SourceRef) async throws -> SourceSavedBook {
        let details = try await provider.book(.init(ref: ref))
        try Task.checkCancellation()
        guard details.ref.id == ref.id else { throw SourceDomainError(.invalidData, "Provider changed stable book identity") }
        let saved = SourceSavedBook(key: try .init(scope: provider.descriptor.identity.scope, bookID: ref.id), details: details)
        try await archive.saveBook(saved)
        return saved
    }

    public func refreshCatalog(provider: any SourceProvider, book: SourceWire.SourceRef) async throws -> SourceCatalog {
        try Task.checkCancellation()
        let key = try SourceBookKey(scope: provider.descriptor.identity.scope, bookID: book.id)
        let operation = "catalog:" + SourceCoding.digest(try SourceCoding.encode(key))
        generations[operation]?.invalidate()
        let generation = SourceCommitGate()
        generations[operation] = generation
        defer {
            generation.invalidate()
            if generations[operation] === generation { generations.removeValue(forKey: operation) }
        }
        let catalog = try await SourceCatalogLoader().load(provider: provider, book: book)
        try Task.checkCancellation()
        guard generations[operation] === generation else { throw SourceDomainError(.stale, "A newer catalog refresh superseded this result") }
        try await archive.saveCatalog(catalog, gate: generation)
        return catalog
    }

    public func chapter(provider: any SourceProvider, book: SourceWire.SourceRef, chapter: SourceWire.SourceRef,
                        policy: ReadPolicy = .current) async throws -> SourceCachedChapter {
        try Task.checkCancellation()
        let identity = provider.descriptor.identity
        let key = try SourceChapterKey(book: .init(scope: identity.scope, bookID: book.id), chapterID: chapter.id)
        let operation = "chapter:" + SourceCoding.digest(try SourceCoding.encode(key))
        generations[operation]?.invalidate()
        let generation = SourceCommitGate()
        generations[operation] = generation
        defer {
            generation.invalidate()
            if generations[operation] === generation { generations.removeValue(forKey: operation) }
        }
        if let cached = try await archive.chapter(key, identity: identity, allowPreviousExtraction: policy == .offline) {
            try Task.checkCancellation()
            guard generations[operation] === generation else { throw SourceDomainError(.stale, "Chapter read superseded") }
            return cached
        }
        guard policy != .offline else { throw SourceDomainError(.notDownloaded, "This chapter has not been downloaded for this account") }
        let content = try await provider.content(.init(book: book, chapter: chapter))
        try Task.checkCancellation()
        guard provider.descriptor.identity == identity, generations[operation] === generation else {
            throw SourceDomainError(.stale, "Chapter result belongs to an older operation")
        }
        let value = SourceCachedChapter(key: key, identity: identity, content: content, document: try ChapterNormalizer.normalize(content))
        try Task.checkCancellation()
        try await archive.saveChapter(value, gate: generation)
        return value
    }

    /// A failed download preserves completed chapters; cancellation is checked between chapters.
    public func download(provider: any SourceProvider, catalog: SourceCatalog) async throws -> Int {
        guard provider.descriptor.identity == catalog.identity else { throw SourceDomainError(.stale, "Download must use the catalog snapshot") }
        var count = 0
        for item in catalog.chapters {
            try Task.checkCancellation()
            _ = try await chapter(provider: provider, book: catalog.book, chapter: item.ref)
            count += 1
        }
        return count
    }
}

/// The caller owns the search generation; cancelling a stream cancels all outstanding provider work.
public enum SourceSearchService {
    public struct Update: Sendable {
        public let descriptor: SourceProviderDescriptor
        public let page: SourceWire.SearchPage?
        public let error: String?
    }
    public static func search(_ query: String, providers: [any SourceProvider], concurrency: Int = 2) -> AsyncStream<Update> {
        AsyncStream { continuation in
            let task = Task {
                await withTaskGroup(of: Update.self) { group in
                    let eligible = providers.filter { $0.descriptor.supportsSearch }
                    var next = 0
                    func enqueue(_ provider: any SourceProvider) {
                        group.addTask {
                            do {
                                try Task.checkCancellation()
                                let page = try await provider.search(.init(query: query))
                                try Task.checkCancellation()
                                return Update(descriptor: provider.descriptor, page: page, error: nil)
                            } catch { return Update(descriptor: provider.descriptor, page: nil, error: error.localizedDescription) }
                        }
                    }
                    for _ in 0..<min(max(1, concurrency), eligible.count) { enqueue(eligible[next]); next += 1 }
                    while let result = await group.next() {
                        if Task.isCancelled { group.cancelAll(); break }
                        continuation.yield(result)
                        if next < eligible.count { enqueue(eligible[next]); next += 1 }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}
