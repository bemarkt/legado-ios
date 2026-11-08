import ImageIO
import SwiftUI
import UIKit
import XCTest
@testable import Legado

private final class BackgroundPhotoProvider: NSItemProvider, @unchecked Sendable {
    let photoData: Data?
    let photoError: (any Error)?

    init(data: Data?, error: (any Error)? = nil) {
        photoData = data
        photoError = error
        super.init()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var registeredTypeIdentifiers: [String] { ["public.png"] }

    override func loadDataRepresentation(
        forTypeIdentifier typeIdentifier: String,
        completionHandler: @escaping @Sendable (Data?, (any Error)?) -> Void
    ) -> Progress {
        DispatchQueue.global(qos: .userInitiated).async { [photoData, photoError] in
            dispatchPrecondition(condition: .notOnQueue(.main))
            completionHandler(photoData, photoError)
        }
        return Progress(totalUnitCount: 1)
    }
}

@MainActor
final class ReadingPhotoPickerTests: XCTestCase {
    func testPhotoDataReturnedOnBackgroundQueueReachesMainActor() async throws {
        let expected = Data("photo-provider-data".utf8)
        let provider = BackgroundPhotoProvider(data: expected)
        let received = expectation(description: "Photo data delivered on main actor")
        let coordinator = ReadingPhotoPickerController.Coordinator { result in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(try? result?.get(), expected)
            received.fulfill()
        }

        coordinator.loadImage(from: provider)
        await fulfillment(of: [received], timeout: 5)
        withExtendedLifetime(coordinator) {}
    }

    func testPhotoProviderFailureOnBackgroundQueueReachesMainActor() async throws {
        let errors: [(any Error)?] = [CocoaError(.fileReadNoPermission), nil]
        for error in errors {
            let provider = BackgroundPhotoProvider(data: nil, error: error)
            let received = expectation(description: "Photo error delivered on main actor")
            let coordinator = ReadingPhotoPickerController.Coordinator { result in
                XCTAssertTrue(Thread.isMainThread)
                guard case .failure(let failure)? = result else {
                    XCTFail("Expected an import error")
                    received.fulfill()
                    return
                }
                XCTAssertEqual((failure as NSError).domain, NSCocoaErrorDomain)
                XCTAssertEqual((failure as NSError).code, (error as NSError?)?.code ?? NSFileReadCorruptFileError)
                received.fulfill()
            }

            coordinator.loadImage(from: provider)
            await fulfillment(of: [received], timeout: 5)
            withExtendedLifetime(coordinator) {}
        }
    }
}

@MainActor
final class ReaderBackgroundStoreTests: XCTestCase {
    func testLargeBackgroundIsDownsampledOnImportAndLegacyReload() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("background.jpg")
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let data = UIGraphicsImageRenderer(size: CGSize(width: 4096, height: 3072), format: format).jpegData(withCompressionQuality: 0.9) { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 4096, height: 3072))
        }

        for _ in 0..<3 {
            let imported = try ReaderBackgroundStore.save(data, to: target)
            XCTAssertEqual(imported.size.width, CGFloat(ReaderBackgroundStore.maximumPixelSize))
            XCTAssertEqual(imported.size.height / imported.size.width, 0.75, accuracy: 0.001)
            let restored = try XCTUnwrap(ReaderBackgroundStore.load(from: target))
            XCTAssertEqual(restored.size, imported.size)
        }
        try data.write(to: target)
        let legacy = try XCTUnwrap(ReaderBackgroundStore.load(from: target))
        XCTAssertEqual(legacy.size.width, CGFloat(ReaderBackgroundStore.maximumPixelSize))
    }

    func testCorruptReplacementPreservesExistingBackground() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("background.jpg")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 60)).image { context in
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 60))
        }
        _ = try ReaderBackgroundStore.save(try XCTUnwrap(image.pngData()), to: target)
        let saved = try Data(contentsOf: target)

        XCTAssertThrowsError(try ReaderBackgroundStore.save(Data("not an image".utf8), to: target))
        XCTAssertEqual(try Data(contentsOf: target), saved)
        XCTAssertNotNil(ReaderBackgroundStore.load(from: target))
    }

    func testBackgroundPreservesPhotoOrientation() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 60)).image { context in
            UIColor.green.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 60))
        }
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(image.cgImage), [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let saved = try ReaderBackgroundStore.save(data as Data, to: directory.appendingPathComponent("background.jpg"))
        XCTAssertEqual(saved.imageOrientation, .up)
        XCTAssertEqual(saved.size.height / saved.size.width, 2, accuracy: 0.001)
    }
}

