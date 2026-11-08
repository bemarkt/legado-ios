import CoreText
import UIKit

/// 正文对齐方式，口径照 Juyue `ReaderTextAlignment`（`ReaderConfig.swift:1186`）：
/// 只有两端对齐要二次分配，居中 / 靠右交给 `CTLineGetPenOffsetForFlush` 推位。
enum ReaderCoreTextAlignment: String, CaseIterable, Identifiable {
    case justify = "两端"
    case leading = "靠左"
    case center = "居中"
    case trailing = "靠右"

    var id: String { rawValue }

    var isJustify: Bool { self == .justify }
}

/// `UIFont` → `CTFont`。
///
/// 我们这边字体走 `ReaderFontStore` + `fontPath`，`UIFont.fontName` 就是可用的
/// PostScript 名，`CTFontCreateWithName` 直接认；字重已经在 `ReaderFontStore.font`
/// 里派生完毕（粗体走 descriptor、细体走 trait），这里不再二次加权，
/// 否则粗体会被叠成两档、细体会被拉回常规。
enum ReaderCoreTextFont {
    static func font(from base: UIFont, size: CGFloat? = nil) -> CTFont {
        let target = max(1, size ?? base.pointSize)
        let name = base.fontName
        if name.isEmpty {
            return CTFontCreateWithName("PingFangSC-Regular" as CFString, target, nil)
        }
        return CTFontCreateWithName(name as CFString, target, nil)
    }
}

/// 一行的排版结果。字体与行高跟着所属段走：章节标题比正文大一号，
/// 行高必须按它自己的字号算，否则标题会被正文行高切掉一半。
struct ReaderCoreTextLine {
    /// 这一行要画的字（不含段首缩进，缩进在绘制时补）。
    let text: String
    /// 是否段末：段间距、段末下划线、非两端对齐都看它。
    let isParagraphEnd: Bool
    /// 是否章节标题行：不缩进、不参与两端对齐。
    let isHeading: Bool
    /// 在整章正文里的 UTF-16 起点。
    let charStart: Int
    let font: CTFont
    let lineHeight: CGFloat
    /// 本行行首要补的段首缩进宽度（0 = 不缩进）。
    ///
    /// 缩进是绘制时补在行首的，两端对齐的目标宽度必须扣掉它：否则「缩进 + 撑满整行」
    /// 比可用宽度正好多出一个缩进，行尾那个字被页边裁掉（实测「首行最后一个字只显示
    /// 一部分」）。分页时记下来，绘制时直接用同一份，不在两处各量一遍。
    var leadingIndent: CGFloat = 0
}

/// 一页的排版结果。
struct ReaderCoreTextPage {
    let lines: [ReaderCoreTextLine]
    /// 页末匀空白后每段额外分到的间距：`justifyLastPage` 关掉时为 0。
    let extraParagraphSpacing: CGFloat
    /// 首页顶部设计标题（HTML 设计稿）的预留高度：0 表示这一章没有设计稿。
    ///
    /// 高度由画布等比算出后先占住，位图异步回来只重绘不重排 —— 否则会出现
    /// 「标题图回来后整章重排、页码跳两下」。
    var titleHeight: CGFloat = 0
    /// 设计标题的位图：离屏 WKWebView 截图（`ReaderChapterTitleStore`）。
    var titleImage: UIImage? = nil

    /// 该页首行的 UTF-16 起点：卷页落地后要用它把阅读进度对齐到这一页。
    var startCharacter: Int { lines.first?.charStart ?? 0 }
}

/// 一段待排的正文：文字 + 这一段自己的字体 + 在整章里的起点。
struct ReaderCoreTextParagraph {
    let text: String
    let font: CTFont
    let charBase: Int
    let isHeading: Bool
}

