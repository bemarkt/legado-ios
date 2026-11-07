import Foundation

#if SWIFT_PACKAGE
import LegadoCore
#endif

/// 阅读器换章链路的诊断日志。
///
/// 只走一个入口：`DiagnosticLog`（设置 → 诊断日志里能直接看、也能导出文本）。
/// 换章这条路有三条触发通路（位移旁听、左右划兜底、程序化翻页到头），
/// 出问题时在日志里看同一时刻出现了几条「章界翻页」就够了，不用往代码里撒 print。
enum ReaderChapterTrace {
    static func log(_ message: @autoclosure () -> String) {
        DiagnosticLog.shared.record(category: "阅读", message: message())
    }
}
