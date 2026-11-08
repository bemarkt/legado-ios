import CoreText
import UIKit

/// 按配置挑正文字体：优先用对应字重，找不到就派生加粗，再不行退回系统默认。
///
/// 分页层与绘制层都必须走这一个入口：换字体或把字距调大后，两边若各取一份字体，
/// 量出来的行宽与画出来的行宽就会差半个字，行尾被页边裁掉。
enum ReaderFontFactory {
    static func ctFont(
        postScriptName: String,
        boldPostScriptName: String?,
        size: CGFloat,
        weightLevel: Int
    ) -> CTFont {
        let baseName = postScriptName.isEmpty ? "PingFangSC-Regular" : postScriptName
        let font = CTFontCreateWithName(baseName as CFString, size, nil)

        if weightLevel <= 0 {
            // kCTFontWeightTrait 的刻度：-0.4 细、0 常规、0.4 粗
            return applyWeight(-0.4, to: font, size: size)
        }

        guard weightLevel >= 2 else { return font }

        if let boldName = boldPostScriptName, !boldName.isEmpty {
            let candidate = CTFontCreateWithName(boldName as CFString, size, nil)
            let resolved = CTFontCopyPostScriptName(candidate) as String
            if resolved.caseInsensitiveCompare(boldName) == .orderedSame {
                return candidate
            }
        }
        return applyWeight(0.4, to: font, size: size)
    }

    private static func applyWeight(_ weight: CGFloat, to font: CTFont, size: CGFloat) -> CTFont {
        let traits: [CFString: Any] = [kCTFontWeightTrait: weight]
        let attributes: [CFString: Any] = [kCTFontTraitsAttribute: traits]
        let descriptor = CTFontDescriptorCreateWithAttributes(attributes as CFDictionary)
        return CTFontCreateCopyWithAttributes(font, size, nil, descriptor)
    }
}