/// 排版参数（值类型，可安全地丢到后台算）。
struct ReaderCoreTextLayout {
    /// 正文基准字体：只用来量段首缩进宽度，绘制时每行用自己的字体。
    var bodyFont: CTFont
    /// 正文字号：行高口径以它为准（章节标题行按自己的字号算）。
    var fontSize: CGFloat
    var lineSpacing: CGFloat
    var paragraphSpacing: CGFloat
    /// 字间距系数：铺开时取 `letterSpacing * fontSize` 当 kern，与 `ReaderTypography` 同口径。
    var letterSpacing: CGFloat
    /// 段首缩进字符串（设置里默认两个全角空格）。
    var firstLineIndent: String
    var alignment: ReaderCoreTextAlignment
    var underline: Bool
    /// 下划线线型位掩码：`NSUnderlineStyle` 与 `CTUnderlineStyle` 同值，
    /// 由 `ReaderUnderlinePattern.nsUnderlineStyle` 给出（实线 / 点线 / 虚线 / 点划线）。
    var underlineStyle: Int
    /// 段末分隔线根数（0 = 不画）与颜色。
    var paragraphSeparatorLines: Int
    var paragraphSeparatorColor: UIColor?
    /// 页末匀空白开关（Juyue `reader_justify_last_page`）。
    var justifyLastPage: Bool
    /// 中文标点禁则开关（Juyue `reader_punctuation_kinsoku`）。
    var punctuationKinsoku: Bool
    /// 简繁转换：只在绘制时换字，不动字符偏移，分页与进度都不受影响。
    var conversion: ReaderChineseConversion

    /// kern 是点值，设置里的 `letterSpacing` 是系数。
    var kern: CGFloat { letterSpacing * fontSize }

    /// 行高口径：字号 × 1.25 + 行距，与 Juyue `PageCurlContent`
    /// （`PageCurlPager.swift:1150` 的 `effectiveLineHeight`）一致。
    func lineHeight(for font: CTFont) -> CGFloat {
        max(1, CTFontGetSize(font)) * 1.25 + lineSpacing
    }

    /// 段首缩进宽度：同一字体、同一 kern 量出来，量宽与绘制不会差半个字。
    var indentWidth: CGFloat {
        guard !firstLineIndent.isEmpty else { return 0 }
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: bodyFont,
            kCTKernAttributeName: kern
        ]
        guard let attributed = CFAttributedStringCreate(
            nil,
            firstLineIndent as CFString,
            attributes as CFDictionary
        ) else { return 0 }
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0
        var descent: CGFloat = 0
        var leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        return max(0, width)
    }
}

/// CoreText 排版内核：折行 + 分页。
///
/// 全部照 Juyue：`ReaderPaginator.splitParagraphIntoLines`（`ReaderPaginator.swift:176`）
/// 用 `CTTypesetterSuggestLineBreak` 逐行切、再补中文标点禁则；
/// `ReaderPaginator.paginate`（同文件 :51）按「行高 + 段间距」累加，换页点永远落在整行上，
/// 页顶页底都压在行边界，翻页不会切出半截字。
///
/// 与 Juyue 的两处差别：
/// - 章节标题作为第一段真实参与排版，不复用 `estimatedTitleHeight` 估算（估小了末行会被页脚裁掉）；
/// - 设计稿标题（HTML）只按画布等比预留高度、位图叠在首页顶部，行内排版不受影响。
enum ReaderCoreTextEngine {