@MainActor
final class ReaderBookmarkPersistenceTests: XCTestCase {
    func testBookmarkSurvivesNewActivityAndReaderInstances() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = FileReadingActivityRepository(
            bookmarksURL: directory.appendingPathComponent("bookmarks.json"),
            recordsURL: directory.appendingPathComponent("records.json")
        )
        let book = Book(bookUrl: "demo://saved-bookmark", name: "书", author: "作者")
        let chapters = [BookChapter(url: "demo://chapter", title: "第一章", bookUrl: book.bookUrl, index: 0)]
        let original = ReadingActivityModel(repository: repository, deviceID: "test")
        await original.load()
        await original.addBookmark(book: book, chapter: chapters[0], position: 40, content: String(repeating: "正文", count: 100))
        XCTAssertNil(original.errorMessage)

        let restored = ReadingActivityModel(repository: repository, deviceID: "test")
        await restored.load()
        let reader = ReaderViewModel(demoBook: book, chapters: chapters, initialIndex: 0, content: "正文")
        XCTAssertEqual(reader.bookmarks(at: 40, in: restored.bookmarks).count, 1)
        XCTAssertTrue(reader.bookmarks(at: 80, in: restored.bookmarks).isEmpty)
        await restored.removeBookmark(try XCTUnwrap(restored.bookmarks.first))
        XCTAssertTrue(reader.bookmarks(at: 40, in: restored.bookmarks).isEmpty)
    }
}

@MainActor
final class ReaderScrollGeometryTests: XCTestCase {
    func testPrependingAndRecyclingStayWithinOnePhysicalPixel() async throws {
        let chapters = (4...6).map { chapter($0) }
        let fixture = host(chapters: chapters, active: 5)
        defer { fixture.coordinator.displayLink?.invalidate(); fixture.window.isHidden = true }
        let coordinator = fixture.coordinator, view = fixture.view
        let layout = view.collectionViewLayout as! ReaderContinuousLayout
        let row = try XCTUnwrap(coordinator.blocks.firstIndex { $0.chapter.chapter.id == 5 })
        let id = coordinator.blocks[row].id
        view.setContentOffset(CGPoint(x: 0, y: layout.frames[row].minY + 71.25), animated: false)
        let screenY = layout.frames[row].minY - view.contentOffset.y
        let chapterLayout = coordinator.blocks[row].chapter

        coordinator.parent = surface(chapters: [chapter(2), chapter(3)] + chapters, active: 5)
        coordinator.update(view)
        let insertedRow = try XCTUnwrap(coordinator.blocks.firstIndex { $0.id == id })
        XCTAssertEqual(layout.frames[insertedRow].minY - view.contentOffset.y, screenY, accuracy: 1 / fixture.window.screen.scale)
        XCTAssertTrue(coordinator.blocks[insertedRow].chapter === chapterLayout)

        coordinator.parent = surface(chapters: [chapter(5), chapter(6), chapter(7)], active: 5)
        coordinator.update(view)
        let recycledRow = try XCTUnwrap(coordinator.blocks.firstIndex { $0.id == id })
        XCTAssertEqual(layout.frames[recycledRow].minY - view.contentOffset.y, screenY, accuracy: 1 / fixture.window.screen.scale)
        XCTAssertTrue(coordinator.blocks[recycledRow].chapter === chapterLayout)
    }

    func testAppendingAndNaturalChapterChangesDoNotRebuildVisibleText() async throws {
        let chapters = (0...2).map { chapter($0) }
        let fixture = host(chapters: chapters, active: 0)
        defer { fixture.coordinator.displayLink?.invalidate(); fixture.window.isHidden = true }
        let coordinator = fixture.coordinator, view = fixture.view
        let original = try XCTUnwrap(coordinator.blocks.first?.chapter)
        view.setContentOffset(CGPoint(x: 0, y: 123.75), animated: false)
        let offset = view.contentOffset
        coordinator.parent = surface(chapters: chapters + [chapter(3), chapter(4)], active: 1)
        coordinator.update(view)
        XCTAssertEqual(view.contentOffset.y, offset.y, accuracy: 0.01)
        XCTAssertTrue(coordinator.blocks[0].chapter === original)
        XCTAssertEqual(Set(coordinator.blocks.map { $0.chapter.chapter.id }), Set(0...4))
    }

