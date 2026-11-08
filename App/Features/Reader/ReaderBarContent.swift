import Foundation
import UIKit

/// 页眉页脚每栏能填什么。
///
/// 口径照 Juyue `ReaderBarContent`（`ReaderConfig.swift:1137`）：24 种条目，
/// 其中电量图标 / 电量条 / 总进度条要画图形，不能只当文本塞进一行。
/// rawValue 就是设置界面显示的标签，也是存进 UserDefaults 的键 —— 前 6 项不要改，
/// 否则老配置解不出来。
enum ReaderBarContent: String, CaseIterable, Identifiable {
    case none = "无"
    case bookName = "书名"
    case chapterTitle = "标题"
    case shortChapterTitle = "短标题"
    case progress = "进度(%)"
    case pageInfo = "页码"
    case pagePercent = "页进度"
    case pageNumberLabel = "第 N 页"
    case bookPercent = "总进度"
    case bookPercentBar = "总进度条"
    case time = "时间"
    case clockWithSeconds = "时间(秒)"
    case date = "日期"
    case weekday = "星期"
    case userDate = "自定义日期"
    case batteryLevel = "电量(%)"
    case batteryIcon = "电量图标"
    case batteryGlyphWithPercent = "图标+电量"
    case batteryBar = "电量条"
    case chapterCount = "共 N 章"
    case chaptersShort = "N 章"
    case elapsedReadingTime = "阅读时长"
    case remainingReadingTime = "剩余时间"
    case userText = "自定义"

    var id: String { rawValue }

    /// 电量与进度条这类要画图形，不能只当文本塞进 HStack。
    var isGraphical: Bool {
        switch self {
        case .batteryIcon, .batteryGlyphWithPercent, .batteryBar, .bookPercentBar:
            return true
        default:
            return false
        }
    }

    /// 一栏的多个条目存成一个字符串：用 `|` 连接 rawValue。
    /// rawValue 是中文标签、本身不含 `|`，所以这一层不需要 JSON 编解码。
    static func encode(_ items: [ReaderBarContent]) -> String {
        items.map(\.rawValue).joined(separator: "|")
    }

    /// 一栏里解出来的顺序就是显示顺序。
    static func decode(_ text: String) -> [ReaderBarContent] {
        guard !text.isEmpty else { return [] }
        return text.split(separator: "|").compactMap { ReaderBarContent(rawValue: String($0)) }
    }

    /// 只能画文字的地方（页内页眉页脚）用的退化文案：图形项退成方块 / 百分比，
    /// 其余照常走 `readerBarText`。总进度条没有文字形态，返回空串。
    func plainText(_ ctx: ReaderBarContext) -> String {
        switch self {
        case .batteryIcon:
            return "▰"
        case .batteryBar:
            guard let level = ReaderBarBattery.level() else { return "" }
            return "▰" + String(format: "%.0f%%", level * 100)
        case .bookPercentBar:
            return ""
        default:
            return readerBarText(self, ctx)
        }
    }

    /// 旧版本的 12 个整数码（`tipHeaderLeft` 那批 `@AppStorage`）→ 新条目。
    ///
    /// 老用户存的是整数，没有对应项就映射成空栏，不去猜他想要什么。
    /// 6 / 8 / 9 三个旧码本来就是「两项拼一行」，这里映射成两条，栏里按顺序排。
    static func legacy(_ code: Int) -> [ReaderBarContent] {
        switch code {
        case 1: return [.chapterTitle]
        case 2: return [.time]
        case 3: return [.batteryIcon]
        case 4: return [.pageInfo]
        case 5: return [.progress]
        case 6: return [.pageInfo, .progress]
        case 7: return [.bookName]
        case 8: return [.time, .bookPercentBar]
        case 9: return [.time, .batteryLevel]
        case 10: return [.batteryLevel]
        case 11: return [.pageInfo]
        default: return []
        }
    }
}

/// 页眉页脚格式化需要的全部输入。
///
/// 照 Juyue `ReaderBarContext`（`ReaderConfig.swift:1807`）：滚动、分页、仿真翻页
/// 三条路径共用同一套取值，免得同一栏在不同模式下显示不一样。
struct ReaderBarContext {
    var bookName: String = ""
    var chapterTitle: String = ""
    var chapterIndex: Int = 0
    var chapterCount: Int = 0
    var pageIndex: Int = 0
    var pageCount: Int = 0
    /// 是否分页模式：页码类条目只有分页时才有意义。
    var isPaged: Bool = false
    /// 全书进度 0...1
    var bookProgress: Double = 0
    /// 本次阅读会话起点，没有就不显示时长
    var sessionStart: Date?
    var shortTitleLength: Int = 6
    var customDatePattern: String = "M月d日"
    var customBarText: String = ""

    init() {}
}