    /// 整章分页。
    /// - Parameters:
    ///   - containerSize: 整页尺寸（含内边距、含页内页眉页脚占位）。
    ///   - insets: 正文内边距，与主视图 `textContainerInset` 同一份。
    ///   - firstPageTitleHeight: 首页给设计稿标题预留的高度（0 表示没有设计稿）。
    static func pages(
        for paragraphs: [ReaderCoreTextParagraph],
        containerSize: CGSize,
        insets: UIEdgeInsets,
        layout: ReaderCoreTextLayout,
        firstPageTitleHeight: CGFloat = 0
    ) -> [ReaderCoreTextPage] {
        let usableWidth = max(120, containerSize.width - insets.left - insets.right)
        let usableHeight = max(120, containerSize.height - insets.top - insets.bottom - 2)
        // 预留高度只作用在首页：后续页回到满高，否则每页都被砍掉一截。
        let reservedTitle = max(0, firstPageTitleHeight)
        var pageHeight = reservedTitle > 0 ? max(80, usableHeight - reservedTitle) : usableHeight

        var pages: [ReaderCoreTextPage] = []
        var current: [ReaderCoreTextLine] = []
        var currentHeight: CGFloat = 0

        for paragraph in paragraphs {
            let split = lines(for: paragraph, width: usableWidth, layout: layout)
            for item in split {
                let gap: CGFloat = current.last?.isParagraphEnd == true ? layout.paragraphSpacing : 0
                let advance = item.lineHeight + gap
                if !current.isEmpty, currentHeight + advance > pageHeight {
                    pages.append(finish(current, layout: layout, pageHeight: pageHeight))
                    current.removeAll(keepingCapacity: true)
                    currentHeight = 0
                    pageHeight = usableHeight
                }
                current.append(ReaderCoreTextLine(
                    text: item.text,
                    isParagraphEnd: item.isParagraphEnd,
                    isHeading: paragraph.isHeading,
                    charStart: paragraph.charBase + item.charStart,
                    font: paragraph.font,
                    lineHeight: item.lineHeight,
                    leadingIndent: item.leadingIndent
                ))
                currentHeight += advance
            }
        }

        if !current.isEmpty {
            pages.append(finish(current, layout: layout, pageHeight: pageHeight))
        }
        if pages.isEmpty {
            pages.append(ReaderCoreTextPage(
                lines: [],
                extraParagraphSpacing: 0,
                titleHeight: reservedTitle,
                titleImage: nil
            ))
            return pages
        }
        if reservedTitle > 0 {
            // 预留高度回填到首页：图还没回来时也先占住位置，保证页数稳定。
            let first = pages[0]
            pages[0] = ReaderCoreTextPage(
                lines: first.lines,
                extraParagraphSpacing: first.extraParagraphSpacing,
                titleHeight: reservedTitle,
                titleImage: first.titleImage
            )
        }
        return pages
    }

    /// 一段正文折行。
    ///
    /// 断行必须与绘制用同一字体、同一 kern、同一缩进宽度：换字体或把字距调大后，
    /// 按默认苹方、不带字距切出来的行，画的时候会宽于量出来的宽度，整页就溢出。
    static func lines(
        for paragraph: ReaderCoreTextParagraph,
        width: CGFloat,
        layout: ReaderCoreTextLayout
    ) -> [(text: String, isParagraphEnd: Bool, charStart: Int, lineHeight: CGFloat, leadingIndent: CGFloat)] {
        let lineHeight = layout.lineHeight(for: paragraph.font)
        let textWidth = max(20, width)
        let source = paragraph.text
        guard !source.isEmpty else { return [("", true, 0, lineHeight, 0)] }

        let attributes: [CFString: Any] = [
            kCTFontAttributeName: paragraph.font,
            kCTKernAttributeName: layout.kern
        ]
        guard let attributed = CFAttributedStringCreate(
            nil,
            source as CFString,
            attributes as CFDictionary
        ) else { return [(source, true, 0, lineHeight, 0)] }

        let typesetter = CTTypesetterCreateWithAttributedString(attributed)
        let ns = source as NSString
        let length = ns.length
        // 段首补全角缩进，第一行要按缩进后的宽度切，否则首行一定超宽。
        let indent = paragraph.isHeading ? 0 : layout.indentWidth
        var start = 0
        var isFirstLine = true
        var result: [(text: String, isParagraphEnd: Bool, charStart: Int, lineHeight: CGFloat, leadingIndent: CGFloat)] = []

        while start < length {
            let leading = isFirstLine ? indent : 0
            let available = max(20, textWidth - leading)
            var count = CTTypesetterSuggestLineBreak(typesetter, start, Double(available))
            if count <= 0 { break }
            // 标点禁则可关：关掉就纯 CoreText 断行。
            if layout.punctuationKinsoku {
                let adjusted = adjustLineBreak(ns: ns, start: start, count: count, length: length)
                // 拉进来的标点必须先量一遍宽度：CoreText 给的 count 刚好塞满可用宽度，
                // 再往后拉一个句读就会超宽。量出来超了就放弃这次拉伸，宁可标点落到下一行。
                if adjusted != count, adjusted > 0 {
                    let candidate = ns.substring(with: NSRange(location: start, length: adjusted))
                    if measuredWidth(candidate, font: paragraph.font, kern: layout.kern) <= available + 0.5 {
                        count = adjusted
                    }
                }
            }
            let sub = ns.substring(with: NSRange(location: start, length: count))
            let isEnd = start + count >= length
            result.append((sub, isEnd, start, lineHeight, leading))
            start += count
            isFirstLine = false
        }

        if result.isEmpty { return [(source, true, 0, lineHeight, 0)] }
        return result
    }

