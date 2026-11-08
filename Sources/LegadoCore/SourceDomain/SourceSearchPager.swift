import Foundation

/// One query over one immutable provider snapshot. A failed or cancelled request does not consume its cursor.
public actor SourceSearchPager {
    public struct Batch: Sendable {
        public let items: [SourceWire.BookSummary]
        public let hasMore: Bool
    }
    public nonisolated let descriptor: SourceProviderDescriptor
    private let provider: any SourceProvider
    private let query: String
    private let maximumPages: Int
    private let maximumItems: Int
    private var cursor: SourceCursorEnvelope?
    private var seenCursors = Set<Data>()
    private var seenBooks = Set<String>()
    private var revision: String?
    private var pages = 0
    private var loading = false
    private var finished = false
    public var hasMore: Bool { !finished }

    public init(provider: any SourceProvider, query: String, maximumPages: Int = 100, maximumItems: Int = 10_000) throws {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.utf8.count <= 4096, maximumPages > 0, maximumItems > 0 else {
            throw SourceDomainError(.invalidInput, "Invalid search query or page budget")
        }
        self.provider = provider; descriptor = provider.descriptor; self.query = query
        self.maximumPages = maximumPages; self.maximumItems = maximumItems
    }

    public func next() async throws -> Batch {
        try Task.checkCancellation()
        guard !loading else { throw SourceDomainError(.stale, "Search page is already loading") }
        guard !finished else { return Batch(items: [], hasMore: false) }
        guard provider.descriptor.identity == descriptor.identity else {
            finished = true
            throw SourceDomainError(.stale, "书源或选项已改变，请重新搜索。")
        }
        loading = true
        defer { loading = false }
        let input = SourceJSON.object(["query": .string(query)])
        let value = try cursor?.unwrap(identity: descriptor.identity, input: input)
        let page = try await provider.search(.init(query: query, cursor: value))
        try Task.checkCancellation()
        // Only malformed/inconsistent data ends pagination. Network failures above remain retryable.
        do {
            guard provider.descriptor.identity == descriptor.identity else {
                throw SourceDomainError(.stale, "书源或选项已改变，请重新搜索。")
            }
            if let revision, page.revision != revision {
                throw SourceDomainError(.catalogChanged, "搜索结果版本发生变化，请重新搜索。")
            }
            if let revision = page.revision, revision.isEmpty {
                throw SourceDomainError(.invalidData, "Empty search revision")
            }
            guard page.items.count <= 1000 else { throw SourceDomainError(.resourceLimit, "Search page exceeds item budget") }
            var additions: [SourceWire.BookSummary] = [], pageIDs = Set<String>()
            for book in page.items {
                try SourceBookKey.validateID(book.ref.id)
                guard !book.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      pageIDs.insert(book.ref.id).inserted else { throw SourceDomainError(.invalidData, "Invalid or repeated book within search page") }
                if let state = book.ref.state { _ = try state.validatedData() }
                // Search rankings may overlap between pages without a snapshot revision. Keep the first result for each ID.
                if !seenBooks.contains(book.ref.id) { additions.append(book) }
            }
            guard seenBooks.count + additions.count <= maximumItems else {
                throw SourceDomainError(.resourceLimit, "搜索结果超过数量限制，请缩小关键词范围。")
            }
            let next: SourceCursorEnvelope?
            var cursorData: Data?
            if page.nextCursor == .null { next = nil }
            else {
                guard pages + 1 < maximumPages else { throw SourceDomainError(.resourceLimit, "搜索分页超过限制，请缩小关键词范围。") }
                let data = try page.nextCursor.validatedData()
                guard !seenCursors.contains(data) else { throw SourceDomainError(.invalidData, "书源重复返回搜索游标，已停止继续加载。") }
                cursorData = data
                next = try SourceCursorEnvelope(identity: descriptor.identity, input: input, value: page.nextCursor)
            }
            try Task.checkCancellation()
            seenBooks.formUnion(additions.map(\.ref.id))
            if let cursorData { seenCursors.insert(cursorData) }
            pages += 1; revision = page.revision; cursor = next; finished = next == nil
            return Batch(items: additions, hasMore: !finished)
        } catch is CancellationError { throw CancellationError() }
        catch { finished = true; throw error }
    }
}
