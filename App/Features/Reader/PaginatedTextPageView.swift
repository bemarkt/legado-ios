import CoreText
import UIKit

/// 正文对齐方式。只有两端对齐要二次分配，居中 / 靠右交给 `CTLineGetPenOffsetForFlush` 推位。
enum ReaderLineAlignment: String, CaseIterable, Sendable {
    case justify
    case leading
    case center
    case trailing
}

/// 一页按行画出来的正文。
///
/// 每行一个 `CTLine`：非段末行用 `CTLineCreateJustifiedLine` 做两端对齐（这是
/// `UITextView` 给不出的逐行二次分配），居中 / 靠右用 flush 偏移推位，段末叠段间距。
///
/// 对齐宽度就是 `containerWidth`（整页可用宽度），段首缩进是在行首补全角空格、
/// 由断行阶段让过宽度。宽度只有一个来源 —— 分页用的 `usableWidth` 就是这里的
/// `containerWidth`，所以撑满整行的那一行不会被右边缘裁掉最后一个字。
final class PaginatedTextPageView: UIView {
    var lines: [String] = []
    var isParagraphEnd: [Bool] = []
    var fontSize: CGFloat = 18
    var lineSpacing: CGFloat = 6
    var letterSpacing: CGFloat = 0
    var paragraphSpacing: CGFloat = 0
    var firstLineIndent: CGFloat = 0
    var weightLevel: Int = 1
    var fontPostScriptName: String = "PingFangSC-Regular"
    var boldPostScriptName: String? = "PingFangSC-Semibold"
    var textColor: UIColor = .label
    /// 分页时用的可用宽度：绘制宽度只认这一个数，不再从 frame 反算。
    var containerWidth: CGFloat = 340
    var containerHeight: CGFloat = 600
    var textAlignment: ReaderLineAlignment = .justify
    var underlineEnabled: Bool = false
    var underlineColor: UIColor?
    var paragraphSeparatorLines: Int = 0
    var paragraphSeparatorColor: UIColor?

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

    /// 指纹：行内容、排版参数、字体、尺寸，任一项变了就重画。
    func currentSignature() -> String {
        var parts: [String] = []
        parts.reserveCapacity(16)
        parts.append("\(fontSize)")
        parts.append("\(lineSpacing)")
        parts.append("\(letterSpacing)")
        parts.append("\(paragraphSpacing)")
        parts.append("\(firstLineIndent)")
        parts.append("\(weightLevel)")
        parts.append(fontPostScriptName)
        parts.append(boldPostScriptName ?? "")
        parts.append(textAlignment.rawValue)
        parts.append("\(underlineEnabled)")
        parts.append(underlineColor?.description ?? "")
        parts.append("\(paragraphSeparatorLines)")
        parts.append("\(containerWidth)x\(containerHeight)")
        parts.append("\(textColor.hashValue)")
        parts.append(lines.joined(separator: "\u{1}"))
        parts.append(isParagraphEnd.map { $0 ? "1" : "0" }.joined())
        return parts.joined(separator: "|")
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(), !lines.isEmpty else { return }

        let ctFont = ReaderFontFactory.ctFont(
            postScriptName: fontPostScriptName,
            boldPostScriptName: boldPostScriptName,
            size: fontSize,
            weightLevel: weightLevel
        )
        let effectiveLineHeight = fontSize * 1.25 + lineSpacing
        let targetWidth = Double(max(100, containerWidth))

        // 每行的顶部 y：段末把段间距累进去，与分页时的口径完全一致。
        var lineTops = [CGFloat](repeating: 0, count: lines.count)
        var cursor: CGFloat = 0
        for index in lines.indices {
            lineTops[index] = cursor
            cursor += effectiveLineHeight
            if index < isParagraphEnd.count, isParagraphEnd[index] {
                cursor += paragraphSpacing
            }
        }

        for (index, lineText) in lines.enumerated() {
            guard !lineText.isEmpty else { continue }
            let isParagraphStart = index == 0 || (index - 1 < isParagraphEnd.count && isParagraphEnd[index - 1])
            // 段首补全角缩进：断行时首行已经按缩进后的宽度切过，两边口径一致。
            let indentText = isParagraphStart && firstLineIndent >= 1
                ? String(repeating: "\u{3000}", count: Int(firstLineIndent.rounded()))
                : ""

            var attrs: [CFString: Any] = [
                kCTFontAttributeName: ctFont,
                kCTForegroundColorAttributeName: textColor.cgColor,
                kCTKernAttributeName: letterSpacing
            ]
            if underlineEnabled {
                attrs[kCTUnderlineStyleAttributeName] = CTUnderlineStyle.single.rawValue
                attrs[kCTUnderlineColorAttributeName] = (underlineColor ?? textColor).cgColor
            }

            /// 一段文字 → 一行，并量出它的自然宽度。宽度口径只有一个：`targetWidth`。
            func buildLine(_ text: String) -> (line: CTLine, width: Double)? {
                guard let attributed = CFAttributedStringCreate(
                    nil,
                    text as CFString,
                    attrs as CFDictionary
                ) else { return nil }
                let typesetter = CTTypesetterCreateWithAttributedString(attributed)
                // 长度必须按 UTF-16 算：emoji 是代理对，用 String.count 会把范围截在半个表情上。
                let length = (text as NSString).length
                let line = CTTypesetterCreateLine(typesetter, CFRange(location: 0, length: length))
                var ascent: CGFloat = 0
                var descent: CGFloat = 0
                var leading: CGFloat = 0
                let width = Double(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
                return (line, width)
            }

            guard var built = buildLine(indentText + lineText) else { continue }
            // 段首缩进把整行顶出页宽时放弃缩进：宁可这一行不缩进，也不能让行尾的字被页边裁掉。
            if !indentText.isEmpty, built.width > targetWidth + 0.5, let plain = buildLine(lineText) {
                built = plain
            }
            let ctLine = built.line
            let naturalWidth = built.width

            let isEnd = index < isParagraphEnd.count ? isParagraphEnd[index] : false
            let finalLine: CTLine
            var penOffset: CGFloat = 0
            // 只有自然宽度没有超过页宽的行才做两端对齐：超宽还拉，字距会被压成负值，
            // 行首的前引号叠到后一个字上、行尾的字被页边裁掉（实测「双引号压在字上」）。
            if textAlignment == .justify, !isEnd, lineText.count > 5, naturalWidth <= targetWidth + 0.5 {
                finalLine = CTLineCreateJustifiedLine(ctLine, 1.0, targetWidth) ?? ctLine
            } else {
                finalLine = ctLine
                switch textAlignment {
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

            // 段末分隔线：画在段末行下沿的段间距里，不会压到下一段首行。
            if isEnd, paragraphSeparatorLines > 0 {
                let lineColor = paragraphSeparatorColor ?? textColor
                var sepY = baselineY + descent
                    + max(2, (paragraphSpacing - CGFloat(paragraphSeparatorLines) * 3.5) / 2)
                ctx.saveGState()
                ctx.setStrokeColor(lineColor.cgColor)
                ctx.setLineWidth(0.5)
                for _ in 0..<paragraphSeparatorLines {
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