    /// 量一段文字在给定字体 / 字距下的实际宽度。
    ///
    /// 断行与禁则拉伸都用它复核：`CTTypesetterSuggestLineBreak` 只在「不拉伸」的前提下
    /// 保证不超宽，拉伸过的行必须自己再量一次，否则绘制时会溢出页边被裁。
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

    /// 行首不该出现句读 / 收尾类标点。
    private static let forbiddenLineStart: Set<unichar> = {
        var set = Set<unichar>()
        for scalar in "。，、；：？！…～·）】》」』〉”’.，;:?!)]}%".unicodeScalars where scalar.value <= 0xFFFF {
            set.insert(unichar(scalar.value))
        }
        return set
    }()

    /// 行尾不该出现开引号、开括号。
    private static let forbiddenLineEnd: Set<unichar> = {
        var set = Set<unichar>()
        for scalar in "（【《「『〈“([{".unicodeScalars where scalar.value <= 0xFFFF {
            set.insert(unichar(scalar.value))
        }
        return set
    }()

    /// 行首禁则按「标点挤压」处理：把后面的标点拉到本行（一次最多两个），
    /// 多出来的宽度交给两端对齐吸收；行尾禁则把该字符挪到下一行。
    /// CoreText 不做中文禁则，只能在这里补。
    private static func adjustLineBreak(ns: NSString, start: Int, count: Int, length: Int) -> Int {
        var adjusted = count
        var pulled = 0
        var next = start + count
        while pulled < 2, next < length, forbiddenLineStart.contains(ns.character(at: next)) {
            pulled += 1
            next += 1
        }
        adjusted += pulled
        if adjusted > 1, forbiddenLineEnd.contains(ns.character(at: start + adjusted - 1)) {
            adjusted -= 1
        }
        return max(1, adjusted)
    }

    /// 收尾一页：页末匀空白。
    ///
    /// 照 Juyue `PageCurlContent.contentBody`（`PageCurlPager.swift:1148-1164`）：
    /// 先把段间距本身扣掉再匀余量，否则整页会超出可用高度；
    /// 每段最多匀一个行高；`justifyLastPage` 关掉则完全不匀。
    private static func finish(
        _ lines: [ReaderCoreTextLine],
        layout: ReaderCoreTextLayout,
        pageHeight: CGFloat
    ) -> ReaderCoreTextPage {
        let filled = lines.reduce(CGFloat(0)) { $0 + $1.lineHeight }
        let trailing = lines.last?.isParagraphEnd == true ? 1 : 0
        let paragraphCount = max(0, lines.filter { $0.isParagraphEnd }.count - trailing)
        guard layout.justifyLastPage, paragraphCount > 0 else {
            return ReaderCoreTextPage(lines: lines, extraParagraphSpacing: 0)
        }
        let slack = max(0, pageHeight - filled - CGFloat(paragraphCount) * layout.paragraphSpacing - 2)
        let bodyLineHeight = layout.lineHeight(for: layout.bodyFont)
        let extra = min(slack / CGFloat(paragraphCount), bodyLineHeight)
        return ReaderCoreTextPage(lines: lines, extraParagraphSpacing: extra)
    }
}
