import Foundation

/// 一页在「整本书页序」里的坐标：第几章第几页（都从 0 起）。
public struct PageDeckLocation: Hashable, Sendable {
    public let chapterIndex: Int
    public let pageIndex: Int

    public init(chapterIndex: Int, pageIndex: Int) {
        self.chapterIndex = chapterIndex
        self.pageIndex = pageIndex
    }
}

/// 拼接好的扁平页序：上一章各页 + 本章各页 + 下一章各页（哪章没排进来就少哪段）。
///
/// 章界在数据层不存在 —— 翻页层只认 `slots` 的下标，`before` / `after` 就是
/// `index - 1` / `index + 1`。跨章于是退化成一次普通拖拽卷页：跟手、可取消、
/// 可反向，动画曲线与章内完全同源，不再需要任何程序化转场。
///
/// 参照 InkShelf `ReaderPageCatalog`：那边全书一份扁平页序 + 坐标反查，章界只在
/// UI 层表现为「下一页」。这里保留同样的形态，但按需只拼「上一章 + 本章 + 下一章」。
///
/// 放在 `LegadoCore` 而不是 App 里的理由：拼接顺序、章界相邻、`nearestIndex`
/// 重映射、章内页码全是纯算术，此前因为挂在 UIKit 文件里而无法被 SwiftPM 的
/// 测试 job 覆盖，只能每次真机试。抽到这里之后由 `PageDeckTests` 每次 CI 必过。
public struct PageDeck<Payload> {

    /// 页序里的一页：坐标 + 所属章标题 + 这一页的载荷（App 侧是「一页纸」）。
    public struct Slot {
        public let location: PageDeckLocation
        public let chapterTitle: String
        public let payload: Payload

        public init(location: PageDeckLocation, chapterTitle: String, payload: Payload) {
            self.location = location
            self.chapterTitle = chapterTitle
            self.payload = payload
        }
    }

    /// 拼进来的一章：章下标 + 标题 + 这一章的页表（未加载时给空数组）。
    public struct Chapter {
        public let index: Int
        public let title: String
        public let pages: [Payload]

        public init(index: Int, title: String, pages: [Payload]) {
            self.index = index
            self.title = title
            self.pages = pages
        }
    }

    public private(set) var slots: [Slot] = []
    public private(set) var currentChapterIndex: Int = 0
    /// 章下标 → 该章第一页在 `slots` 里的绝对下标。
    public private(set) var chapterStarts: [Int: Int] = [:]
    /// 页坐标 → 绝对下标。
    private var indexByLocation: [PageDeckLocation: Int] = [:]

    public init() {}

    public init(chapters: [Chapter], currentChapterIndex: Int) {
        var slots: [Slot] = []
        var starts: [Int: Int] = [:]
        var lookup: [PageDeckLocation: Int] = [:]
        // 空页表的章不进页序：相邻章还没加载时，页序自然退化成「只有本章」，
        // 不会多出一段空白帧，也不会让下标映射错位。
        for chapter in chapters where !chapter.pages.isEmpty {
            starts[chapter.index] = slots.count
            for (pageIndex, payload) in chapter.pages.enumerated() {
                let location = PageDeckLocation(chapterIndex: chapter.index, pageIndex: pageIndex)
                lookup[location] = slots.count
                slots.append(Slot(location: location, chapterTitle: chapter.title, payload: payload))
            }
        }
        self.slots = slots
        self.currentChapterIndex = currentChapterIndex
        self.chapterStarts = starts
        self.indexByLocation = lookup
    }

    public var isEmpty: Bool { slots.isEmpty }
    public var count: Int { slots.count }

    public func slot(at index: Int) -> Slot? {
        slots.indices.contains(index) ? slots[index] : nil
    }

    public func index(of location: PageDeckLocation) -> Int? { indexByLocation[location] }

    /// 本章第一页的绝对下标（本章没排进来时返回 nil）。
    public var currentChapterStart: Int? { chapterStarts[currentChapterIndex] }

    /// 本章最后一页的绝对下标（含）。
    ///
    /// 走显式循环而不是 `chapterStarts.filter{...}.values.min()`：`Dictionary.filter`
    /// 的返回类型依赖标准库版本，这里不值得赌，一次写准。
    public func currentChapterEnd() -> Int? {
        guard let start = chapterStarts[currentChapterIndex] else { return nil }
        var offset = start
        var end = start
        while offset < slots.count, slots[offset].location.chapterIndex == currentChapterIndex {
            end = offset
            offset += 1
        }
        return end
    }

