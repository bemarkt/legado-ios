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
                VStack(alignment: .leading, spacing: 4) {
                    HStack { Text(record.operation.rawValue); Spacer(); Text(record.code).font(.caption.monospaced()) }
                    Text("耗时 \(record.elapsedMilliseconds) ms · 书源 \(record.sourceDigest.prefix(8))").font(.footnote)
                    Text(record.timestamp, style: .time).font(.caption).foregroundStyle(.secondary)
                    if let line = record.line { Text("源码位置：\(line):\(record.column ?? 1)").font(.caption) }
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
