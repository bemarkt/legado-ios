import SwiftUI
import UniformTypeIdentifiers

extension SourceIssue {
    init(error: Error) {
        if let failure = error as? SourceFailure { self.init(code: failure.code, retryAfterMs: failure.retryAfterMs) }
        else if let failure = error as? SourceDomainError { self.init(code: failure.code.rawValue) }
        else if let failure = error as? SourceHostHTTPFailure { self.init(code: failure.code.rawValue) }
        else if error is CancellationError { self.init(code: "CANCELLED") }
        else { self.init(code: "UNKNOWN") }
    }
}

struct NativeSourceIssueView: View {
    @ObservedObject var model: NativeSourceLibrary
    let installation: SourceInstallation
    let issue: SourceIssue
    var retry: (() -> Void)? = nil
    @State private var accounts = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(issue.title).font(.headline)
            Text(issue.message).font(.footnote).foregroundStyle(.secondary)
            Text(issue.code).font(.caption.monospaced()).foregroundStyle(.secondary)
            if issue.recovery == .login {
                Button("账号与登录") { accounts = true }.frame(minHeight: 44)
            }
            if let retry, issue.recovery == .retry || issue.code == "CANCELLED" {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Button(issue.canRetry(at: context.date) ? "重试" : "等待后重试") { retry() }
                        .disabled(!issue.canRetry(at: context.date)).frame(minHeight: 44)
                }
            }
            NavigationLink("书源设置") { NativeSourceSettingsView(model: model, initialInstallation: installation) }
                .frame(minHeight: 44)
        }
        .buttonStyle(.borderless)
        .sheet(isPresented: $accounts) {
            NavigationStack {
                NativeSourceAccountsView(model: model, initialInstallation: installation)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { accounts = false } } }
            }
        }
    }
}

private struct NativeSourceDiagnosticFile: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

struct NativeSourceDiagnosticsView: View {
    @ObservedObject var model: NativeSourceLibrary
    @State private var records: [SourceDiagnosticRecord] = []
    @State private var data = Data()
    @State private var exporting = false
    @State private var clearing = false
    @State private var feedback: String?
    var body: some View {
        List {
            Section {
                Text("最近 128 次书源操作的状态和耗时，仅在本次运行中保留。报告不包含查询词、网站地址、凭据或正文。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button("导出诊断记录") {
                    Task {
                        do { data = try await SourceDiagnostics.shared.export(); exporting = true }
                        catch { feedback = error.localizedDescription }
                    }
                }.frame(minHeight: 44).disabled(records.isEmpty)
                Button("清除记录", role: .destructive) { clearing = true }.frame(minHeight: 44).disabled(records.isEmpty)
            }
            if records.isEmpty { ContentUnavailableView("暂无记录", systemImage: "list.bullet.rectangle", description: Text("执行书源操作后，可在这里查看结果。")) }
            ForEach(records) { record in
                NavigationLink {
                    NativeSourceDiagnosticDetailView(model: model, record: record)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text(record.operation.rawValue); Spacer(); Text(record.code).font(.caption.monospaced()) }
                        Text("耗时 \(record.elapsedMilliseconds) ms · 书源 \(record.sourceDigest.prefix(8))").font(.footnote)
                        Text(record.timestamp, style: .time).font(.caption).foregroundStyle(.secondary)
                        if let line = record.line { Text("源码位置：\(line):\(record.column ?? 1)").font(.caption) }
                    }.frame(minHeight: 44)
                }
            }
            if let feedback { Text(feedback).font(.footnote) }
        }
        .navigationTitle("书源诊断").navigationBarTitleDisplayMode(.inline)
        .task { records = await SourceDiagnostics.shared.records() }
        .refreshable { records = await SourceDiagnostics.shared.records() }
        .confirmationDialog("清除本次运行的诊断记录？", isPresented: $clearing, titleVisibility: .visible) {
            Button("清除", role: .destructive) { Task { await SourceDiagnostics.shared.clear(); records = [] } }
            Button("取消", role: .cancel) { }
        }
        .fileExporter(isPresented: $exporting, document: NativeSourceDiagnosticFile(data: data), contentType: .json, defaultFilename: "source-diagnostics.json") { result in
            if case .failure(let error) = result { feedback = error.localizedDescription }
        }
    }
}

private struct NativeSourceDiagnosticDetailView: View {
    @ObservedObject var model: NativeSourceLibrary
    let record: SourceDiagnosticRecord
    @State private var source: SourceInstallation?
    @State private var excerpt: SourceCodeExcerpt?
    @State private var loaded = false
    @State private var feedback: String?
    var body: some View {
        List {
            Section("操作记录") {
                LabeledContent("操作", value: record.operation.rawValue)
                LabeledContent("结果", value: record.code)
                LabeledContent("耗时", value: "\(record.elapsedMilliseconds) ms")
                Text(record.sourceDigest).font(.caption.monospaced()).textSelection(.enabled)
            }
            Section("对应源码") {
                if let source {
                    Text(source.name + " · " + source.version)
                    if let excerpt {
                        Text("第 \(excerpt.line) 行，第 \(excerpt.column) 列").font(.subheadline)
                        ForEach(excerpt.lines) { line in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("\(line.selected ? "→ " : "")\(line.number)").font(.caption.monospaced()).foregroundStyle(.secondary)
                                Text(line.text.isEmpty ? " " : line.text).font(.caption.monospaced()).textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                            .listRowBackground(line.selected ? Color.accentColor.opacity(0.1) : Color.clear)
                        }
                    } else if feedback == nil {
                        Text("此操作未提供可用源码位置。可在实验室检查完整文件。").font(.footnote).foregroundStyle(.secondary)
                    }
                    if let operation = SourceOperation(rawValue: record.operation.rawValue) {
                        NavigationLink("在实验室查看并重试") {
                            SourceProtocolLabView(initialSource: source.source, initialOperation: operation)
                        }.frame(minHeight: 44)
                        Text("实验室不会自动执行源码；需要手动检查、填写本次输入并运行。账号凭据和持久状态不会带入调试页。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                } else if loaded {
                    Text("此源码版本已不在当前安装或保留的历史中。请按摘要向作者提供原文件，避免使用新版行号定位。")
                        .font(.footnote).foregroundStyle(.secondary)
                } else { ProgressView("正在查找源码…") }
                if let feedback { Text(feedback).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("诊断详情").navigationBarTitleDisplayMode(.inline)
        .task {
            defer { loaded = true }
            do {
                source = try await model.services().0.sourceSnapshot(digest: record.sourceDigest)
                if let source, let line = record.line {
                    excerpt = try SourceCodeExcerpt(source: source.source, expectedDigest: record.sourceDigest, line: line, column: record.column ?? 1)
                }
            } catch { feedback = error.localizedDescription }
        }
    }
}
