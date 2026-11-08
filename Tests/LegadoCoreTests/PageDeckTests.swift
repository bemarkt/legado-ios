import Foundation
import Testing
@testable import LegadoCore

/// 页序（扁平页表）与双面卷页物理页翻译的回归测试。
///
/// 这两段全是纯算术，却一直是「只能真机试」的部分：拼接顺序错一位，过章就跳页；
/// `nearestIndex` 映射错一格，读者会被上一次的绝对下标带偏；物理页 `2i` / `2i+1`
/// 翻译错一位，观感就是「往后翻跳一页」或「左划翻不动」。放在这里之后每次 CI 必过。
struct PageDeckTests {

    private static func deck(chapterCounts: [(index: Int, pages: Int)], current: Int) -> PageDeck<Int> {
        let chapters = chapterCounts.map { entry in
            PageDeck<Int>.Chapter(
                index: entry.index,
                title: "CHAPTER-\(entry.index)",
                pages: (0..<entry.pages).map { $0 }
            )
        }
        return PageDeck(chapters: chapters, currentChapterIndex: current)
    }

    @Test func stitchedChaptersKeepReadingOrder() {
        let deck = Self.deck(chapterCounts: [(4, 2), (5, 3), (6, 1)], current: 5)
        #expect(deck.count == 6)
        #expect(deck.slots.map(\.location.chapterIndex) == [4, 4, 5, 5, 5, 6])
        #expect(deck.slots.map(\.location.pageIndex) == [0, 1, 0, 1, 2, 0])
        #expect(deck.slots.map(\.payload) == [0, 1, 0, 1, 2, 0])
        #expect(deck.slots[2].chapterTitle == "CHAPTER-5")
        #expect(deck.chapterStarts[4] == 0)
        #expect(deck.chapterStarts[5] == 2)
        #expect(deck.chapterStarts[6] == 5)
    }

    @Test func emptyChapterDoesNotEnterTheDeck() {
        // 相邻章还没排出来时给的是空页表：那一段必须整段消失，页序退化成「只有本章」。
        let deck = Self.deck(chapterCounts: [(4, 0), (5, 3), (6, 0)], current: 5)
        #expect(deck.count == 3)
        #expect(deck.chapterStarts[4] == nil)
        #expect(deck.chapterStarts[6] == nil)
        #expect(deck.currentChapterStart == 0)
        #expect(deck.index(of: PageDeckLocation(chapterIndex: 5, pageIndex: 2)) == 2)
        #expect(deck.isEmpty == false)
        #expect(PageDeck<Int>().isEmpty)
    }

    @Test func chapterBoundaryIsOneAdjacentStep() {
        // 章界在数据层不存在：上一章最后一页的下一格就是下一章第一页。
        let deck = Self.deck(chapterCounts: [(4, 2), (5, 3), (6, 1)], current: 5)
        #expect(deck.lastIndex(inChapter: 4)! + 1 == deck.firstIndex(inChapter: 5)!)
        #expect(deck.lastIndex(inChapter: 5)! + 1 == deck.firstIndex(inChapter: 6)!)
        #expect(deck.pageCount(inChapter: 4) == 2)
        #expect(deck.pageCount(inChapter: 5) == 3)
        #expect(deck.pageCount(inChapter: 6) == 1)
        #expect(deck.pageCount(inChapter: 9) == 0)
        #expect(deck.currentChapterStart == 2)
        #expect(deck.currentChapterEnd() == 4)
        #expect(deck.firstIndex(inChapter: 9) == nil)
        #expect(deck.lastIndex(inChapter: 9) == nil)
    }

    @Test func nearestIndexRemapsByLocation() {
        // 重排之后页数会变，落点必须按坐标重映射，否则读者被旧下标带偏一页。
        let deck = Self.deck(chapterCounts: [(4, 2), (5, 3), (6, 1)], current: 5)
        // ① 坐标存在：原样命中。
        #expect(deck.nearestIndex(to: PageDeckLocation(chapterIndex: 5, pageIndex: 1)) == 3)
        // ② 页号超出该章页数：取该章最后一页，绝不越到下一章。
        #expect(deck.nearestIndex(to: PageDeckLocation(chapterIndex: 5, pageIndex: 9)) == 4)
        // ③ 该章不在页序里（相邻章正文还没到）：返回 nil，调用方据此保留当前页等下一帧。
        #expect(deck.nearestIndex(to: PageDeckLocation(chapterIndex: 9, pageIndex: 0)) == nil)
        // ④ 页号为 0：落在该章首页。
        #expect(deck.nearestIndex(to: PageDeckLocation(chapterIndex: 6, pageIndex: 0)) == 5)
    }