    func testReflowKeepsTheSameTextLineAtTheSameScreenPosition() async throws {
        let fixture = host(chapters: [chapter(0), chapter(1)], active: 0)
        defer { fixture.coordinator.displayLink?.invalidate(); fixture.window.isHidden = true }
        let coordinator = fixture.coordinator, view = fixture.view
        let old = try XCTUnwrap(coordinator.blocks.first?.chapter)
        let glyph = old.manager.glyphIndexForCharacter(at: old.bodyStart + 200)
        let lineY = old.manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
        let startOfLine = old.manager.characterIndexForGlyph(at: old.manager.glyphIndex(
            for: CGPoint(x: 0, y: lineY + 0.5), in: old.container))
        let layout = view.collectionViewLayout as! ReaderContinuousLayout
        let chapterY = layout.frames[0].minY
        view.setContentOffset(CGPoint(x: 0, y: chapterY + lineY + 3.25), animated: false)
        let previousScreenY = chapterY + lineY - view.contentOffset.y
        coordinator.parent = surface(chapters: [chapter(0), chapter(1)], active: 0, fontSize: 25)
        coordinator.update(view)
        let new = try XCTUnwrap(coordinator.blocks.first?.chapter)
        let newGlyph = new.manager.glyphIndexForCharacter(at: startOfLine)
        let newLineY = new.manager.lineFragmentRect(forGlyphAt: newGlyph, effectiveRange: nil).minY
        XCTAssertEqual(layout.frames[0].minY + newLineY - view.contentOffset.y, previousScreenY, accuracy: 1 / fixture.window.screen.scale)
    }

    func testChunksCoverAllGlyphsAndDoNotRetainTheirChapter() async {
        weak var released: ReaderScrollChapterLayout?
        autoreleasepool {
            let layout = ReaderScrollChapterLayout(chapter: chapter(0), configuration: configuration(), width: 390)
            released = layout
            XCTAssertGreaterThan(layout.blocks.count, 2)
            var nextGlyph = 0
            for block in layout.blocks {
                XCTAssertEqual(block.glyphRange.location, nextGlyph)
                XCTAssertGreaterThan(block.height, 0)
                nextGlyph = NSMaxRange(block.glyphRange)
            }
            XCTAssertEqual(nextGlyph, layout.manager.numberOfGlyphs)
            XCTAssertTrue(layout.storage.string.contains("👨‍👩‍👧‍👦"))
        }
        XCTAssertNil(released, "Recycled TextKit chapter layouts must be released")
    }

    func testShortLastChapterCanReachTheTopWithoutChangingTheRequestedChapter() async throws {
        let short = ReaderScrollChapter(id: 8, title: "短章", content: "仅一行正文")
        let fixture = host(chapters: [chapter(7), short], active: 8)
        defer { fixture.coordinator.displayLink?.invalidate(); fixture.window.isHidden = true }
        let layout = fixture.view.collectionViewLayout as! ReaderContinuousLayout
        let row = try XCTUnwrap(fixture.coordinator.blocks.firstIndex { $0.chapter.chapter.id == 8 })
        XCTAssertEqual(fixture.view.contentOffset.y, layout.frames[row].minY, accuracy: 1 / fixture.window.screen.scale)
    }

