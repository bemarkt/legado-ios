import CoreText
import Foundation

/// 行级正文块：分页结果与绘制层共用这一份结构。
///
/// `imageUrl == "p_end"` 表示这一行是段末行：段间距、段末分隔线、非两端对齐都看它。
/// `paragraphId` / `charStart` 记录这一行来自哪个原始段落、段内字符起点，
/// 进度换算与长按命中都靠它们，不靠字符串反查。
struct ReaderContentLine: Identifiable, Equatable, Sendable {
    let id: Int
    var isImage: Bool = false
    var text: String = ""
    var imageUrl: String? = nil
    var paragraphId: Int = 0
    var charStart: Int = 0

    var isParagraphEnd: Bool { imageUrl == "p_end" }
}

/// 分页需要的全部排版参数。
///
/// 做成值类型是为了能安全地丢到后台队列：计算期间用户继续拖滑杆，
/// 后台读到的也只会是完整的一份旧参数，不会读到半新半旧的配置。
struct ReaderPaginationLayout: Sendable, Equatable {
    var version: Int = 0
    var containerSize: CGSize
    var fontSize: CGFloat
    var lineSpacing: CGFloat
    var letterSpacing: CGFloat
    var firstLineIndent: CGFloat
    var paragraphSpacing: CGFloat
    var weightLevel: Int
    var fontPostScriptName: String
    var fontBoldPostScriptName: String
    var punctuationKinsoku: Bool
    var headerEnabled: Bool
    var footerEnabled: Bool
    var headerOffset: CGFloat
    var footerOffset: CGFloat
    var paddingTop: CGFloat
    var paddingBottom: CGFloat
    var paddingLeft: CGFloat
    var paddingRight: CGFloat
    var chapterTitleScale: CGFloat
    var titleHidden: Bool

    /// 行高口径：字号 × 1.25 + 行距。分页累加与绘制取位都用它，不许有第二个算法。
    var lineHeight: CGFloat { fontSize * 1.25 + lineSpacing }

    /// 断行的宽度必须和渲染时用的一致，不然一行排得比页宽，右边就被切掉。
    var usableWidth: Double {
        Double(max(200, containerSize.width - paddingLeft - paddingRight))
    }
}

/// 阅读页分页的布局版本，以及「哪些章还没按当前布局排过」。
///
/// 排版参数（字号、行距、边距……）每次变化就推进一个版本号。章节分页完成后
/// 记下当时的版本；版本对不上就是脏章，等真正切到 / 预取到这一章时再重排。
/// 纯值类型，不碰 CoreText，方便单测。
struct PaginationLayoutTracker: Equatable, Sendable {
    /// 当前布局版本。每次排版参数变化都会 +1。
    private(set) var layoutVersion: Int
    /// 章节下标 → 这份 pages 是按哪个布局版本排出来的。
    private var paginatedVersions: [Int: Int]

    init(layoutVersion: Int = 0, paginatedVersions: [Int: Int] = [:]) {
        self.layoutVersion = layoutVersion
        self.paginatedVersions = paginatedVersions
    }

    /// 排版参数变了：推进版本，所有旧分页自动变脏。返回新版本号。
    @discardableResult
    mutating func advanceLayout() -> Int {
        layoutVersion += 1
        return layoutVersion
    }

    func paginatedVersion(of chapterIndex: Int) -> Int? {
        paginatedVersions[chapterIndex]
    }

    func isDirty(_ chapterIndex: Int) -> Bool {
        paginatedVersions[chapterIndex] != layoutVersion
    }

    /// 后台任务算完回来时先过这一关：版本已经翻篇的结果直接丢掉。
    func acceptsResult(version: Int) -> Bool {
        version == layoutVersion
    }

    /// 记录某一章已经按 `version` 排好。旧版本的结果不能把章洗白。
    mutating func markPaginated(_ chapterIndex: Int, version: Int) {
        guard version == layoutVersion else { return }
        paginatedVersions[chapterIndex] = version
    }

    mutating func forget(_ chapterIndex: Int) {
        paginatedVersions.removeValue(forKey: chapterIndex)
    }

    mutating func forgetAll() {
        paginatedVersions.removeAll()
    }

    /// 给定候选章节，按原顺序挑出还没按当前布局排过的。
    func dirtyChapters(in candidates: [Int]) -> [Int] {
        candidates.filter { isDirty($0) }
    }

    /// 布局变化后立刻重排的章节：当前章优先，其次是预取邻居。
    func repaginationPriority(current: Int, neighbors: [Int], available: [Int]) -> [Int] {
        let availableSet = Set(available)
        var result: [Int] = []
        for index in [current] + neighbors
        where availableSet.contains(index) && !result.contains(index) {
            result.append(index)
        }
        return result
    }
}

/// 把正文切成页。纯函数式：只依赖传入的 `ReaderPaginationLayout`，
/// 可以在后台线程直接跑，不碰任何 UI / 配置对象。
enum ReaderPaginator {
    typealias PageLine = (text: String, isParagraphEnd: Bool, charStart: Int, paragraphId: Int)

