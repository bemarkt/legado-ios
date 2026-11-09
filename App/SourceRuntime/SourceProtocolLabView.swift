import SwiftUI
import UniformTypeIdentifiers

struct SourceProtocolLabView: View {
    @State private var source = ""
    @State private var input = #"{"query":"示例"}"#
    @State private var operation: SourceOperation = .search
    @State private var snapshot: SourceSnapshot?
    @State private var result = ""
    @State private var task: Task<Void, Never>?
    @State private var importing = false

    init(initialSource: String = "", initialOperation: SourceOperation = .search) {
        _source = State(initialValue: initialSource)
        _operation = State(initialValue: initialOperation)
        _input = State(initialValue: Self.exampleInput(initialOperation))
    }
    private static func exampleInput(_ operation: SourceOperation) -> String {
        switch operation {
        case .search: return #"{"query":"示例"}"#
        case .book: return #"{"ref":{"id":"demo"}}"#
        case .chapters: return #"{"book":{"id":"demo"}}"#
        case .content: return #"{"book":{"id":"demo"},"chapter":{"id":"chapter-1"}}"#
        }
    }
    var body: some View {
        Form {
            Section {
                Text("这是自有书源协议的实验入口。可检查单文件源码，并逐项执行搜索、详情、目录与正文。此处结果只用于调试；保存书源和离线阅读请使用「原生书源阅读」。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("载入离线示例") {
                    do { source = try SourceAssets.script("OfflineExample.source"); snapshot = nil; result = "" }
                    catch { result = error.localizedDescription }
                }
                Button("打开 .source.js 文件") { importing = true }
            } header: { Text("书源协议实验室") }
            Section("源码") {
                TextEditor(text: $source).font(.system(.caption, design: .monospaced)).frame(minHeight: 180)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                Button("检查元数据与语法") { inspect() }.disabled(source.isEmpty)
                if let snapshot {
                    Text("\(snapshot.inspection.metadata.name) · \(snapshot.inspection.metadata.version)")
                    Text("SHA-256: \(snapshot.sha256)").font(.caption2.monospaced()).textSelection(.enabled)
                    Text("声明的网站：\(snapshot.inspection.metadata.origins.joined(separator: "、"))")
                        .font(.caption).foregroundStyle(.secondary)
                    if !snapshot.inspection.unsupportedRequirements.isEmpty {
                        Text("尚不支持：\(snapshot.inspection.unsupportedRequirements.joined(separator: "、"))").foregroundStyle(.orange)
                    }
                }
            }
            Section("执行操作") {
                Picker("操作", selection: $operation) {
                    ForEach(SourceOperation.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                TextEditor(text: $input).font(.system(.caption, design: .monospaced)).frame(minHeight: 90)
                    .autocorrectionDisabled().textInputAutocapitalization(.never)
                Button("执行所选操作") { execute() }.disabled(snapshot == nil)
                Text("执行会运行源代码，允许通过原生网络访问其声明的 HTTPS 网站。请先查看源码和网站范围。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("结果") {
                Text(result.isEmpty ? "尚未运行" : result).font(.caption.monospaced()).textSelection(.enabled)
            }
        }
        .disabled(task != nil)
        .overlay(alignment: .bottom) {
            if task != nil {
                HStack { ProgressView(); Button("取消") { task?.cancel() } }
                    .padding().background(.regularMaterial, in: Capsule())
            }
        }
        .navigationTitle("书源协议实验室")
        .navigationBarTitleDisplayMode(.inline)
        .readingTabBarHidden()
        .onDisappear { task?.cancel() }
        .onChange(of: source) { snapshot = nil }
        .onChange(of: operation) {
            input = Self.exampleInput(operation)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.javaScript, .plainText, .data]) { selection in
            do {
                let url = try selection.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let limit = try SourceProfile.load().limits.sourceBytes
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: limit + 1) ?? Data()
                guard data.count <= limit, let text = String(data: data, encoding: .utf8) else {
                    throw SourceFailure(code: "INVALID_INPUT", message: "文件必须为 UTF-8 且不超过 2 MiB")
                }
                source = text
                result = "文件已读取。检查元数据不会执行源码。"
            } catch { result = error.localizedDescription }
        }
    }

    private func inspect() {
        task = Task { @MainActor in
            defer { task = nil }
            do {
                snapshot = try await SourceInspector().inspect(Data(source.utf8))
                result = "静态检查通过；尚未执行源码。"
            } catch { snapshot = nil; result = error.localizedDescription }
        }
    }
    private func execute() {
        guard let snapshot else { return }
        task = Task { @MainActor in
            defer { task = nil }
            do {
                let json = try await SourceRuntime().run(operation, inputJSON: input, snapshot: snapshot)
                let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
                result = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
            } catch { result = error.localizedDescription }
        }
    }
}
