import Foundation
import SQLite3
import Testing
@testable import LegadoCore

struct SourceReadingStateTests {
    private struct Fixture {
        let root: URL
        let url: URL
        let archive: SourceArchive
        let book: SourceBookKey
        let other: SourceBookKey
        func anchor(_ book: SourceBookKey? = nil, offset: Int = 2) throws -> SourceReadingAnchor {
            .init(chapter: try .init(book: book ?? self.book, chapterID: "stable-chapter"),
                  document: try ChapterNormalizer.normalize(.init(body: .text(.init(text: "A 😀 paragraph.\n\nAnother paragraph.")))), offsetUTF16: offset)
        }
    }
    private func fixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reading-state-\(UUID())")
        let url = root.appendingPathComponent("native.sqlite3"), archive = try SourceArchive(url: url)
        let book = try SourceBookKey(scope: .init(installationID: UUID()), bookID: "book")
        let other = try SourceBookKey(scope: .init(installationID: UUID()), bookID: "book")
        for key in [book, other] {
            try await archive.saveBook(.init(key: key, details: .init(ref: .init(id: key.bookID), title: "Same title", author: "Same author")))
        }
        return .init(root: root, url: url, archive: archive, book: book, other: other)
    }
    private func sql(_ query: String, at url: URL) throws {
        var raw: OpaquePointer?
        guard sqlite3_open(url.path, &raw) == SQLITE_OK, let raw else { throw SourceDomainError(.unavailable, "Fixture database") }
        defer { sqlite3_close(raw) }
        guard sqlite3_exec(raw, query, nil, nil, nil) == SQLITE_OK else { throw SourceDomainError(.invalidData, "Fixture SQL") }
    }

    @Test func independentPreferencePatchesSurviveReopeningAndDoNotMergeSameNamedBooks() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let second = try SourceArchive(url: f.url)
        async let a = f.archive.changeReaderPreference(.useReplaceRules(false), book: f.book)
        async let b = second.changeReaderPreference(.pageAnimation(2), book: f.book)
        _ = try await (a, b)
        try await f.archive.changeReaderPreference(.ttsEngine("engine-id"), book: f.book)
        let reopened = try SourceArchive(url: f.url)
        #expect(try await reopened.readerPreferences(book: f.book) == .init(useReplaceRules: false, pageAnimation: 2, ttsEngine: "engine-id"))
        #expect(try await reopened.readerPreferences(book: f.other) == .init())
        try await reopened.changeReaderPreference(.pageAnimation(nil), book: f.book)
        let reset = try await reopened.readerPreferences(book: f.book)
        #expect(reset.pageAnimation == nil); #expect(reset.useReplaceRules == false)
        await #expect(throws: SourceDomainError.self) { try await reopened.changeReaderPreference(.pageAnimation(999), book: f.book) }
        #expect(try await reopened.readerPreferences(book: f.book) == reset)
    }

    @Test func bookmarkEditsRejectStaleWritersAndDeletedNotesCannotReappear() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let otherWindow = try SourceArchive(url: f.url)
        let saved = try await f.archive.saveReaderBookmark(anchor: f.anchor(), chapterTitle: "Chapter", selectedText: "😀", note: "Original")
        let edited = try await otherWindow.saveReaderBookmark(id: saved.id, anchor: saved.anchor, chapterTitle: saved.chapterTitle,
            selectedText: saved.selectedText, note: "Changed", expectedRevision: saved.revision)
        #expect(saved.revision != edited.revision); #expect(saved.createdAt == edited.createdAt)
        await #expect(throws: SourceDomainError.self) {
            try await f.archive.saveReaderBookmark(id: saved.id, anchor: saved.anchor, chapterTitle: "Chapter", selectedText: "",
                note: "Stale", expectedRevision: saved.revision)
        }
        #expect(try await f.archive.readerBookmarks(book: f.book) == [edited])
        #expect(try await f.archive.readerBookmarks(book: f.other).isEmpty)
        try await f.archive.removeReaderBookmark(id: edited.id, book: f.book, expectedRevision: edited.revision)
        await #expect(throws: SourceDomainError.self) {
            try await otherWindow.saveReaderBookmark(id: edited.id, anchor: edited.anchor, chapterTitle: "Chapter", selectedText: "",
                expectedRevision: edited.revision)
        }
        #expect(try await SourceArchive(url: f.url).readerBookmarks(book: f.book).isEmpty)
    }

    @Test func readingCheckpointsAreIdempotentAndNewReaderRejectsLateOldProgress() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let session = try await f.archive.beginReaderSession(book: f.book)
        let first = SourceReaderCheckpoint(session: session, sequence: 1, elapsedMilliseconds: 1200, anchor: try f.anchor())
        try await f.archive.saveReaderCheckpoint(first)
        try await f.archive.saveReaderCheckpoint(first)
        #expect(try await f.archive.readerHistory(book: f.book) == [first])
        let next = SourceReaderCheckpoint(session: session, sequence: 2, elapsedMilliseconds: 2500, anchor: try f.anchor(offset: 9))
        try await f.archive.saveReaderCheckpoint(next)
        await #expect(throws: SourceDomainError.self) { try await f.archive.saveReaderCheckpoint(first) }
        #expect(try await f.archive.anchor(book: f.book) == next.anchor)
        let reopened = try SourceArchive(url: f.url)
        let newSession = try await reopened.beginReaderSession(book: f.book)
        await #expect(throws: SourceDomainError.self) {
            try await f.archive.saveReaderCheckpoint(.init(session: session, sequence: 3, elapsedMilliseconds: 3000, anchor: try f.anchor(offset: 1)))
        }
        let terminal = SourceReaderCheckpoint(session: newSession, sequence: 1, elapsedMilliseconds: 500, anchor: try f.anchor(offset: 16), ended: true)
        try await reopened.saveReaderCheckpoint(terminal)
        try await reopened.saveReaderCheckpoint(terminal)
        await #expect(throws: SourceDomainError.self) {
            try await reopened.saveReaderCheckpoint(.init(session: newSession, sequence: 2, elapsedMilliseconds: 600))
        }
        #expect(try await f.archive.anchor(book: f.book) == terminal.anchor)
        #expect(try await f.archive.readerHistory(book: f.book).reduce(0) { $0 + $1.elapsedMilliseconds } == 3000)
        #expect(try await f.archive.readerHistory(book: f.other).isEmpty)
    }

    @Test func checkpointAndAnchorRollBackTogetherAndCanRetryTheSameValue() async throws {
        let f = try await fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let session = try await f.archive.beginReaderSession(book: f.book)
        try sql("CREATE TRIGGER fail_anchor BEFORE INSERT ON records WHEN NEW.namespace='anchor' BEGIN SELECT RAISE(ABORT,'fixture failure'); END;", at: f.url)
        let value = SourceReaderCheckpoint(session: session, sequence: 1, elapsedMilliseconds: 1000, anchor: try f.anchor())
        await #expect(throws: SourceDomainError.self) { try await f.archive.saveReaderCheckpoint(value) }
        #expect(try await f.archive.anchor(book: f.book) == nil)
        #expect(try await f.archive.readerHistory(book: f.book).first?.sequence == 0)
        try sql("DROP TRIGGER fail_anchor;", at: f.url)
        try await f.archive.saveReaderCheckpoint(value)
        #expect(try await f.archive.readerHistory(book: f.book) == [value])
        #expect(try await f.archive.anchor(book: f.book) == value.anchor)
        await #expect(throws: SourceDomainError.self) {
            try await f.archive.saveReaderCheckpoint(.init(session: session, sequence: 2, elapsedMilliseconds: 1500, anchor: try f.anchor(f.other)))
        }
        #expect(try await f.archive.readerHistory(book: f.book) == [value])
    }
}