    func testRepeatedShortChapterPrependingDoesNotAccumulateOffsetDrift() async throws {
        func short(_ index: Int) -> ReaderScrollChapter {
            .init(id: index, title: "第\(index + 1)章 · 连续阅读", content: "短章正文，继续向下可以自然读到下一章。")
        }
        let fixture = host(chapters: (20...22).map(short), active: 20)
        defer { fixture.coordinator.displayLink?.invalidate(); fixture.window.isHidden = true }
        for first in stride(from: 19, through: 0, by: -1) {
            fixture.coordinator.parent = surface(chapters: (first...22).map(short), active: 20)
            fixture.coordinator.update(fixture.view)
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let layout = fixture.view.collectionViewLayout as! ReaderContinuousLayout
        let row = try XCTUnwrap(fixture.coordinator.blocks.firstIndex { $0.chapter.chapter.id == 20 })
        XCTAssertEqual(fixture.view.contentOffset.y, layout.frames[row].minY,
                       accuracy: 1 / fixture.window.screen.scale)
        XCTAssertTrue(fixture.view.accessibilityValue?.contains("chapter=20 ") == true,
                      fixture.view.accessibilityValue ?? "Missing viewport report")
    }

    func testFractionalPixelBoundariesBelongToTheFollowingRow() {
        let layout = ReaderContinuousLayout()
        let frames = (0..<100).map { CGRect(x: 0, y: CGFloat($0 * 5) / 3, width: 390, height: 5.0 / 3) }
        layout.install(frames: frames, size: CGSize(width: 390, height: 500.0 / 3), correction: 0)
        for index in frames.indices {
            XCTAssertEqual(layout.row(at: frames[index].minY), index)
        }
    }

    func testPrependingPreservesTheChapterBelowTopPadding() async throws {
        func short(_ index: Int) -> ReaderScrollChapter {
            .init(id: index, title: "短章\(index)", content: "短章正文")
        }
        let fixture = host(chapters: [short(20)], active: 20)
        defer { fixture.coordinator.displayLink?.invalidate(); fixture.window.isHidden = true }
        // A short initial chapter can settle at offset zero with its heading
        // still below the reading area's top padding.
        fixture.view.setContentOffset(.zero, animated: false)
        fixture.coordinator.parent = surface(chapters: (19...21).map(short), active: 20)
        fixture.coordinator.update(fixture.view)
        try await Task.sleep(nanoseconds: 10_000_000)
        let layout = fixture.view.collectionViewLayout as! ReaderContinuousLayout
        let row = try XCTUnwrap(fixture.coordinator.blocks.firstIndex { $0.chapter.chapter.id == 20 })
        XCTAssertEqual(layout.frames[row].minY - fixture.view.contentOffset.y, 16,
                       accuracy: 1 / fixture.window.screen.scale)
        XCTAssertTrue(fixture.view.accessibilityValue?.contains("chapter=20 ") == true,
                      fixture.view.accessibilityValue ?? "Missing viewport report")
    }

    private func chapter(_ index: Int) -> ReaderScrollChapter {
        .init(id: index, title: "第\(index)章", content: String(repeating: "正文包含中文、英文 words 与家庭表情👨‍👩‍👧‍👦，用于验证连续阅读的排版和位置。\n", count: 100))
    }

    private func host(chapters: [ReaderScrollChapter], active: Int) -> (window: UIWindow, view: ReaderScrollCollectionView, coordinator: ReaderScrollView.Coordinator) {
        let parent = surface(chapters: chapters, active: active)
        let coordinator = parent.makeCoordinator()
        let view = coordinator.makeView()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let controller = UIViewController()
        controller.view.addSubview(view)
        view.frame = window.bounds
        window.rootViewController = controller
        window.makeKeyAndVisible()
        coordinator.update(view)
        view.layoutIfNeeded()
        return (window, view, coordinator)
    }

    private func surface(chapters: [ReaderScrollChapter], active: Int, fontSize: Double = 20) -> ReaderScrollView {
        .init(configuration: configuration(fontSize: fontSize), chapters: chapters,
              resetID: 0, activeIndex: active, loadingAhead: false, loadingBehind: false,
              onNeedChapters: { _ in }, onPositionChanged: { _, _ in },
              onRetainChapters: { _ in })
    }

    private func configuration(fontSize: Double = 20) -> ReaderTextView {
        .init(text: "", title: "", previousTitle: nil, previousText: "", isPreviousReady: false,
              continuationTitle: nil, continuationText: "", isContinuationReady: false, chapterIndex: 0, isVolume: false,
              fontSize: fontSize, fontPath: "", letterSpacing: 0, lineSpacing: 8, paragraphSpacing: 12,
              paragraphIndent: "　　", paddingLeft: 20, paddingRight: 20, paddingTop: 16, paddingBottom: 16,
              headerInset: 0, footerInset: 0, headerBar: nil, footerBar: nil, fontWeight: 0, titleMode: 0, titleSize: 4,
              titleTopSpacing: 16, titleBottomSpacing: 24, underlineMode: 0,
              justifyLastPage: false, punctuationKinsoku: true, smartParagraphs: false,
              chineseConversion: 0, underlinePattern: 0, paragraphSeparatorLines: 0,
              titleHTMLTemplate: "", titleProjectJSON: "", titleCanvasHeight: 0, isSelectable: false,
              fullJustify: true, pageAnimation: 3, isEInkMode: false, clickActions: Array(repeating: 0, count: 9),
              backgroundColor: .white, backgroundImage: nil, foregroundColor: .black, requestedPosition: 0, jumpPosition: nil,
              renderRevision: 0, readerPosition: .constant(0), pageRanges: .constant([]),
              currentPage: .constant(1), totalPages: .constant(1), isAutoReading: false,
              isAutoReadPaused: false, isLoadingNextChapter: false, secondsPerScreen: 10,
              onReachedEnd: { _ in }, onReachedStart: { _ in }, onEnteredPrevious: { _ in },
              onEnteredContinuation: { _ in }, onDeferredRender: {}, onCancelNextLoading: {},
              onPageChanged: {}, onTapAction: { _ in }, onCurlPublished: { _ in })
    }
}


@MainActor
private final class CurlRegressionWindow: UIWindow {
    override var safeAreaInsets: UIEdgeInsets {
        UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0)
    }
}

