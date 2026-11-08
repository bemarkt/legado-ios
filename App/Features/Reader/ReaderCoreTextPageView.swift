import CoreText
import UIKit

/// 一页用 CoreText 逐行画出来的正文。
///
/// 直接照 Juyue `CoreTextUIView.draw`（`ReaderView.swift:10348`）：每行一个 `CTLine`，
/// 非段末行用 `CTLineCreateJustifiedLine` 做两端对齐（这是 `UITextView` 给不出的
/// 逐行二次分配），居中 / 靠右用 `CTLineGetPenOffsetForFlush` 推位，段末叠段间距
/// （含页末匀空白）。
///
/// 与 Juyue 的差别只保留我们确实有的东西：没有热评卡片、段评气泡、逐字标注；
/// 分页已由 `ReaderCoreTextEngine` 算好，这一层只负责把一页画准。
final class ReaderCoreTextPageView: UIView {

    var page: ReaderCoreTextPage?
    var layout: ReaderCoreTextLayout?
    var textColor: UIColor = .label
    var underlineColor: UIColor?

    /// 内容指纹：与上次相同就不重绘。
    var renderSignature: String = "" {
        didSet { if oldValue != renderSignature { setNeedsDisplay() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 一页的指纹：行内容 + 排版参数 + 字体 + 尺寸，任一项变了就重画。
    ///
    /// 逐项 `append` 而不是一个大数组字面量：多项 `String(...)` 挤在同一条表达式里
    /// 会让类型检查器超时（本项目 CI 实测报过 “unable to type-check this expression
    /// in reasonable time”）。插值走 `String(describing:)`，对 `CGFloat` 合法。
    func currentSignature() -> String {
        var parts: [String] = []
        parts.reserveCapacity(18)
        parts.append("\(layout?.fontSize ?? 0)")
        parts.append("\(layout?.lineSpacing ?? 0)")
        parts.append("\(layout?.paragraphSpacing ?? 0)")
        parts.append("\(layout?.kern ?? 0)")
        parts.append(layout?.firstLineIndent ?? "")
        parts.append(layout?.alignment.rawValue ?? "")
        parts.append("\(layout?.underline == true)")
        parts.append("\(layout?.underlineStyle ?? 0)")
        parts.append("\(layout?.paragraphSeparatorLines ?? 0)")
        parts.append(layout?.conversion.rawValue ?? "")
        parts.append("\(bounds.width)")
        parts.append("\(bounds.height)")
        parts.append("\(page?.extraParagraphSpacing ?? 0)")
        parts.append("\(page?.titleHeight ?? 0)")
        parts.append(page?.titleImage == nil ? "t0" : "t1")
        if let lines = page?.lines {
            parts.append(lines.map { $0.text }.joined(separator: "\u{1}"))
            parts.append(lines.map { $0.isParagraphEnd ? "1" : "0" }.joined())
            let fonts = lines.map { CTFontCopyPostScriptName($0.font) as String }.joined(separator: ",")
            parts.append(fonts)
        }
        parts.append("\(textColor.hashValue)")
        return parts.joined(separator: "|")
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(),
              let page,
              let layout,
              !page.lines.isEmpty else { return }
        let targetWidth = CGFloat(max(100, bounds.width))
        // 首页设计稿标题：分页时已按画布等比预留高度，这里只把位图铺满可用宽度。
        // 图还没回来时只空着这一段，行位置不变 —— 不会因为异步回来而重排。
        let titleHeight = page.titleHeight
        if titleHeight > 0, let image = page.titleImage {
            image.draw(in: CGRect(x: 0, y: 0, width: targetWidth, height: titleHeight))
        }

        // 行的位置：段末把段间距（含页末匀空白）累进去，与分页时的口径完全一致。
        var lineTops = [CGFloat](repeating: 0, count: page.lines.count)
        var cursor: CGFloat = titleHeight
        for index in page.lines.indices {
            lineTops[index] = cursor
            cursor += page.lines[index].lineHeight
            if page.lines[index].isParagraphEnd {
                cursor += layout.paragraphSpacing + page.extraParagraphSpacing
            }
        }

        for (index, line) in page.lines.enumerated() {
            guard !line.text.isEmpty else { continue }
            // 行首缩进只补「分页时确实按缩进让过宽度」的那一行：跨页续行的首行
            // 分页没有让过宽度，这里再补两个全角空格，整行就比页宽多出两格，行尾被裁。
            let isParagraphStart = index == 0 || page.lines[index - 1].isParagraphEnd
            let showsIndent = isParagraphStart && !line.isHeading && line.leadingIndent > 0
            let indent = showsIndent ? layout.firstLineIndent : ""
            // 简繁转换只在绘制时换字：字符偏移仍按原文算，分页 / 进度对得上。
            let rendered = layout.conversion.apply(indent + line.text)

            var attributes: [CFString: Any] = [
                kCTFontAttributeName: line.font,
                kCTForegroundColorAttributeName: textColor.cgColor,
                kCTKernAttributeName: layout.kern
            ]
            if layout.underline {
                // 线型走位掩码（实线 / 点线 / 虚线 / 点划线），跟 Juyue `nsUnderlineStyle` 同值。
                attributes[kCTUnderlineStyleAttributeName] = layout.underlineStyle
                attributes[kCTUnderlineColorAttributeName] = (underlineColor ?? textColor).cgColor
            }
            guard let attributed = CFAttributedStringCreate(
                nil,
                rendered as CFString,
                attributes as CFDictionary
            ) else { continue }

            let typesetter = CTTypesetterCreateWithAttributedString(attributed)
            // 长度必须按 UTF-16 算：emoji 是代理对，按 String.count 会把范围截在半个表情上。
            let renderedLength = (rendered as NSString).length
            let ctLine = CTTypesetterCreateLine(typesetter, CFRange(location: 0, length: renderedLength))

            // 先量自然宽度：CoreText 断出来的行本来就可能比可用宽度略宽（标点禁则会把
            // 句读拉到本行）。这种行必须原样画 —— 走 `CTLineCreateJustifiedLine` 会把
            // 字距压成负值，句读叠到相邻字上（实测「有些符号会显示在正文字上」）。
            var naturalAscent: CGFloat = 0
            var naturalDescent: CGFloat = 0
            var naturalLeading: CGFloat = 0
            let naturalWidth = CGFloat(CTLineGetTypographicBounds(
                ctLine,
                &naturalAscent,
                &naturalDescent,
                &naturalLeading
            ))

            let finalLine: CTLine
            var penOffset: CGFloat = 0
            // 两端对齐的目标宽度就是整行可用宽度：分页已经给段首缩进让过宽度，
            // 这里再扣一次缩进等于把行压窄两格，字距被压成负值，行首那个前引号
            // 就叠到后面的字上（实测「首字符是前双引号时压在字上」）。
            let canJustify = layout.alignment.isJustify
                && !line.isParagraphEnd
                && !line.isHeading
                && line.text.count > 5
                && naturalWidth <= targetWidth + 0.5
            if canJustify {
                finalLine = CTLineCreateJustifiedLine(ctLine, 1.0, targetWidth) ?? ctLine
            } else {
                finalLine = ctLine
                switch layout.alignment {
                case .center:
                    penOffset = CGFloat(CTLineGetPenOffsetForFlush(ctLine, 0.5, targetWidth))
                case .trailing:
                    penOffset = CGFloat(CTLineGetPenOffsetForFlush(ctLine, 1.0, targetWidth))
                default:
                    break
                }
            }

            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            CTLineGetTypographicBounds(finalLine, &ascent, &descent, &leading)
            let baselineY = lineTops[index] + ascent

            ctx.saveGState()
            ctx.textMatrix = .identity
            ctx.translateBy(x: penOffset, y: baselineY)
            ctx.scaleBy(x: 1.0, y: -1.0)
            CTLineDraw(finalLine, ctx)
            ctx.restoreGState()

            // 段末分隔线（Juyue `paragraphSeparatorLines`）：画在段末行下沿的段间距里，
            // 位置按「段距 + 页末匀空白」算，与分页口径一致，不会压到下一段首行。
            if line.isParagraphEnd, layout.paragraphSeparatorLines > 0 {
                let gap = layout.paragraphSpacing + page.extraParagraphSpacing
                var sepY = baselineY + descent
                    + max(2, (gap - CGFloat(layout.paragraphSeparatorLines) * 3.5) / 2)
                ctx.saveGState()
                ctx.setStrokeColor((layout.paragraphSeparatorColor ?? textColor).cgColor)
                ctx.setLineWidth(0.5)
                for _ in 0..<layout.paragraphSeparatorLines {
                    ctx.move(to: CGPoint(x: 0, y: sepY))
                    ctx.addLine(to: CGPoint(x: targetWidth, y: sepY))
                    sepY += 3.5
                }
                ctx.strokePath()
                ctx.restoreGState()
            }
        }
    }
}
