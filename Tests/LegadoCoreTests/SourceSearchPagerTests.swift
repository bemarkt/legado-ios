import Foundation
import Testing
@testable import LegadoCore

private actor SearchPagerProvider: SourceProvider {
    nonisolated let descriptor: SourceProviderDescriptor
    private let pages: [SourceWire.SearchPage]
    private var failing = false
    private var pauseNext = false
    private var pending: CheckedContinuation<Void, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private(set) var inputs: [SourceWire.SearchInput] = []
    init(_ pages: [SourceWire.SearchPage]) throws {
        self.pages = pages
        descriptor = .init(identity: try .init(scope: .init(installationID: UUID()), sourceDigest: String(repeating: "a", count: 64), configuration: .object([:])), name: "Pager")
    }
    func failNext() { failing = true }
    func pause() { pauseNext = true }
    func waitUntilPaused() async {
        if pending != nil { return }
        await withCheckedContinuation { started = $0 }
    }
    func resume() { pending?.resume(); pending = nil }
    func search(_ input: SourceWire.SearchInput) async throws -> SourceWire.SearchPage {
        inputs.append(input)
        if failing { failing = false; throw SourceDomainError(.unavailable, "Synthetic offline") }
        if pauseNext {
            pauseNext = false
            await withCheckedContinuation { continuation in
                pending = continuation; started?.resume(); started = nil
            }
        }
        let index: Int
        if case .some(.number(let value)) = input.cursor { index = Int(value) } else { index = 0 }
        guard pages.indices.contains(index) else { throw SourceDomainError(.invalidInput, "Unknown fixture cursor") }
        return pages[index]
    }
    func book(_ input: SourceWire.BookInput) async throws -> SourceWire.BookDetails { .init(ref: input.ref, title: "Book") }
    func chapters(_ input: SourceWire.ChaptersInput) async throws -> SourceWire.ChapterPage { .init(items: [], nextCursor: .null) }
    func content(_ input: SourceWire.ContentInput) async throws -> SourceWire.ChapterContent { .init(body: .text(.init(text: "Body"))) }
}

@Suite("Native source search pagination")
struct SourceSearchPagerTests {
    private func book(_ id: String) -> SourceWire.BookSummary { .init(ref: .init(id: id), title: "Book " + id) }

    @Test func emptyPagesContinueAndCrossPageIDsDeduplicate() async throws {
        let provider = try SearchPagerProvider([
            .init(items: [book("a")], nextCursor: .number(1)),
            .init(items: [], nextCursor: .number(2)),
            .init(items: [book("a"),book("b")], nextCursor: .null)
        ])
        let pager = try SourceSearchPager(provider: provider, query: "query")
        let first = try await pager.next(), empty = try await pager.next(), last = try await pager.next()
        #expect(first.items.map(\.ref.id) == ["a"] && first.hasMore)
        #expect(empty.items.isEmpty && empty.hasMore)
        #expect(last.items.map(\.ref.id) == ["b"] && !last.hasMore)
        #expect(try await pager.next().items.isEmpty)
        #expect(await provider.inputs.count == 3)
    }

    @Test func networkFailureRetriesSameCursorWithoutDuplicatingResults() async throws {
        let provider = try SearchPagerProvider([.init(items: [book("a")], nextCursor: .number(1)), .init(items: [book("b")], nextCursor: .null)])
        let pager = try SourceSearchPager(provider: provider, query: "query")
        _ = try await pager.next()
        await provider.failNext()
        await #expect(throws: SourceDomainError.self) { try await pager.next() }
        #expect(await pager.hasMore)
        #expect(try await pager.next().items.map(\.ref.id) == ["b"])
        #expect(await provider.inputs.map(\.cursor) == [nil, .number(1), .number(1)])
    }

    @Test func repeatedCursorTerminatesWithoutPublishingPartialPage() async throws {
        let provider = try SearchPagerProvider([.init(items: [book("a")], nextCursor: .number(1)), .init(items: [book("b")], nextCursor: .number(1))])
        let pager = try SourceSearchPager(provider: provider, query: "query")
        _ = try await pager.next()
        await #expect(throws: SourceDomainError.self) { try await pager.next() }
        #expect(await pager.hasMore == false)
        #expect(try await pager.next().items.isEmpty)
        #expect(await provider.inputs.count == 2)
    }

    @Test func changedOrMissingRevisionStopsSnapshotPagination() async throws {
        let revisions: [String?] = ["new", nil]
        for revision in revisions {
            let provider = try SearchPagerProvider([
                .init(items: [book("a")], nextCursor: .number(1), revision: "original"),
                .init(items: [book("b")], nextCursor: .null, revision: revision)
            ])
            let pager = try SourceSearchPager(provider: provider, query: "query")
            _ = try await pager.next()
            await #expect(throws: SourceDomainError.self) { try await pager.next() }
            #expect(await pager.hasMore == false)
        }
    }

    @Test func malformedPagesAndBudgetsStopPagination() async throws {
        let invalidPages: [SourceWire.SearchPage] = [
            .init(items: [book("a"),book("a")], nextCursor: .null),
            .init(items: [.init(ref: .init(id: ""), title: "Missing ID")], nextCursor: .null),
            .init(items: [.init(ref: .init(id: "a"), title: "  ")], nextCursor: .null),
            .init(items: [], nextCursor: .null, revision: ""),
            .init(items: [book("a"),book("b")], nextCursor: .null),
            .init(items: [], nextCursor: .number(1))
        ]
        for page in invalidPages {
            let provider = try SearchPagerProvider([page])
            let pager = try SourceSearchPager(provider: provider, query: "query", maximumPages: 1, maximumItems: 1)
            await #expect(throws: SourceDomainError.self) { try await pager.next() }
            #expect(await pager.hasMore == false)
        }
    }

    @Test(.timeLimit(.minutes(1))) func cancellationDoesNotConsumePageAndConcurrentRequestIsRejected() async throws {
        let provider = try SearchPagerProvider([.init(items: [book("a")], nextCursor: .null)])
        let pager = try SourceSearchPager(provider: provider, query: "query")
        await provider.pause()
        let old = Task { try await pager.next() }
        await provider.waitUntilPaused()
        await #expect(throws: SourceDomainError.self) { try await pager.next() }
        old.cancel()
        await provider.resume()
        await #expect(throws: CancellationError.self) { try await old.value }
        #expect(await pager.hasMore)
        #expect(try await pager.next().items.map(\.ref.id) == ["a"])
        #expect(await provider.inputs.map(\.cursor) == [nil, nil])
    }

    @Test func querySessionsKeepIndependentCursors() async throws {
        let provider = try SearchPagerProvider([.init(items: [book("a")], nextCursor: .number(1)), .init(items: [book("b")], nextCursor: .null)])
        let first = try SourceSearchPager(provider: provider, query: "first"), second = try SourceSearchPager(provider: provider, query: "second")
        _ = try await first.next()
        _ = try await second.next()
        _ = try await first.next()
        #expect(await provider.inputs == [.init(query: "first"), .init(query: "second"), .init(query: "first", cursor: .number(1))])
        #expect(await second.hasMore)
        #expect(await first.hasMore == false)
    }
}