@MainActor
final class ReaderCurlProgressTests: XCTestCase {
    @MainActor
    private final class State {
        var position = 0
        var progress: [ReaderPageProgress] = []
        var enteredPrevious: Int?
        var pageChanges = 0
    }

    @MainActor
    private struct Fixture {
        let window: UIWindow
        let host: UIViewController
        let textView: UITextView
        let coordinator: ReaderTextView.Coordinator
        let state: State

        func close() {
            coordinator.invalidate()
            window.isHidden = true
        }
    }

    private var content: String {
        (0..<80).map { "第\($0)段。" + String(repeating: "测试原文坐标与退出重新进入后的页码。", count: 8) }
            .joined(separator: "\r\n\r\n")
    }

    private func fixture(height: CGFloat, position: Int, text: String? = nil, previous: Bool = false, chapterIndex: Int = 4) -> Fixture {
        let state = State()
        state.position = position
        let body = text ?? content
        let reader = ReaderTextView(
            text: body, title: "当前章", previousTitle: previous ? "上一章" : nil,
            previousText: previous ? content : "", isPreviousReady: previous,
            continuationTitle: nil, continuationText: "", isContinuationReady: false,
            chapterIndex: chapterIndex, isVolume: false, fontSize: 22, fontPath: "",
            letterSpacing: 0, lineSpacing: 4, paragraphSpacing: 8, paragraphIndent: "　　",
            paddingLeft: 18, paddingRight: 18, paddingTop: 6, paddingBottom: 31,
            headerInset: 0, footerInset: 0, headerBar: nil, footerBar: nil,
            fontWeight: 0, titleMode: 2, titleSize: 26, titleTopSpacing: 0, titleBottomSpacing: 0,
            underlineMode: 0, justifyLastPage: false, punctuationKinsoku: true,
            smartParagraphs: true, chineseConversion: 0, underlinePattern: 0, paragraphSeparatorLines: 0,
            titleHTMLTemplate: "", titleProjectJSON: "", titleCanvasHeight: 0,
            isSelectable: false, fullJustify: false, pageAnimation: 2, isEInkMode: false,
            clickActions: [], backgroundColor: .white, backgroundImage: nil, foregroundColor: .black,
            requestedPosition: position, requestedPage: 15, requestedPageCount: 17,
            jumpPosition: nil, renderRevision: 0,
            readerPosition: Binding(get: { state.position }, set: { state.position = $0 }),
            pageRanges: .constant([]), currentPage: .constant(1), totalPages: .constant(1),
            isAutoReading: false, isAutoReadPaused: false, isLoadingNextChapter: false, secondsPerScreen: 10,
            onReachedEnd: { _ in }, onReachedStart: { _ in },
            onEnteredPrevious: { state.enteredPrevious = $0 }, onEnteredContinuation: { _ in },
            onDeferredRender: {}, onCancelNextLoading: {}, onPageChanged: { state.pageChanges += 1 },
            onPageSettled: { state.progress.append($0); state.position = $0.position },
            onTapAction: { _ in }, onCurlPublished: { _ in }
        )
        let coordinator = reader.makeCoordinator()
        let window = CurlRegressionWindow(frame: CGRect(x: 0, y: 0, width: 440, height: 956))
        let host = UIViewController()
        window.rootViewController = host
        window.isHidden = false
        host.view.frame = window.bounds
        let textView = UITextView(usingTextLayoutManager: false)
        textView.frame = CGRect(x: 0, y: 62, width: 440, height: height)
        textView.textContainerInset = UIEdgeInsets(top: 6, left: 18, bottom: 31, right: 18)
        textView.text = body
        host.view.addSubview(textView)
        return Fixture(window: window, host: host, textView: textView, coordinator: coordinator, state: state)
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    func testEntryAndReentryUseTheSamePageDespiteTransientTextViewHeight() async throws {
        let first = fixture(height: 811, position: 4200, previous: true)
        defer { first.close() }
        first.coordinator.syncNativeCurl(in: first.textView)
        await drainMainQueue()
        let saved = try XCTUnwrap(first.state.progress.last)
        XCTAssertGreaterThan(saved.pageIndex, 0)
        first.textView.frame.size.height = 860
        first.coordinator.syncNativeCurl(in: first.textView)
        await drainMainQueue()
        XCTAssertEqual(first.state.progress.last, saved)
        first.close()

        let reopened = fixture(height: 860, position: saved.position, previous: true)
        defer { reopened.close() }
        reopened.coordinator.syncNativeCurl(in: reopened.textView)
        await drainMainQueue()
        XCTAssertEqual(reopened.state.progress.last, saved)
    }

    func testHiddenTextCannotWriteProgressBeforeMountOrAfterTeardown() async {
        let reader = fixture(height: 811, position: 4200)
        defer { reader.close() }
        reader.textView.contentOffset.y = 400
        reader.coordinator.scrollViewDidScroll(reader.textView)
        await drainMainQueue()
        XCTAssertEqual(reader.state.position, 4200)
        XCTAssertEqual(reader.state.pageChanges, 0)
        reader.coordinator.syncNativeCurl(in: reader.textView)
        await drainMainQueue()
        let saved = reader.state.position
        reader.close()
        reader.textView.contentOffset.y = 0
        reader.coordinator.scrollViewDidScroll(reader.textView)
        await drainMainQueue()
        XCTAssertEqual(reader.state.position, saved)
    }

    func testCompletedTurnPersistsTheNewPageBeforeExitAndReentry() async throws {
        let reader = fixture(height: 860, position: 4200)
        defer { reader.close() }
        reader.coordinator.syncNativeCurl(in: reader.textView)
        await drainMainQueue()
        let initial = try XCTUnwrap(reader.state.progress.last)
        let controller = try XCTUnwrap(reader.host.children.compactMap { $0 as? ReaderNativeCurlController }.first)
        XCTAssertTrue(controller.turn(forward: true, animated: false))
        await drainMainQueue()
        let saved = try XCTUnwrap(reader.state.progress.last)
        XCTAssertEqual(saved.pageIndex, initial.pageIndex + 1)
        XCTAssertGreaterThan(saved.position, initial.position)
        reader.close()
        let reopened = fixture(height: 811, position: saved.position)
        defer { reopened.close() }
        reopened.coordinator.syncNativeCurl(in: reopened.textView)
        await drainMainQueue()
        XCTAssertEqual(reopened.state.progress.last, saved)
    }

    func testSinglePageEntryIgnoresStaleStoredPageNumber() async throws {
        let reader = fixture(height: 811, position: 0, text: "只有一页的正文。")
        defer { reader.close() }
        reader.coordinator.syncNativeCurl(in: reader.textView)
        await drainMainQueue()
        let saved = try XCTUnwrap(reader.state.progress.last)
        XCTAssertEqual(saved, ReaderPageProgress(chapterIndex: 4, pageIndex: 0, pageCount: 1, position: 0))
    }

    func testCancelledTurnDoesNotCommitAndCrossChapterTurnSavesActualLastPage() async throws {
        let reader = fixture(height: 860, position: 0, previous: true)
        defer { reader.close() }
        reader.coordinator.syncNativeCurl(in: reader.textView)
        await drainMainQueue()
        let controller = try XCTUnwrap(reader.host.children.compactMap { $0 as? ReaderNativeCurlController }.first)
        let initial = reader.state.progress.last
        controller.pageViewController(controller, willTransitionTo: controller.viewControllers ?? [])
        reader.coordinator.syncNativeCurl(in: reader.textView)
        controller.pageViewController(controller, didFinishAnimating: true, previousViewControllers: [], transitionCompleted: false)
        await drainMainQueue()
        XCTAssertEqual(reader.state.progress.last, initial)
        XCTAssertNil(reader.state.enteredPrevious)

        XCTAssertTrue(controller.turn(forward: false, animated: false))
        await drainMainQueue()
        let saved = try XCTUnwrap(reader.state.progress.last)
        XCTAssertEqual(saved.chapterIndex, 3)
        XCTAssertEqual(saved.pageIndex, saved.pageCount - 1)
        XCTAssertGreaterThan(saved.position, 0)
        XCTAssertEqual(reader.state.enteredPrevious, saved.position)
        reader.close()
        let reopened = fixture(height: 811, position: saved.position, chapterIndex: saved.chapterIndex)
        defer { reopened.close() }
        reopened.coordinator.syncNativeCurl(in: reopened.textView)
        await drainMainQueue()
        XCTAssertEqual(reopened.state.progress.last, saved)
    }

    func testViewportPaginationAndDrawingHaveIdenticalContentHeight() {
        let viewport = ReaderCurlViewport(
            windowBounds: CGRect(x: 0, y: 0, width: 440, height: 956),
            safeAreaInsets: UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0), maximumWidth: 760
        )
        let padding = UIEdgeInsets(top: 6, left: 18, bottom: 31, right: 18)
        let insets = viewport.contentInsets(padding: padding)
        XCTAssertEqual(viewport.rect.height, 860)
        XCTAssertEqual(insets.top, 68)
        XCTAssertEqual(insets.bottom, 65)
        XCTAssertEqual(viewport.rect.height - padding.top - padding.bottom, 956 - insets.top - insets.bottom)
        let tablet = ReaderCurlViewport(
            windowBounds: CGRect(x: 0, y: 0, width: 1024, height: 1366),
            safeAreaInsets: .zero, maximumWidth: 760
        )
        XCTAssertEqual(tablet.rect.width, 760)
        XCTAssertEqual(tablet.rect.minX, 132)
    }

