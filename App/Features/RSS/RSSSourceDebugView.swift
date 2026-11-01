import SwiftUI

@MainActor
private final class RSSSourceDebugModel: ObservableObject {
    @Published var input = ""
    @Published var running = false
    @Published var report: RSSSourceDebugReport?
    private let debugger = RSSSourceDebugger()
    private var task: Task<Void, Never>?

    func run(_ source: RssSource) {
        task?.cancel(); running = true; report = nil
        task = Task { [debugger, input] in
            let result = await debugger.run(source: source, input: input)
            guard !Task.isCancelled else { return }
            report = result; running = false
        }
    }
    deinit { task?.cancel() }
}

struct RSSSourceDebugView: View {
    let source: RssSource
    @StateObject private var model = RSSSourceDebugModel()
    @State private var rawTitle = ""
    @State private var rawText: String?

    var body: some View {
        List {
            Section("调试输入") {
                Text(source.sourceName).font(.headline)
                TextField("关键词，或 分类::地址", text: $model.input)
                    .textInputAutocapitalization(.never).disableAutocorrection(true)
                    .onSubmit { model.run(source) }
                Button { model.run(source) } label: { Label(model.running ? "正在调试…" : "运行完整链路", systemImage: "play.fill") }
                    .disabled(model.running)
            }
            if model.running { Section { HStack { ProgressView(); Text("正在请求并解析列表与正文") } } }
            if let report = model.report {
                Section(report.passed ? "调试通过" : "发现兼容问题") {
                    ForEach(report.steps) { step in
                        DisclosureGroup {
                            if step.diagnostics.isEmpty { Text("无规则诊断").foregroundStyle(.secondary) }
                            ForEach(step.diagnostics) { item in
                                VStack(alignment: .leading) { Text(item.message); Text(item.code).font(.caption.monospaced()).foregroundStyle(.secondary) }
                            }
                        } label: {
                            Label { VStack(alignment: .leading) { Text(step.stage.title); Text(step.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2) } } icon: { Image(systemName: icon(step.status)).foregroundStyle(color(step.status)) }
                        }
                    }
                }
                if !report.articles.isEmpty {
                    Section("文章样本") { ForEach(report.articles.prefix(10)) { Text($0.title) } }
                }
                if let preview = report.contentPreview { Section("正文样本") { Text(preview).textSelection(.enabled) } }
            }
        }
        .navigationTitle("RSS源调试")
        .readingTabBarHidden()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu("查看源码", systemImage: "doc.plaintext") {
                    Button("列表源码") { rawTitle = "列表源码"; rawText = model.report?.listSource }.disabled(model.report?.listSource == nil)
                    Button("正文源码") { rawTitle = "正文源码"; rawText = model.report?.contentSource }.disabled(model.report?.contentSource == nil)
                }
            }
        }
        .sheet(isPresented: Binding(get: { rawText != nil }, set: { if !$0 { rawText = nil } })) {
            ReadingNavigationStack { ScrollView { Text(rawText ?? "").font(.caption.monospaced()).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding() }.navigationTitle(rawTitle).toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { rawText = nil } } } }
        }
    }

    private func icon(_ status: SourceDebugStatus) -> String { switch status { case .passed: "checkmark.circle.fill"; case .warning: "exclamationmark.triangle.fill"; case .failed: "xmark.circle.fill"; case .skipped: "forward.end.circle" } }
    private func color(_ status: SourceDebugStatus) -> Color { switch status { case .passed: .green; case .warning: .orange; case .failed: .red; case .skipped: .secondary } }
}
