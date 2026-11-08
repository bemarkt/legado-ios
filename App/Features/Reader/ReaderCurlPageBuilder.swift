import CoreText
import UIKit

/// 纸页使用窗口安全区；导航退出/入场时 UITextView 的临时高度不参与分页。
/// 分页的容器与整屏绘制的边距来自同一矩形，横屏、分屏和 iPad 阅读列也保持一致。
struct ReaderCurlViewport {
    let rect: CGRect
    let windowBounds: CGRect

    init(windowBounds: CGRect, safeAreaInsets: UIEdgeInsets, maximumWidth: CGFloat) {
        self.windowBounds = windowBounds
        let safe = windowBounds.inset(by: safeAreaInsets)
        let width = min(safe.width, maximumWidth)
        rect = CGRect(x: safe.midX - width / 2, y: safe.minY, width: width, height: safe.height)
    }

    func contentInsets(padding: UIEdgeInsets) -> UIEdgeInsets {
        UIEdgeInsets(
            top: rect.minY - windowBounds.minY + padding.top,
            left: rect.minX - windowBounds.minX + padding.left,
            bottom: windowBounds.maxY - rect.maxY + padding.bottom,
            right: windowBounds.maxX - rect.maxX + padding.right
        )
    }
}

/// 一次排版需要的全部输入。
///
/// 分页与绘制共用这一份：宽度、行高、段距、缩进、字体名都只在这里出现一次，
/// 于是「量宽」与「画宽」不可能是两个数。
struct ReaderCurlPageBuildInput {
    var blocks: [ReaderContentLine]
    var title: String?
    var layout: ReaderPaginationLayout
    var alignment: ReaderLineAlignment
    var underline: Bool
    var underlineColor: UIColor?
    var textColor: UIColor
    var backgroundColor: UIColor
    var backgroundImage: UIImage?
    var contentInsets: UIEdgeInsets
    var contentWidth: CGFloat
    var header: ReaderCurlBarSpec?
    var footer: ReaderCurlBarSpec?
    /// 设计稿画布等比算出的首页标题高度。> 1 时直接用，不再按文字估算。
    var titleHeightOverride: CGFloat = 0
    var titleImage: UIImage?
}

/// 排版结果：页、每页首字符偏移、整卷绘制参数。
struct ReaderCurlPageBuildResult {
    var sheets: [ReaderCurlSheet]
    var startCharacters: [Int]
    var style: ReaderCurlStyle
    var firstPageTitleHeight: CGFloat
}

/// 章节正文 → 页。纯函数，不碰任何 UI 状态。
enum ReaderCurlPageBuilder {

    /// 章节正文 → 行级块。
    ///
    /// `paragraphId` 用块下标，输入块的 `charStart` 是原文章内 UTF-16 起点；
    /// 智能分段只拆「特别长、又完全没有段落」的行，短行原样保留。
    static func blocks(from text: String, smartParagraphs: Bool) -> [ReaderContentLine] {
        var result: [ReaderContentLine] = []
        let source = text as NSString
        source.enumerateSubstrings(in: NSRange(location: 0, length: source.length), options: .byLines) { line, range, _, _ in
            guard let line, !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let pieces = smartParagraphs ? ReaderTextTransform.smartParagraphSplit(line) : [line]
            var pieceOffset = range.location
            for piece in pieces {
                defer { pieceOffset += piece.utf16.count }
                guard !piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                result.append(ReaderContentLine(
                    id: result.count,
                    isImage: false,
                    text: piece,
                    imageUrl: nil,
                    paragraphId: result.count,
                    charStart: pieceOffset
                ))
            }
        }
        if result.isEmpty, !text.isEmpty {
            result.append(ReaderContentLine(
                id: 0,
                isImage: false,
                text: text,
                imageUrl: nil,
                paragraphId: 0,
                charStart: 0
            ))
        }
        return result
    }

    static func build(_ input: ReaderCurlPageBuildInput) -> ReaderCurlPageBuildResult {
        // 首页标题高度只认一个来源：设计稿画布等比后的高度，没有设计稿才按文字估算。
        let titleHeight: CGFloat = {
            if input.titleHeightOverride > 1 { return input.titleHeightOverride }
            return input.title.map {
                ReaderPaginator.estimatedTitleHeight($0, layout: input.layout)
            } ?? 0
        }()
        let pages = ReaderPaginator.paginate(
            blocks: input.blocks,
            title: input.title,
            layout: input.layout,
            firstPageTitleHeight: titleHeight > 1 ? titleHeight : nil
        )

        var sheets: [ReaderCurlSheet] = []
        var starts: [Int] = []
        let blockStarts = Dictionary(uniqueKeysWithValues: input.blocks.map { ($0.id, $0.charStart) })
        for (index, page) in pages.enumerated() {
            let textLines = page.filter { !$0.isImage }
            var sheet = ReaderCurlSheet()
            sheet.lines = textLines.map { $0.text }
            sheet.isParagraphEnd = textLines.map { $0.isParagraphEnd }
            if index == 0, titleHeight > 0 {
                sheet.titleHeight = titleHeight
                sheet.titleText = input.title ?? ""
                sheet.titleImage = input.titleImage
            }
            sheets.append(sheet)
            // 使用原文 UTF-16 坐标：空行、CRLF 和智能分段不能被虚构成一个换行。
            // 分页返回的 charStart 是块内偏移，块的 charStart 是原文章内偏移。
            if index == 0 {
                starts.append(0)
            } else if let first = textLines.first {
                starts.append((blockStarts[first.paragraphId] ?? 0) + first.charStart)
            } else {
                starts.append(starts.last ?? 0)
            }
        }
        if sheets.isEmpty {
            sheets = [ReaderCurlSheet()]
            starts = [0]
        }

        let style = ReaderCurlStyle(
            layout: input.layout,
            alignment: input.alignment,
            underline: input.underline,
            underlineColor: input.underlineColor,
            textColor: input.textColor,
            backgroundColor: input.backgroundColor,
            backgroundImage: input.backgroundImage,
            contentInsets: input.contentInsets,
            contentWidth: input.contentWidth,
            titleFontSize: input.layout.fontSize * max(1, input.layout.chapterTitleScale),
            header: input.header,
            footer: input.footer
        )

        return ReaderCurlPageBuildResult(
            sheets: sheets,
            startCharacters: starts,
            style: style,
            firstPageTitleHeight: titleHeight
        )
    }
}
