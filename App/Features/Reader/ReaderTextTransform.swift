import Foundation
import UIKit

/// 简繁转换。
///
/// 口径照 Juyue `ChineseConversion`（`ReaderConfig.swift:1073`）：走 Foundation 的
/// `StringTransform`，不自建字表 —— 自建表漏字比不转换更糟。
enum ReaderChineseConversion: String, CaseIterable, Identifiable {
    case none = "原文"
    case simplified = "转简体"
    case traditional = "转繁体"

    var id: String { rawValue }

    var transform: StringTransform? {
        switch self {
        case .none: return nil
        case .simplified: return StringTransform("Traditional-Simplified")
        case .traditional: return StringTransform("Simplified-Traditional")
        }
    }

    func apply(_ text: String) -> String {
        guard let transform else { return text }
        return text.applyingTransform(transform, reverse: false) ?? text
    }

    /// 设置里的整数码 → 转换方式（0 原文 / 1 转简 / 2 转繁）。
    static func conversion(for code: Int) -> ReaderChineseConversion {
        switch code {
        case 1: return .simplified
        case 2: return .traditional
        default: return .none
        }
    }
}

/// 下划线线型。
///
/// 口径照 Juyue `ReaderUnderlinePattern`（`ReaderConfig.swift:1199` + `JustifiedBodyText.swift:288`）：
/// 位掩码是 `single | pattern*`，CoreText 的 `kCTUnderlineStyleAttributeName` 吃同一套值。
enum ReaderUnderlinePattern: String, CaseIterable, Identifiable {
    case solid = "实线"
    case dot = "点线"
    case dash = "虚线"
    case dashDot = "点划线"

    var id: String { rawValue }

    /// 转成 `NSUnderlineStyle` 的位掩码；`CTUnderlineStyle` 与之同值。
    var nsUnderlineStyle: Int {
        switch self {
        case .solid: return NSUnderlineStyle.single.rawValue
        case .dot: return NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue
        case .dash: return NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDash.rawValue
        case .dashDot: return NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDashDot.rawValue
        }
    }

    /// 设置里的整数码 → 线型（0 实线 / 1 点线 / 2 虚线 / 3 点划线）。
    static func pattern(for code: Int) -> ReaderUnderlinePattern {
        switch code {
        case 1: return .dot
        case 2: return .dash
        case 3: return .dashDot
        default: return .solid
        }
    }

    /// 旧的三档 `underlineMode`（0 关 / 1 实线 / 2 虚线）→ 线型。
    static func legacy(_ mode: Int) -> ReaderUnderlinePattern {
        mode == 2 ? .dash : .solid
    }
}

/// 正文本变换：智能分段 + 简繁转换。
///
/// 两件事都在「拿到一段原文、还没分页」这个时点做，做完再交给 CoreText 排版，
/// 否则分页用的是变换前的字数、显示的是变换后的字，页界立刻对不上。
enum ReaderTextTransform {

    /// 智能分段：只处理「特别长、又完全没有段落」的行（不少书源整章塞成一行）。
    ///
    /// 逐字照 Juyue `smartParagraphSplit`（`ReaderView.swift:8792`）：
    /// - 短于 120 字原样返回，不动已经分好段的正文；
    /// - 按句末标点 `。！？…` 断句；
    /// - 再把断句拼回正常长度的段落（累计 ≥ 100 字就断一段）。
    static func smartParagraphSplit(_ line: String) -> [String] {
        guard line.count > 120 else { return [line] }

        var sentences: [String] = []
        var buffer = ""
        for ch in line {
            buffer.append(ch)
            if "。！？…".contains(ch) {
                sentences.append(buffer)
                buffer = ""
            }
        }
        if !buffer.isEmpty { sentences.append(buffer) }
        guard sentences.count > 1 else { return [line] }

        var paragraphs: [String] = []
        var current = ""
        for sentence in sentences {
            current += sentence
            if current.count >= 100 {
                paragraphs.append(current)
                current = ""
            }
        }
        if !current.isEmpty { paragraphs.append(current) }
        return paragraphs
    }

    /// 把整章正文按行切开、按需智能分段。
    ///
    /// 返回的顺序就是阅读顺序；调用方按返回数组逐段排版即可。
    static func paragraphs(
        in text: String,
        smartParagraphs: Bool,
        conversion: ReaderChineseConversion
    ) -> [String] {
        guard !text.isEmpty else { return [] }
        let converted = conversion.apply(text)
        var result: [String] = []
        for raw in converted.components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if smartParagraphs {
                result.append(contentsOf: smartParagraphSplit(trimmed))
            } else {
                result.append(trimmed)
            }
        }
        return result
    }
}