    func testEveryPageStartPointsAtItsDisplayedFirstLineInTheOriginalText() {
        let layout = ReaderPaginationLayout(
            containerSize: CGSize(width: 440, height: 860), fontSize: 22,
            lineSpacing: 4, letterSpacing: 0, firstLineIndent: 2, paragraphSpacing: 8,
            weightLevel: 1, fontPostScriptName: "PingFangSC-Regular", fontBoldPostScriptName: "",
            punctuationKinsoku: true, headerEnabled: false, footerEnabled: false,
            headerOffset: 0, footerOffset: 0, paddingTop: 6, paddingBottom: 31,
            paddingLeft: 18, paddingRight: 18, chapterTitleScale: 1, titleHidden: true
        )
        let text = "\r\n\r\n" + content
        let built = ReaderCurlPageBuilder.build(ReaderCurlPageBuildInput(
            blocks: ReaderCurlPageBuilder.blocks(from: text, smartParagraphs: true),
            title: nil, layout: layout, alignment: .leading, underline: false, underlineColor: nil,
            textColor: .black, backgroundColor: .white, backgroundImage: nil,
            contentInsets: UIEdgeInsets(top: 68, left: 18, bottom: 65, right: 18),
            contentWidth: CGFloat(layout.usableWidth), header: nil, footer: nil
        ))
        XCTAssertGreaterThan(built.sheets.count, 2)
        XCTAssertEqual(built.startCharacters.count, built.sheets.count)
        let source = text as NSString
        for page in 1..<built.sheets.count {
            guard let firstLine = built.sheets[page].lines.first else { XCTFail("Empty page"); continue }
            let start = built.startCharacters[page]
            XCTAssertEqual(source.substring(with: NSRange(location: start, length: firstLine.utf16.count)), firstLine)
            XCTAssertEqual(ReaderPositionResolver.pageIndex(position: start, startCharacters: built.startCharacters), page)
        }
    }

    func testBlocksPreserveOriginalUTF16OffsetsAcrossBlankLinesAndSmartSplits() {
        let text = "\r\n  \r\n第一段😀。\r\n\r\n" + String(repeating: "第二段内容😀。", count: 60)
        let source = text as NSString
        let blocks = ReaderCurlPageBuilder.blocks(from: text, smartParagraphs: true)
        XCTAssertGreaterThan(blocks.count, 2)
        for block in blocks {
            XCTAssertEqual(source.substring(with: NSRange(location: block.charStart, length: block.text.utf16.count)), block.text)
        }
    }
}