/// 设备电量。
///
/// 读之前要先打开电池监控，否则 `batteryLevel` 恒为 -1。
enum ReaderBarBattery {
    /// 设备电量 0...1，拿不到返回 nil
    static func level() -> Double? {
        let device = UIDevice.current
        if !device.isBatteryMonitoringEnabled { device.isBatteryMonitoringEnabled = true }
        let level = device.batteryLevel
        return level < 0 ? nil : Double(level)
    }

    /// 电量图标名：25% 一档取 SF Symbol，与 Juyue `batterySymbolName` 同口径。
    static func symbolName(for level: Double?) -> String {
        guard let level else { return "battery.0" }
        switch level {
        case ..<0.13: return "battery.0"
        case ..<0.38: return "battery.25"
        case ..<0.63: return "battery.50"
        case ..<0.88: return "battery.75"
        default: return "battery.100"
        }
    }
}

/// `DateFormatter` 建一次要几百微秒，而页眉页脚每帧都会问一次时间。
/// 按格式串缓存住，不然翻页时每帧都在建格式化器。
private final class ReaderBarClock: @unchecked Sendable {
    static let shared = ReaderBarClock()
    private var cache: [String: DateFormatter] = [:]
    private let lock = NSLock()

    func string(for pattern: String) -> String {
        lock.lock()
        let formatter: DateFormatter
        if let cached = cache[pattern] {
            formatter = cached
        } else {
            let made = DateFormatter()
            made.locale = Locale(identifier: "zh_CN")
            made.dateFormat = pattern
            cache[pattern] = made
            formatter = made
        }
        lock.unlock()
        return formatter.string(from: Date())
    }
}

private func readerBarClock(_ pattern: String) -> String {
    ReaderBarClock.shared.string(for: pattern)
}

/// 把一栏显示项格式化成文字。图形项（电量图标、进度条）返回空串，由视图层单独画。
///
/// 逐项照 Juyue `readerBarText`（`ReaderConfig.swift:1869`），文案与小数位都不改。
func readerBarText(_ content: ReaderBarContent, _ ctx: ReaderBarContext) -> String {
    switch content {
    case .none, .bookPercentBar, .batteryIcon, .batteryBar:
        return ""
    case .bookName:
        return ctx.bookName
    case .chapterTitle:
        return ctx.chapterTitle
    case .shortChapterTitle:
        guard !ctx.chapterTitle.isEmpty else { return "" }
        let limit = max(2, ctx.shortTitleLength)
        return ctx.chapterTitle.count <= limit ? ctx.chapterTitle : String(ctx.chapterTitle.prefix(limit)) + "…"
    case .progress:
        guard ctx.chapterCount > 0 else { return "" }
        return String(format: "%.1f%%", Double(ctx.chapterIndex + 1) / Double(ctx.chapterCount) * 100)
    case .pageInfo, .pagePercent:
        if ctx.isPaged, ctx.pageCount > 0 { return "\(ctx.pageIndex + 1)/\(ctx.pageCount)" }
        guard ctx.chapterCount > 0 else { return "" }
        return "\(ctx.chapterIndex + 1)/\(ctx.chapterCount)"
    case .pageNumberLabel:
        guard ctx.isPaged, ctx.pageCount > 0 else { return "" }
        return "第 \(ctx.pageIndex + 1) 页"
    case .bookPercent:
        return ctx.bookProgress <= 0 ? "" : String(format: "%.1f%%", ctx.bookProgress * 100)
    case .time:
        return readerBarClock("HH:mm")
    case .clockWithSeconds:
        return readerBarClock("HH:mm:ss")
    case .date:
        return readerBarClock("yyyy-MM-dd")
    case .weekday:
        return readerBarClock("EEEE")
    case .userDate:
        return readerBarClock(ctx.customDatePattern)
    case .batteryLevel, .batteryGlyphWithPercent:
        guard let level = ReaderBarBattery.level() else { return "" }
        return "\(Int((level * 100).rounded()))%"
    case .chapterCount:
        return ctx.chapterCount > 0 ? "共 \(ctx.chapterCount) 章" : ""
    case .chaptersShort:
        return ctx.chapterCount > 0 ? "\(ctx.chapterCount)章" : ""
    case .elapsedReadingTime:
        guard let start = ctx.sessionStart else { return "" }
        return barDurationText(Date().timeIntervalSince(start))
    case .remainingReadingTime:
        guard let start = ctx.sessionStart else { return "" }
        let elapsed = Date().timeIntervalSince(start)
        // 样本太少不外推，免得刚打开就报一个离谱的数字
        guard ctx.bookProgress > 0.02, elapsed > 60 else { return "" }
        let remaining = elapsed / ctx.bookProgress - elapsed
        guard remaining > 0, remaining < 24 * 3600 else { return "" }
        return "约剩 " + barDurationText(remaining)
    case .userText:
        return ctx.customBarText
    }
}

private func barDurationText(_ seconds: TimeInterval) -> String {
    let minutes = Int(seconds / 60)
    if minutes <= 0 { return "刚刚" }
    if minutes < 60 { return "\(minutes) 分" }
    return "\(minutes / 60) 时 \(minutes % 60) 分"
}