    /// 把某一页坐标落到最近的合法下标：同章里取不超过它的最后一页，没有就取该章首页。
    ///
    /// 换章/重排之后页表会变（页数、分页点都可能不同），落点必须按坐标重新映射一次，
    /// 否则读者会被「上一次的绝对下标」带偏一页。
    public func nearestIndex(to location: PageDeckLocation) -> Int? {
        if let exact = indexByLocation[location] { return exact }
        guard let start = chapterStarts[location.chapterIndex] else { return nil }
        var candidate = start
        var offset = start
        while offset < slots.count, slots[offset].location.chapterIndex == location.chapterIndex {
            if slots[offset].location.pageIndex <= location.pageIndex { candidate = offset }
            offset += 1
        }
        return candidate
    }

    public func firstIndex(inChapter chapterIndex: Int) -> Int? { chapterStarts[chapterIndex] }

    /// 某一章有多少页（该章没排进页序时返回 0）。
    ///
    /// 页内栏的 `{page}` / `{pages}` 必须是「章内页码」，不是整卷绝对下标：
    /// 页序把上一章、本章、下一章拼在一起之后，绝对下标一跨章就等于整本进度，
    /// 直接拿来盖章，页眉会显示成「第 27 页 / 共 41 页」这种读者对不上的数。
    public func pageCount(inChapter chapterIndex: Int) -> Int {
        guard let start = chapterStarts[chapterIndex] else { return 0 }
        var offset = start
        while offset < slots.count, slots[offset].location.chapterIndex == chapterIndex { offset += 1 }
        return offset - start
    }

    public func lastIndex(inChapter chapterIndex: Int) -> Int? {
        guard let start = chapterStarts[chapterIndex] else { return nil }
        var offset = start
        var last = start
        while offset < slots.count, slots[offset].location.chapterIndex == chapterIndex {
            last = offset
            offset += 1
        }
        return last
    }
}

/// 双面卷页的「物理页 → 内容页」翻译。
///
/// `front(i)` 的物理编号是 `2i`、`back(i)` 是 `2i + 1`。落地在纸背上时，往前翻
/// 表示「这一张纸已经翻过去了」→ 下一页；往回翻表示「这是上一张纸」→ 那一张纸
/// 自己那一页。错一位的观感就是「往后翻跳一页」或「左划翻不动」，所以这段算术
/// 必须被测试覆盖，不能只靠真机试。
public enum PageDeckPaging {

    /// 一张纸的一个面：内容页号 + 是不是纸背。
    public struct Face: Hashable, Sendable {
        public let pageIndex: Int
        public let isBack: Bool

        public init(pageIndex: Int, isBack: Bool) {
            self.pageIndex = pageIndex
            self.isBack = isBack
        }

        /// 物理页编号：正面 = 2i、纸背 = 2i + 1。
        public var tag: Int { pageIndex * 2 + (isBack ? 1 : 0) }

        public init(tag: Int) {
            self.pageIndex = tag / 2
            self.isBack = tag % 2 == 1
        }
    }

    /// 往回翻的下一个面；nil 表示页序到头。
    public static func before(_ face: Face, pageCount: Int) -> Face? {
        guard pageCount > 0 else { return nil }
        // 从纸背往回翻 = 回到同一页的正面。
        if face.isBack { return Face(pageIndex: face.pageIndex, isBack: false) }
        let previous = face.pageIndex - 1
        guard previous >= 0, previous < pageCount else { return nil }
        return Face(pageIndex: previous, isBack: true)
    }

    /// 往前翻的下一个面；nil 表示页序到头。
    public static func after(_ face: Face, pageCount: Int) -> Face? {
        guard pageCount > 0 else { return nil }
        // 从纸背往前翻 = 下一张纸的正面。
        if face.isBack {
            let next = face.pageIndex + 1
            guard next < pageCount else { return nil }
            return Face(pageIndex: next, isBack: false)
        }
        guard face.pageIndex + 1 < pageCount else { return nil }
        return Face(pageIndex: face.pageIndex, isBack: true)
    }

    /// 落地在某个物理页上时，内容页号应该是第几页。
    ///
    /// 这是双面卷页唯一的记账点：落在纸背上是「这一张纸已经翻过去了」，
    /// 往前翻就是下一页；往回翻（落在上一张纸的纸背）就是那一张纸自己那一页。
    public static func landedIndex(currentIndex: Int, landedTag: Int, pageCount: Int) -> Int? {
        guard pageCount > 0 else { return nil }
        let face = Face(tag: landedTag)
        guard face.pageIndex >= 0, face.pageIndex < pageCount else { return nil }
        if face.isBack, face.pageIndex == currentIndex, face.pageIndex + 1 < pageCount {
            return face.pageIndex + 1
        }
        return face.pageIndex
    }
}
