#if canImport(UIKit)
import UIKit
#endif
import SwiftUI

@MainActor
final class SourceDebugViewModel: ObservableObject {
    @Published var keyword = ""
    @Published private(set) var isRunning = false
    @Published private(set) var report: BookSourceDebugReport?

    private let debugger: BookSourceDebugger
    private var task: Task<Void, Never>?

    init(debugger: BookSourceDebugger = .init()) {
        self.debugger = debugger
    }

    deinit { task?.cancel() }

    func run(source: BookSource) {
        let keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }
        task?.cancel()
        isRunning = true
        report = nil
        task = Task { [debugger] in
            let value = await debugger.run(source: source, keyword: keyword)
            guard !Task.isCancelled else { return }
            report = value
            isRunning = false
        }
    }
}

struct SourceDebugView: View {
    let source: BookSource
    @StateObject private var model = SourceDebugViewModel()
    /// iOS 15 没有 ShareLink，导出退回复制到剪贴板，用它给一次可见反馈。
    @State private var copiedNotice = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                introCard
                runCard
                if model.isRunning { runningCard }
                if let report = model.report { reportView(report) }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 30)
        }
        .background(ReadingTheme.canvas)
        // 调试结果是排错依据，必须能选中复制：贴给协作者、写进 issue，
        // 或者直接拿去和页面真实 DOM 逐字对照。
        .textSelection(.enabled)
        .navigationTitle("书源调试")
        .navigationBarTitleDisplayMode(.inline)
        // 二级页隐藏 TabBar：调试是「看完就返回」的浏览态，
        // 底部标签会挤掉纵向空间，也与返回手势抢注意力。
        .readingTabBarHidden()
    }

    /// 整体导出：一次给出全部阶段，不用逐个展开复制。
    ///
    /// iOS 16+ 用 ShareLink 直接分享/存文件；iOS 15 没有 ShareLink，
    /// 退回复制到剪贴板并给一行可见反馈，避免点了没反应。
    @ViewBuilder
    private func exportButton(for report: BookSourceDebugReport) -> some View {
        let text = DebugReportExport.text(for: report)
        if #available(iOS 16.0, *) {
            ShareLink(item: text) { exportLabel }
                .buttonStyle(.plain)
                .foregroundStyle(ReadingTheme.accent)
                .accessibilityLabel("导出完整调试日志")
        } else {
            Button {
                DebugClipboard.copy(text)
                copiedNotice = true
            } label: {
                exportLabel
            }
            .buttonStyle(.plain)
            .foregroundStyle(ReadingTheme.accent)
            .accessibilityLabel("导出完整调试日志")
        }
    }

    /// 热区补到 44pt：小图标或小字号文字不满足移动端最小触控面积，
    /// 用 contentShape 把整块可点区域撑开，而不是靠视觉尺寸。
    private var exportLabel: some View {
        Label("导出日志", systemImage: "square.and.arrow.up")
            .font(.caption.bold())
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
    }

    private var introCard: some View {
        ReadingCard {
            HStack(spacing: 13) {
                Image(systemName: "stethoscope")
                    .font(.title2).foregroundStyle(ReadingTheme.coral)
                    .frame(width: 46, height: 46)
                    .background(ReadingTheme.coral.opacity(0.11), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 3) {
                    Text(source.bookSourceName).font(.headline)
                    Text("依次验证搜索 → 详情 → 目录 → 第一章正文")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.top, 8)
    }

    private var runCard: some View {
        ReadingCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("样本关键词").font(.caption.bold()).foregroundStyle(.secondary)
                TextField("输入该书源能搜到的书名", text: $model.keyword)
                    .textFieldStyle(.roundedBorder)
                    .textInputAutocapitalization(.never)
                    .submitLabel(.go)
                    .onSubmit { model.run(source: source) }
                Button { model.run(source: source) } label: {
                    Label(model.isRunning ? "正在调试…" : "运行完整链路", systemImage: "play.fill")
                        .font(.headline).frame(maxWidth: .infinity)
                }
                .readingProminentButtonStyle()
                .disabled(model.isRunning || model.keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private var runningCard: some View {
        ReadingCard {
            HStack(spacing: 12) {
                ProgressView()
                VStack(alignment: .leading, spacing: 3) {
                    Text("端到端检查进行中").font(.subheadline.bold())
                    Text("请求只发送给这个书源，最多读取 5 页目录与正文。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }

    @ViewBuilder
    private func reportView(_ report: BookSourceDebugReport) -> some View {
        ReadingCard {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(report.passed ? "完整链路通过" : "发现兼容问题").font(.headline)
                    Text(report.passed ? "该样本已成功读取到正文" : "展开失败阶段查看规则诊断")
                        .font(.caption).foregroundStyle(.secondary)
                    if copiedNotice {
                        Text("完整日志已复制到剪贴板")
                            .font(.caption2).foregroundStyle(ReadingTheme.accent)
                    }
                }
                Spacer(minLength: 8)
                exportButton(for: report)
                Image(systemName: report.passed ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.title2).foregroundStyle(report.passed ? .green : .orange)
            }
        }
        VStack(spacing: 10) {
            ForEach(report.steps) { step in DebugStepCard(step: step) }
        }
        if let preview = report.contentPreview {
            ReadingCard {
                VStack(alignment: .leading, spacing: 9) {
                    Label(report.sampleChapterTitle ?? "正文样本", systemImage: "text.quote")
                        .font(.headline)
                    Text(preview).font(.footnote).foregroundStyle(.secondary).lineSpacing(3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

@MainActor
private final class SourceBatchTestModel: ObservableObject {
    enum Status: Equatable {
        case waiting
        case testing
        case passed(Int)
        case failed(String)
    }

    @Published private(set) var statuses: [String: Status] = [:]
    @Published private(set) var completedCount = 0
    @Published private(set) var totalCount = 0
    @Published private(set) var isTesting = false
    @Published var selectedFailedIDs = Set<String>()

    var failedCount: Int {
        statuses.values.reduce(into: 0) { count, status in
            if case .failed = status { count += 1 }
        }
    }

    private let service: BookSearchService
    private var task: Task<Void, Never>?

    init(service: BookSearchService = .init()) {
        self.service = service
    }

    deinit { task?.cancel() }

    func start(sources: [BookSource], keyword: String) {
        stop()
        let keyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty, !sources.isEmpty else { return }
        statuses = Dictionary(uniqueKeysWithValues: sources.map { ($0.id, .waiting) })
        selectedFailedIDs = []
        completedCount = 0
        totalCount = sources.count
        isTesting = true

        task = Task { [service] in
            for source in sources.prefix(16) { statuses[source.id] = .testing }
            var startedCount = min(16, sources.count)
            for await outcome in service.searchOutcomes(
                keyword: keyword,
                sources: sources,
                maximumConcurrentSources: ApplicationSettingsStore.shared.settings.concurrentSources,
                includeDisabled: true
            ) {
                guard !Task.isCancelled else { return }
                completedCount += 1
                if outcome.books.isEmpty {
                    let message = outcome.diagnostics.first(where: { $0.severity == .error })?.message
                        ?? "没有搜索到结果"
                    statuses[outcome.sourceID] = .failed(message)
                    selectedFailedIDs.insert(outcome.sourceID)
                } else {
                    statuses[outcome.sourceID] = .passed(outcome.books.count)
                }
                if startedCount < sources.count {
                    statuses[sources[startedCount].id] = .testing
                    startedCount += 1
                }
            }
            guard !Task.isCancelled else { return }
            isTesting = false
            task = nil
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isTesting = false
        for (id, status) in statuses where status == .testing || status == .waiting {
            statuses[id] = .waiting
        }
    }

    func toggleSelection(_ sourceID: String) {
        if !selectedFailedIDs.insert(sourceID).inserted { selectedFailedIDs.remove(sourceID) }
    }
}

struct SourceBatchTestView: View {
    private enum CleanupAction: String, Identifiable {
        case disable
        case delete
        var id: String { rawValue }
    }

    @EnvironmentObject private var library: SourceLibraryModel
    @StateObject private var model = SourceBatchTestModel()
    @AppStorage("sourceTestKeyword") private var keyword = "我的"
    @State private var includesDisabled = false
    @State private var onlyShowsFailed = false
    @State private var cleanupAction: CleanupAction?

    private var testedSources: [BookSource] {
        includesDisabled ? library.sources : library.sources.filter(\.enabled)
    }

    private var visibleSources: [BookSource] {
        guard onlyShowsFailed else { return testedSources }
        return testedSources.filter {
            if case .failed? = model.statuses[$0.id] { return true }
            return false
        }
    }

    var body: some View {
        List {
            Section {
                TextField("校验搜索词", text: $keyword)
                    .textInputAutocapitalization(.never)
                Toggle("包含已停用书源", isOn: $includesDisabled)
                    .disabled(model.isTesting)
                Toggle("只看失败", isOn: $onlyShowsFailed)
            } footer: {
                Text("快速测试以搜索是否能返回结果为准。部分正常书源可能不收录当前关键词，删除前请复核或更换关键词重测。")
            }

            if model.totalCount > 0 {
                Section {
                    ProgressView(value: Double(model.completedCount), total: Double(model.totalCount))
                    HStack {
                        Text("已完成 \(model.completedCount)/\(model.totalCount)")
                        Spacer()
                        Text("失败 \(model.failedCount) · 已选 \(model.selectedFailedIDs.count)")
                            .foregroundStyle(model.failedCount == 0 ? Color.secondary : Color.red)
                    }
                    .font(.subheadline.monospacedDigit())
                }
            }

            Section("书源") {
                ForEach(visibleSources) { source in
                    SourceBatchTestRow(
                        source: source,
                        status: model.statuses[source.id] ?? .waiting,
                        selected: model.selectedFailedIDs.contains(source.id),
                        onToggle: { model.toggleSelection(source.id) }
                    )
                }
            }
        }
        .navigationTitle("书源测试")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if model.isTesting {
                    Button("停止", systemImage: "stop.fill") { model.stop() }
                } else {
                    Button("开始", systemImage: "play.fill") {
                        model.start(sources: testedSources, keyword: keyword)
                    }
                    .disabled(testedSources.isEmpty || keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !model.isTesting, !model.selectedFailedIDs.isEmpty {
                HStack {
                    Button("停用所选", systemImage: "pause.circle") { cleanupAction = .disable }
                    Spacer()
                    Button("删除所选", systemImage: "trash", role: .destructive) { cleanupAction = .delete }
                }
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 18).padding(.vertical, 12)
                .background(.ultraThinMaterial)
            }
        }
        .alert(item: $cleanupAction) { action in
            Alert(
                title: Text(action == .delete ? "删除失败书源？" : "停用失败书源？"),
                message: Text("将处理已勾选的 \(model.selectedFailedIDs.count) 个书源。搜索不到当前关键词不一定代表书源永久失效。"),
                primaryButton: .destructive(Text(action == .delete ? "删除" : "停用")) {
                    let ids = model.selectedFailedIDs
                    Task {
                        if action == .delete { await library.remove(sourceIDs: ids) }
                        else { await library.setEnabled(false, for: ids) }
                        model.selectedFailedIDs = []
                    }
                },
                secondaryButton: .cancel()
            )
        }
    }
}

private struct SourceBatchTestRow: View {
    let source: BookSource
    let status: SourceBatchTestModel.Status
    let selected: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(source.bookSourceName).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if case .failed = status {
                Button(action: onToggle) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var detail: String {
        switch status {
        case .waiting: "等待测试"
        case .testing: "正在测试…"
        case .passed(let count): "通过，搜索到 \(count) 条结果"
        case .failed(let message): message
        }
    }

    private var icon: String {
        switch status {
        case .waiting: "clock"
        case .testing: "arrow.triangle.2.circlepath"
        case .passed: "checkmark.circle.fill"
        case .failed: "xmark.circle.fill"
        }
    }

    private var color: Color {
        switch status {
        case .waiting: .secondary
        case .testing: ReadingTheme.accent
        case .passed: .green
        case .failed: .red
        }
    }
}

private enum DebugClipboard {
    static func copy(_ text: String) {
        #if canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
    }
}

/// 把完整调试报告导出成纯文本。
///
/// 逐字保留 code 与 rule 原文：调试里最贵的错误就是字符级误读
/// （`y-list__item` 被写成 `y-list_item` 多花了一整轮），所以导出不做任何
/// 截断、换行重排或省略号处理，保证贴出去的就是引擎给的原文。
private enum DebugReportExport {
    static func text(for report: BookSourceDebugReport) -> String {
        var lines: [String] = []
        lines.append("书源：\(report.sourceID)")
        lines.append("关键词：\(report.keyword)")
        lines.append("结论：\(report.passed ? "完整链路通过" : "发现兼容问题")")
        if let name = report.sampleBookName { lines.append("样本书籍：\(name)") }
        if let title = report.sampleChapterTitle { lines.append("样本章节：\(title)") }
        for step in report.steps {
            lines.append("")
            lines.append("[\(step.stage.title)] \(step.status.rawValue) · \(step.summary)")
            if step.elapsedMilliseconds > 0 { lines.append("耗时 \(step.elapsedMilliseconds) ms") }
            for diagnostic in step.diagnostics {
                lines.append("· [\(diagnostic.severity.rawValue)] \(diagnostic.code): \(diagnostic.message)")
                if !diagnostic.rule.isEmpty { lines.append("  rule: \(diagnostic.rule)") }
            }
        }
        if let preview = report.contentPreview {
            lines.append("")
            lines.append("正文预览：\(preview)")
        }
        return lines.joined(separator: "\n")
    }
}

private struct DebugStepCard: View {
    let step: SourceDebugStep

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 9) {
                copyButton
                if step.diagnostics.isEmpty {
                    Text("该阶段没有规则诊断。")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(step.diagnostics) { diagnostic in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(diagnostic.message).font(.caption)
                            if !diagnostic.rule.isEmpty {
                                Text(diagnostic.rule)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }
                            Text(diagnostic.code).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundStyle(color)
                    .frame(width: 34, height: 34)
                    .background(color.opacity(0.1), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text(step.stage.title).font(.subheadline.bold())
                    Text(step.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                if step.elapsedMilliseconds > 0 {
                    Text("\(step.elapsedMilliseconds) ms")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(14)
        .background(.background, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 17, style: .continuous).stroke(.primary.opacity(0.06)) }
        // 这里不要再挂 .contextMenu：iOS 的 contextMenu 与整页的
        // .textSelection(.enabled) 共用长按手势，挂了菜单之后长按只会弹出菜单，
        // 展开后的日志文本反而选不中——体验上等于把「可选中」废掉。
        // 复制入口留在展开区顶部，整体导出放在报告头部。
    }

    private var copyButton: some View {
        Button {
            copyStep()
        } label: {
            Label("复制本阶段日志", systemImage: "doc.on.doc")
                .font(.caption2)
        }
        .buttonStyle(.plain)
        .foregroundStyle(ReadingTheme.accent)
    }

    /// 报告里出现最多的返工原因就是「文本选不中、只能截图识别」：
    /// `y-list__item` 被识别成 `y-list_item`，多花了一整轮排查。
    /// 所以复制按两条路给：整页 `.textSelection(.enabled)` 支持手选，
    /// 卡片里再给一键复制（含 code 与 rule 原文，逐字无歧义）。

    /// 一键复制本阶段日志：标题、状态、耗时、全部诊断（含 code 与 rule 原文）。
    /// 手抄或截图识别容易出错——上次 `y-list__item` 被识别成 `y-list_item`，
    /// 直接多花了一轮排查时间。
    private func copyStep() {
        var lines = ["[\(step.stage.title)] \(step.status.rawValue) · \(step.summary)"]
        if step.elapsedMilliseconds > 0 { lines.append("耗时 \(step.elapsedMilliseconds) ms") }
        for diagnostic in step.diagnostics {
            lines.append("· [\(diagnostic.severity.rawValue)] \(diagnostic.code): \(diagnostic.message)")
            if !diagnostic.rule.isEmpty { lines.append("  rule: \(diagnostic.rule)") }
        }
        DebugClipboard.copy(lines.joined(separator: "\n"))
    }

    private var color: Color {
        switch step.status {
        case .passed: .green
        case .warning: .orange
        case .failed: .red
        case .skipped: .secondary
        }
    }

    private var icon: String {
        switch step.status {
        case .passed: "checkmark"
        case .warning: "exclamationmark"
        case .failed: "xmark"
        case .skipped: "forward.end"
        }
    }
}
