import Foundation

public struct SourceCursorEnvelope: Codable, Sendable, Equatable {
    public let identity: SourceExecutionIdentity
    public let inputDigest: String
    public let value: SourceJSON
    public init(identity: SourceExecutionIdentity, input: SourceJSON, value: SourceJSON) throws {
        self.identity = identity
        inputDigest = SourceCoding.digest(try input.validatedData())
        _ = try value.validatedData()
        self.value = value
    }
    public func unwrap(identity: SourceExecutionIdentity, input: SourceJSON) throws -> SourceJSON {
        guard self.identity == identity, inputDigest == SourceCoding.digest(try input.validatedData()) else {
            throw SourceDomainError(.stale, "Cursor belongs to another source, account, configuration or query")
        }
        return value
    }
}

public struct SourceCatalog: Codable, Sendable, Equatable {
    public let identity: SourceExecutionIdentity
    public let book: SourceWire.SourceRef
    public let chapters: [SourceWire.Chapter]
    public let revision: String?
    public let fetchedAt: Date
    /// Host-owned invalidation epoch, absent in archives written before revision-aware caching.
    /// Reused only for an identical catalog with an explicit, unchanged provider revision.
    var cacheEpoch: UUID?
    public init(identity: SourceExecutionIdentity, book: SourceWire.SourceRef, chapters: [SourceWire.Chapter], revision: String?, fetchedAt: Date = Date()) {
        self.identity = identity; self.book = book; self.chapters = chapters; self.revision = revision; self.fetchedAt = fetchedAt
    }

    public struct Changes: Sendable, Equatable {
        public let inserted: [String]
        public let removed: [String]
        public let updated: [String]
        public let reordered: Bool
    }
    public func changes(from previous: Self) throws -> Changes {
        guard identity.scope == previous.identity.scope, book.id == previous.book.id else {
            throw SourceDomainError(.invalidInput, "Catalogs belong to different books")
        }
        let old = Dictionary(previous.chapters.map { ($0.ref.id, $0) }, uniquingKeysWith: { first, _ in first })
        let new = Dictionary(chapters.map { ($0.ref.id, $0) }, uniquingKeysWith: { first, _ in first })
        return Changes(inserted: chapters.map(\.ref.id).filter { old[$0] == nil },
                       removed: previous.chapters.map(\.ref.id).filter { new[$0] == nil },
                       updated: chapters.filter { old[$0.ref.id] != nil && old[$0.ref.id] != $0 }.map(\.ref.id),
                       reordered: previous.chapters.map(\.ref.id).filter { new[$0] != nil } != chapters.map(\.ref.id).filter { old[$0] != nil })
    }
}

public struct SourceCatalogLoader: Sendable {
    public let maximumPages: Int
    public let maximumChapters: Int
    public init(maximumPages: Int = 1000, maximumChapters: Int = 100_000) {
        self.maximumPages = maximumPages; self.maximumChapters = maximumChapters
    }
    public func load(provider: any SourceProvider, book: SourceWire.SourceRef) async throws -> SourceCatalog {
        try SourceBookKey.validateID(book.id)
        let identity = provider.descriptor.identity
        var cursor: SourceJSON = .null
        var seenCursors = Set<Data>()
        var chapters: [SourceWire.Chapter] = []
        var indices: [String: Int] = [:]
        var revision: String?
        for _ in 0..<max(0, maximumPages) {
            try Task.checkCancellation()
            guard provider.descriptor.identity == identity else { throw SourceDomainError(.stale, "Source changed during catalog loading") }
            let page = try await provider.chapters(.init(book: book, cursor: cursor))
            try Task.checkCancellation()
            guard provider.descriptor.identity == identity else { throw SourceDomainError(.stale, "Source changed during catalog loading") }
            guard page.items.count <= 1000 else { throw SourceDomainError(.resourceLimit, "Catalog page exceeds item budget") }
            if let expected = revision, page.revision != expected { throw SourceDomainError(.catalogChanged, "Catalog revision changed between pages") }
            if let value = page.revision {
                guard !value.isEmpty else { throw SourceDomainError(.invalidData, "Empty catalog revision") }
                revision = value
            }
            var pageIDs = Set<String>()
            for chapter in page.items {
                try SourceBookKey.validateID(chapter.ref.id)
                guard !chapter.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      pageIDs.insert(chapter.ref.id).inserted else { throw SourceDomainError(.invalidData, "Invalid or repeated chapter identity within a page") }
                if let state = chapter.ref.state { _ = try state.validatedData() }
                if let index = indices[chapter.ref.id] {
                    guard chapters[index] == chapter else { throw SourceDomainError(.catalogChanged, "Conflicting chapter across catalog pages") }
                } else {
                    guard chapters.count < maximumChapters else { throw SourceDomainError(.resourceLimit, "Catalog chapter budget exceeded") }
                    indices[chapter.ref.id] = chapters.count
                    chapters.append(chapter)
                }
            }
            if page.nextCursor == .null { return SourceCatalog(identity: identity, book: book, chapters: chapters, revision: revision) }
            let data = try page.nextCursor.validatedData()
            guard seenCursors.insert(data).inserted else { throw SourceDomainError(.catalogChanged, "Catalog cursor repeated") }
            cursor = page.nextCursor
        }
        throw SourceDomainError(.resourceLimit, "Catalog page budget exceeded")
    }
}
