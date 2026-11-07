import CoreText
import UIKit

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
    /// `paragraphId` 用块下标，`charStart` 记这一行在所属段落里的 UTF-16 起点；
    /// 智能分段只拆「特别长、又完全没有段落」的行，短行原样保留。
    static func blocks(from text: String, smartParagraphs: Bool) -> [ReaderContentLine] {
        var result: [ReaderContentLine] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let pieces = smartParagraphs ? ReaderTextTransform.smartParagraphSplit(line) : [line]
            var pieceOffset = 0
            for piece in pieces {
                guard !piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                result.append(ReaderContentLine(
                    id: result.count,
                    isImage: false,
                    text: piece,
                    imageUrl: nil,
                    paragraphId: result.count,
                    charStart: pieceOffset
                ))
                pieceOffset += piece.utf16.count
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
        var character = 0
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
            starts.append(character)
            // 页首字符偏移：正文里每个段落之间有一个换行，进度换算要把它算进去，
            // 否则「页 → 字符」和「字符 → 页」两边会逐页漂一个字。
            for line in textLines {
                character += line.text.utf16.count + (line.isParagraphEnd ? 1 : 0)
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
