import Foundation
import Testing
import LegadoCore
@testable import LegadoAppModels

private actor FixtureReaderChapterAccess: ReaderChapterAccess {
    struct Request: Equatable, Sendable { let id: String; let reload: Bool }
    private(set) var requests: [Request] = []
    private var pausedID: String?
    private var pending: CheckedContinuation<Void, Never>?
    private var failures: Set<String> = []
    func pause(_ id: String) { pausedID = id }
    func fail(_ id: String) { failures.insert(id) }
    func recover() { failures = [] }
    func waitUntilPaused() async { while pending == nil { await Task.yield() } }
    func release() { pending?.resume(); pending = nil }
    func load(chapterID: String, reload: Bool) async throws -> ReaderChapterSnapshot {
        requests.append(.init(id: chapterID, reload: reload))
        if pausedID == chapterID {
            pausedID = nil
            await withCheckedContinuation { pending = $0 }
        }
        if failures.contains(chapterID) { throw SourceDomainError(.notDownloaded, "本章没有离线副本。") }
        return .init(title: "标题 \(chapterID)", text: "广告正文 \(chapterID)", loadedFromCache: !reload)
    }
}

@MainActor
@Suite("Mature reader chapter port", .timeLimit(.minutes(1)))
struct ReaderChapterPortTests {
    private func model(_ access: FixtureReaderChapterAccess, initialIndex: Int = 1) -> ReaderViewModel {
        let book = Book(bookUrl: "local-book-key", name: "书", author: "作者")
        let chapters = (0..<5).map { BookChapter(url: "opaque:\($0)", title: "第\($0)章", bookUrl: book.bookUrl, index: $0) }
        return ReaderViewModel(book: book, chapters: chapters, initialIndex: initialIndex, chapterAccess: access)
    }

    @Test func currentAdjacentContinuousAndSpeechContentAllUseStableIdentifiers() async {
        let access = FixtureReaderChapterAccess()
        let reader = model(access)
        let rules = [ReplaceRule(id: 1, name: "净化", pattern: "广告", replacement: "")]
        await reader.load(rules: rules)
        #expect(reader.content == "正文 opaque:1")
        #expect(reader.title == "标题 opaque:1")
        #expect(reader.loadedFromCache)
        #expect(reader.currentChapterError == nil)
        await reader.loadAdjacentChapters(rules: rules)
        #expect(reader.previousContent == "正文 opaque:0")
        #expect(reader.continuationContent == "正文 opaque:2")
        #expect(await reader.nextSpeechContent(rules: rules) == "正文 opaque:2")
        await reader.prepareContinuousReading(rules: rules)
        #expect(reader.scrollChapters.map(\.id) == [0, 1, 2, 3])
        #expect(reader.scrollChapters.allSatisfy { !$0.content.contains("广告") && $0.error == nil })
        let requests = await access.requests
        #expect(Set(requests.map(\.id)) == Set(["opaque:0", "opaque:1", "opaque:2", "opaque:3"]))
        #expect(requests.allSatisfy { !$0.reload })
    }

    @Test func explicitReloadAndContinuousRetryReachThePortWithReloadPolicy() async {
        let access = FixtureReaderChapterAccess()
        let reader = model(access)
        await reader.load(rules: [])
        await reader.load(rules: [], forceRefresh: true)
        #expect(!reader.loadedFromCache)
        await reader.prepareContinuousReading(rules: [])
        await reader.retryContinuousChapter(index: 2, rules: [])
        let reloads = await access.requests.filter(\.reload)
        #expect(reloads.map(\.id) == ["opaque:1", "opaque:2"])
        #expect(reader.currentIndex == 1)
    }

    @Test func navigationRejectsALateCurrentChapterResult() async {
        let access = FixtureReaderChapterAccess()
        await access.pause("opaque:1")
        let reader = model(access)
        let old = Task { await reader.load(rules: []) }
        await access.waitUntilPaused()
        reader.select(index: 3, position: 4)
        await reader.load(rules: [])
        await access.release()
        await old.value
        #expect(reader.currentIndex == 3)
        #expect(reader.requestedPosition == 4)
        #expect(reader.content == "广告正文 opaque:3")
        #expect(!reader.isLoading)
    }

    @Test func navigationRejectsLateAdjacentWindows() async {
        let access = FixtureReaderChapterAccess()
        let reader = model(access)
        await reader.load(rules: [])
        await access.pause("opaque:2")
        let old = Task { await reader.loadAdjacentChapters(rules: []) }
        await access.waitUntilPaused()
        reader.select(index: 4)
        await reader.load(rules: [])
        await access.release()
        await old.value
        #expect(reader.currentIndex == 4)
        #expect(reader.previousContent.isEmpty)
        #expect(reader.continuationContent.isEmpty)
        #expect(!reader.isContinuationWindowReady)
    }

    @Test func navigationOrCancellationDiscardsLateSpeechPrefetch() async {
        for cancel in [false, true] {
            let access = FixtureReaderChapterAccess()
            let reader = model(access)
            await access.pause("opaque:2")
            let speech = Task { await reader.nextSpeechContent(rules: []) }
            await access.waitUntilPaused()
            if cancel { speech.cancel() }
            else { reader.select(index: 3) }
            await access.release()
            #expect(await speech.value == nil)
        }
    }

    @Test func cancellingACurrentLoadDoesNotPublishContentOrAnError() async {
        let access = FixtureReaderChapterAccess()
        await access.pause("opaque:1")
        let reader = model(access)
        let load = Task { await reader.load(rules: []) }
        await access.waitUntilPaused()
        load.cancel()
        await access.release()
        await load.value
        #expect(reader.content.isEmpty)
        #expect(reader.diagnostics.isEmpty)
        #expect(!reader.hasLoadedCurrentChapter)
        #expect(!reader.isLoading)
    }

    @Test func anOfflineFailureRemainsVisibleAndContinuousRetryCanRecover() async {
        let access = FixtureReaderChapterAccess()
        await access.fail("opaque:2")
        let reader = model(access)
        await reader.load(rules: [])
        await reader.prepareContinuousReading(rules: [])
        reader.updateContinuousPosition(chapter: 2)
        #expect(reader.currentChapterError == SourceDomainError(.notDownloaded, "本章没有离线副本。").localizedDescription)
        await access.recover()
        await reader.retryContinuousChapter(index: 2, rules: [])
        #expect(reader.currentChapterError == nil)
        #expect(reader.content == "广告正文 opaque:2")
    }

    @Test func legacySourceSwitchCannotReplaceASourcePortSession() async {
        let access = FixtureReaderChapterAccess()
        let reader = model(access)
        let oldBook = reader.book
        let replacement = Book(bookUrl: "legacy-book", name: "另一书", origin: "legacy-source")
        reader.applySourceSwitch(.init(book: replacement, chapters: [], exactChapterMatch: false),
                                 source: .init(bookSourceUrl: "legacy-source", bookSourceName: "旧源"))
        #expect(reader.book == oldBook)
        await reader.load(rules: [])
        #expect(reader.content == "广告正文 opaque:1")
    }
}