    static func paginate(
        blocks: [ReaderContentLine],
        title: String?,
        layout: ReaderPaginationLayout,
        firstPageTitleHeight: CGFloat? = nil
    ) -> [[ReaderContentLine]] {
        let metrics = calculateLayoutMetrics(
            title: title,
            layout: layout,
            firstPageTitleHeight: firstPageTitleHeight
        )
        let normalHeight = metrics.pageHeight
        let firstPageHeight = metrics.firstPageHeight
        let lineHeight = layout.lineHeight
        let usableWidth = layout.usableWidth

        var pages: [[ReaderContentLine]] = []
        var currentPageLines: [PageLine] = []
        var currentPageHeight: CGFloat = 0
        var maxHeightForCurrentPage = firstPageHeight
        var blockIdCounter = 10000

        for block in blocks {
            if block.isImage {
                if !currentPageLines.isEmpty {
                    pages.append(buildPageBlocks(from: currentPageLines, startingId: &blockIdCounter))
                    currentPageLines.removeAll(keepingCapacity: true)
                }
                pages.append([block])
                currentPageHeight = 0
                maxHeightForCurrentPage = normalHeight
            } else {
                let pLines = splitParagraphIntoLines(
                    text: block.text,
                    width: usableWidth,
                    layout: layout
                )
                for lineInfo in pLines {
                    let gap = currentPageLines.last?.isParagraphEnd == true
                        ? layout.paragraphSpacing
                        : 0
                    let advance = lineHeight + gap

                    let overflows = !currentPageLines.isEmpty
                        && currentPageHeight + advance > maxHeightForCurrentPage
                    if overflows {
                        pages.append(buildPageBlocks(from: currentPageLines, startingId: &blockIdCounter))
                        currentPageLines.removeAll(keepingCapacity: true)
                        currentPageHeight = 0
                        maxHeightForCurrentPage = normalHeight
                    }

                    currentPageLines.append((lineInfo.text, lineInfo.isParagraphEnd, lineInfo.charStart, block.id))
                    currentPageHeight += advance
                }
            }
        }

        guard !currentPageLines.isEmpty else {
            return pages.isEmpty ? [[]] : pages
        }
        pages.append(buildPageBlocks(from: currentPageLines, startingId: &blockIdCounter))
        return pages
    }

    /// 首页标题占的高度：按可用宽度估算折行行数，分页和渲染共用同一套算法
    static func estimatedTitleHeight(_ title: String, layout: ReaderPaginationLayout) -> CGFloat {
        guard !layout.titleHidden else { return 0 }
        let titleFontSize = layout.fontSize * layout.chapterTitleScale
        let width = max(120, layout.containerSize.width - layout.paddingLeft - layout.paddingRight)
        let charsPerLine = max(4, Int(width / (titleFontSize + layout.letterSpacing)))
        let lines = max(1, min(4, Int(ceil(Double(title.count) / Double(charsPerLine)))))
        // 略放宽：估小了最后一行会被页脚裁掉
        return titleFontSize * 1.45 * CGFloat(lines) + 12.0
    }

    /// 返回高度而非行数：段间距占位，按行数算会低估，超出预算的部分会压到页脚上。
    static func calculateLayoutMetrics(
        title: String?,
        layout: ReaderPaginationLayout,
        firstPageTitleHeight: CGFloat? = nil
    ) -> (pageHeight: CGFloat, firstPageHeight: CGFloat) {
        let height = max(400, layout.containerSize.height)

        let barHeight: CGFloat = 19
        let reserved = (layout.headerEnabled ? barHeight : 0)
            + (layout.footerEnabled ? barHeight : 0)
            + (layout.headerEnabled ? layout.headerOffset : 0)
            + (layout.footerEnabled ? layout.footerOffset : 0)
            + layout.paddingTop
            + layout.paddingBottom
        let usableHeight = max(200, height - reserved - 2)

        // 首页标题占的高度只认一个来源：设计稿画布等比后的高度（`firstPageTitleHeight`），
        // 没有设计稿才退回「按文字估算」。两处混用会让整张标题位图被塞进几十 pt 的
        // 小盒子里等比适配 —— 观感就是「标题只显示在顶部一小块、又小又残缺」。
        let resolvedTitleHeight: CGFloat = {
            if let firstPageTitleHeight, firstPageTitleHeight > 1 { return firstPageTitleHeight }
            return title.map { estimatedTitleHeight($0, layout: layout) }
                ?? estimatedTitleHeight("第 1 章", layout: layout)
        }()
        let firstPageUsableHeight = max(100, usableHeight - resolvedTitleHeight)

        return (pageHeight: usableHeight, firstPageHeight: firstPageUsableHeight)
    }