    @Test func physicalFaceRoundTripsTheTag() {
        #expect(PageDeckPaging.Face(pageIndex: 3, isBack: false).tag == 6)
        #expect(PageDeckPaging.Face(pageIndex: 3, isBack: true).tag == 7)
        let back = PageDeckPaging.Face(tag: 7)
        #expect(back.pageIndex == 3)
        #expect(back.isBack)
        let front = PageDeckPaging.Face(tag: 6)
        #expect(front.pageIndex == 3)
        #expect(front.isBack == false)
        #expect(PageDeckPaging.Face(tag: 0).pageIndex == 0)
    }

    @Test func oneSwipeTurnsExactlyOnePage() {
        let count = 10
        // 往前：正面 → 这一张的纸背 → 下一张的正面。
        let front3 = PageDeckPaging.Face(pageIndex: 3, isBack: false)
        let back3 = PageDeckPaging.after(front3, pageCount: count)
        #expect(back3 == PageDeckPaging.Face(pageIndex: 3, isBack: true))
        #expect(PageDeckPaging.after(back3!, pageCount: count) == PageDeckPaging.Face(pageIndex: 4, isBack: false))
        // 往回：正面 → 上一张的纸背 → 上一张的正面。
        let front4 = PageDeckPaging.Face(pageIndex: 4, isBack: false)
        let back3Again = PageDeckPaging.before(front4, pageCount: count)
        #expect(back3Again == PageDeckPaging.Face(pageIndex: 3, isBack: true))
        #expect(PageDeckPaging.before(back3Again!, pageCount: count) == PageDeckPaging.Face(pageIndex: 3, isBack: false))
    }

    @Test func physicalFaceStopsAtTheDeckEdges() {
        let count = 3
        // 最后一页往前划必须到头：给纸就会卷出来卡在那里，章界那一下也通知不到外层。
        #expect(PageDeckPaging.after(PageDeckPaging.Face(pageIndex: 2, isBack: false), pageCount: count) == nil)
        #expect(PageDeckPaging.after(PageDeckPaging.Face(pageIndex: 2, isBack: true), pageCount: count) == nil)
        // 第一页往回划同样到头。
        #expect(PageDeckPaging.before(PageDeckPaging.Face(pageIndex: 0, isBack: false), pageCount: count) == nil)
        #expect(PageDeckPaging.before(PageDeckPaging.Face(pageIndex: 0, isBack: true), pageCount: count) == PageDeckPaging.Face(pageIndex: 0, isBack: false))
        // 空页序一律 nil。
        #expect(PageDeckPaging.after(PageDeckPaging.Face(pageIndex: 0, isBack: false), pageCount: 0) == nil)
        #expect(PageDeckPaging.before(PageDeckPaging.Face(pageIndex: 0, isBack: false), pageCount: 0) == nil)
    }

    @Test func landingOnBackFaceAdvancesOnePage() {
        let count = 10
        // 往前翻落在「当前页的纸背」上 → 下一页。
        #expect(PageDeckPaging.landedIndex(currentIndex: 3, landedTag: PageDeckPaging.Face(pageIndex: 3, isBack: true).tag, pageCount: count) == 4)
        // 往回翻落在「上一张纸的纸背」上 → 那一张纸自己那一页。
        #expect(PageDeckPaging.landedIndex(currentIndex: 4, landedTag: PageDeckPaging.Face(pageIndex: 3, isBack: true).tag, pageCount: count) == 3)
        // 落在正面上 → 就是那一页。
        #expect(PageDeckPaging.landedIndex(currentIndex: 3, landedTag: PageDeckPaging.Face(pageIndex: 4, isBack: false).tag, pageCount: count) == 4)
        // 末页的纸背不许越界：就地停住，绝不给 count。
        #expect(PageDeckPaging.landedIndex(currentIndex: 9, landedTag: PageDeckPaging.Face(pageIndex: 9, isBack: true).tag, pageCount: count) == 9)
        // 越界 tag / 空页序返回 nil。
        #expect(PageDeckPaging.landedIndex(currentIndex: 0, landedTag: 999, pageCount: count) == nil)
        #expect(PageDeckPaging.landedIndex(currentIndex: 0, landedTag: 0, pageCount: 0) == nil)
    }
}