    /// 把一段正文切成行。
    ///
    /// 这里必须跟绘制层用同一套字体和字距：换字体或把字距调大后，按默认苹方、
    /// 不带字距切出来的行，画的时候会宽于量出来的宽度，整页就溢出/错位。
    static func splitParagraphIntoLines(
        text: String,
        width: Double,
        layout: ReaderPaginationLayout
    ) -> [(text: String, isParagraphEnd: Bool, charStart: Int)] {
        let font = ReaderFontFactory.ctFont(
            postScriptName: layout.fontPostScriptName,
            boldPostScriptName: layout.fontBoldPostScriptName,
            size: layout.fontSize,
            weightLevel: layout.weightLevel
        )
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTKernAttributeName: layout.letterSpacing
        ]
        guard let attrString = CFAttributedStringCreate(nil, text as CFString, attributes as CFDictionary) else {
            return [(text, true, 0)]
        }
        let typesetter = CTTypesetterCreateWithAttributedString(attrString)
        var start = 0
        let textLen = CFStringGetLength(text as CFString)
        var result: [(text: String, isParagraphEnd: Bool, charStart: Int)] = []
        let nsStr = text as NSString
        // 段首会补全角缩进，第一行要按缩进后的宽度切，否则首行一定超宽
        let indentWidth = Double(layout.firstLineIndent.rounded()) * Double(layout.fontSize)
        let textWidth = max(20, width)
        var isFirstLine = true

        while start < textLen {
            let available = isFirstLine ? max(20, textWidth - indentWidth) : textWidth
            var count = CTTypesetterSuggestLineBreak(typesetter, start, available)
            if count <= 0 { break }
            if layout.punctuationKinsoku {
                let adjusted = applyLineBreakRules(nsStr: nsStr, start: start, count: count, textLen: textLen)
                // 拉进来的标点要先量一遍宽度：CoreText 给的 count 刚好塞满可用宽度，
                // 再往后拉一个句读就超宽，绘制时行尾那个字会被页边裁掉一半。
                if adjusted != count, adjusted > 0 {
                    let candidate = nsStr.substring(with: NSRange(location: start, length: adjusted))
                    if measuredWidth(candidate, font: font, kern: layout.letterSpacing) <= available + 0.5 {
                        count = adjusted
                    }
                }
            }
            let sub = nsStr.substring(with: NSRange(location: start, length: count))
            let isEnd = (start + count >= textLen)
            result.append((sub, isEnd, start))
            start += count
            isFirstLine = false
        }
        return result
    }

    /// 量一段文字在给定字体 / 字距下的实际宽度。
    /// 断行与禁则拉伸都用它复核：`CTTypesetterSuggestLineBreak` 只在「不拉伸」的前提下
    /// 保证不超宽，拉伸过的行必须自己再量一次。
    static func measuredWidth(_ text: String, font: CTFont, kern: CGFloat) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTKernAttributeName: kern
        ]
        guard let attributed = CFAttributedStringCreate(
            nil,
            text as CFString,
            attributes as CFDictionary
        ) else { return 0 }
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        return CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
    }

    // MARK: - 标点禁则

    /// 行首不该出现句读/收尾类标点，行尾不该出现开引号、开括号。
    /// 行首禁则按「标点挤压」处理：把标点拉到上一行，宽度交给两端对齐吸收；
    /// 行尾禁则把该字符挪到下一行。CoreText 不做中文禁则，需要在这里补。
    static let forbiddenLineStart: Set<unichar> = {
        var set = Set<unichar>()
        for scalar in "。，、；：？！…～·）】》」』〉”’.，;:?!)]}%".unicodeScalars where scalar.value <= 0xFFFF {
            set.insert(unichar(scalar.value))
        }
        return set
    }()

    static let forbiddenLineEnd: Set<unichar> = {
        var set = Set<unichar>()
        for scalar in "（【《「『〈“‘([{".unicodeScalars where scalar.value <= 0xFFFF {
            set.insert(unichar(scalar.value))
        }
        return set
    }()

    static func applyLineBreakRules(nsStr: NSString, start: Int, count: Int, textLen: Int) -> Int {
        var adjusted = count
        // 行首禁则：后方紧跟句读类标点时拉到本行，一次最多两个
        var pulled = 0
        var next = start + count
        while pulled < 2, next < textLen, forbiddenLineStart.contains(nsStr.character(at: next)) {
            pulled += 1
            next += 1
        }
        adjusted += pulled
        // 行尾禁则：本行最后一个是开引号/开括号就把它推到下一行
        if adjusted > 1, forbiddenLineEnd.contains(nsStr.character(at: start + adjusted - 1)) {
            adjusted -= 1
        }
        return max(1, adjusted)
    }

    private static func buildPageBlocks(from lines: [PageLine], startingId: inout Int) -> [ReaderContentLine] {
        var identifier = startingId
        let blocks = lines.map { line -> ReaderContentLine in
            defer { identifier += 1 }
            return ReaderContentLine(
                id: identifier,
                isImage: false,
                text: line.text,
                imageUrl: line.isParagraphEnd ? "p_end" : nil,
                paragraphId: line.paragraphId,
                charStart: line.charStart
            )
        }
        startingId = identifier
        return blocks
    }
}
