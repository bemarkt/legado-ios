import SwiftUI
import UniformTypeIdentifiers

extension SourceIssue {
    init(error: Error) {
        if let failure = error as? SourceFailure { self.init(code: failure.code, retryAfterMs: failure.retryAfterMs) }
        else if let failure = error as? SourceDomainError { self.init(code: failure.code.rawValue) }
        else if let failure = error as? SourceHostHTTPFailure { self.init(code: failure.code.rawValue) }
        else if error is CancellationError { self.init(code: "CANCELLED") }
        else { self.init(compatibilityError: error) }
    }
}

@MainActor
final class NativeSourceIssuePresentation: ObservableObject {
    enum Destination: String, Identifiable { case response, settings, accounts; var id: String { rawValue } }
    @Published var destination: Destination?
}

struct NativeSourceIssueView: View {
    @ObservedObject var model: NativeSourceLibrary
    let installation: SourceInstallation
    let issue: SourceIssue
    var retry: (() -> Void)? = nil
    @StateObject private var presentation: NativeSourceIssuePresentation
    init(model: NativeSourceLibrary, installation: SourceInstallation, issue: SourceIssue, retry: (() -> Void)? = nil,
         presentation: NativeSourceIssuePresentation = .init()) {
        self.model = model; self.installation = installation; self.issue = issue; self.retry = retry
        _presentation = StateObject(wrappedValue: presentation)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(issue.title).font(.headline)
            Text(issue.message).font(.footnote).foregroundStyle(.secondary)
            Text(issue.code).font(.caption.monospaced()).foregroundStyle(.secondary)
            if issue.recovery == .login || issue.extraction != nil {
                Button("网站登录与验证") { presentation.destination = .accounts }.frame(minHeight: 44)
            }
            if let extraction = issue.extraction {
                Text(extraction.field.rawValue + (extraction.httpStatus.map { " · HTTP \($0)" } ?? "")).font(.caption.monospaced()).foregroundStyle(.secondary)
                if extraction.responseID != nil {
                    Button("查看失败响应") { presentation.destination = .response }
                        .accessibilityIdentifier("source.issue.response").frame(minHeight: 44)
                }
            }
            if let retry, issue.recovery == .retry || issue.code == "CANCELLED" || issue.extraction != nil {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Button(issue.canRetry(at: context.date) ? "重试" : "等待后重试") { retry() }
                        .disabled(!issue.canRetry(at: context.date)).frame(minHeight: 44)
                }
            }
            Button("书源设置") { presentation.destination = .settings }
                .accessibilityIdentifier("source.issue.settings").frame(minHeight: 44)
        }
        .buttonStyle(.borderless)
        // A Form row must not contain multiple NavigationLinks: SwiftUI can activate
        // both row destinations. One item drives exactly one presentation.
        .sheet(item: $presentation.destination) { target in
            NavigationStack {
                Group {
                    switch target {
                    case .response:
                        if let extraction = issue.extraction, let responseID = extraction.responseID {
                            NativeSourceResponseView(model: model, installation: installation, responseID: responseID, extraction: extraction)
                        }
                    case .settings: NativeSourceSettingsView(model: model, initialInstallation: installation)
                    case .accounts: NativeSourceAccountsView(model: model, initialInstallation: installation)
                    }
                }
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { presentation.destination = nil } } }
            }
        }
    }
}

/// Captured HTML is displayed as inert, selectable text, never loaded into a web view.
struct NativeSourceResponseView: View {
    @ObservedObject var model: NativeSourceLibrary
    let installation: SourceInstallation
    let responseID: UUID
    let extraction: SourceExtractionContext
    @State private var response: SourceLocalResponse?
    @State private var loaded = false
    @State private var login: NativeSourceLoginRequest?
    @State private var feedback: String?
    @State private var preparing = false
    var body: some View {
        List {
            Section("失败响应") {
                LabeledContent("提取规则", value: extraction.field.rawValue)
                if let status = extraction.httpStatus { LabeledContent("HTTP 状态", value: String(status)) }
                if let bytes = extraction.responseBytes { LabeledContent("响应字节数", value: String(bytes)) }
                if let response {
                    if let type = response.contentType { LabeledContent("Content-Type", value: type) }
                    if let address = response.finalURL { Text(address).font(.footnote.monospaced()).textSelection(.enabled) }
                    Button("打开此页面验证") {
                        preparing = true; feedback = nil
                        Task {
                            defer { preparing = false }
                            do { login = try await model.verificationRequest(installation, responseID: responseID) }
                            catch { feedback = error.localizedDescription }
                        }
                    }.frame(minHeight: 44).disabled(preparing || response.finalURL == nil)
                    Text("完成网页验证后点保存登录，再返回刷新目录或正文。此操作会重新访问页面，HTTP 202 本身不能说明是否缺少登录。")
                        .font(.footnote).foregroundStyle(.secondary)
                } else if loaded {
                    Text("响应未保留或已过期，请重新执行失败的操作后查看。旧版诊断报告仅包含状态和字节数。")
                        .font(.footnote).foregroundStyle(.secondary)
                } else { ProgressView("正在读取…") }
                if let feedback { Text(feedback).font(.footnote).foregroundStyle(.secondary) }
            }
            if let response {
                if !response.httpExchanges.isEmpty {
                    Section("本次请求的 Cookie") { SourceHTTPExchangeFactsView(exchanges: response.httpExchanges) }
                }
                Section {
                    Text(response.body.isEmpty ? "（空响应）" : response.body)
                        .font(.caption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if response.truncated { Text("内容已截断，仅保留前 64 KiB UTF-8 文本。原始响应大小见上方。") }
                } header: { Text("供规则解析的响应文本") } footer: {
                    Text("文本仅供查看，不执行其中的脚本。响应可能含账号或阅读信息；普通诊断导出不包含它。仅在本次运行保留最近 8 份失败响应，15 分钟后过期，清除诊断会一并删除。")
                }
            }
        }
        .navigationTitle("响应详情").navigationBarTitleDisplayMode(.inline)
        .privacySensitive()
        .task {
            response = await SourceDiagnostics.shared.localResponse(id: responseID, sourceDigest: installation.digest)
            loaded = true
        }
        .onDisappear { response = nil; loaded = false }
        .sheet(item: $login) { request in NativeSourceLoginView(model: model, request: request) }
    }
}

private struct SourceHTTPExchangeFactsView: View {
    let exchanges: [SourceHTTPExchangeSummary]
    var body: some View {
        ForEach(Array(exchanges.enumerated()), id: \.offset) { index, exchange in
            VStack(alignment: .leading, spacing: 6) {
                Text("请求 \(index + 1) · HTTP \(exchange.status)").font(.subheadline)
                LabeledContent("实际发送 Cookie", value: "\(exchange.sentCookieCount) 个")
                LabeledContent("解析响应 Cookie", value: "\(exchange.receivedCookieCount) 个（删除 \(exchange.deletedCookieCount) 个）")
                LabeledContent("返回 Set-Cookie", value: exchange.hasSetCookieHeader ? "是" : "否")
                Text("网站标识 \(exchange.originDigest.prefix(8)) · UA \(exchange.userAgentDigest.map { String($0.prefix(8)) } ?? "未设置")")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
        Text("发送数量取自实际请求；已带 Cookie 仍可能被网站要求重新验证。标识仅用于比较请求是否使用同一网站和 UA，不包含 Cookie 值。")
            .font(.footnote).foregroundStyle(.secondary)
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
                Text("最近 128 次书源操作的状态和耗时，仅在本次运行中保留。失败响应可在详情中于本机查看；导出报告不包含查询词、网站地址、凭据或正文。")
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
    @State private var editor: NativeSourceEditorRequest?
    var body: some View {
        List {
            Section("操作记录") {
                LabeledContent("操作", value: record.operation.rawValue)
                LabeledContent("结果", value: record.code)
                LabeledContent("耗时", value: "\(record.elapsedMilliseconds) ms")
                if let extraction = record.extraction {
                    LabeledContent("提取规则", value: extraction.field.rawValue)
                    if let status = extraction.httpStatus { LabeledContent("HTTP 状态", value: String(status)) }
                    if let bytes = extraction.responseBytes { LabeledContent("响应字节数", value: String(bytes)) }
                }
                Text(record.sourceDigest).font(.caption.monospaced()).textSelection(.enabled)
                if let enabled = record.cookieJarEnabled { LabeledContent("自动 Cookie", value: enabled ? "开启" : "关闭") }
                if let revision = record.credentialRevisionDigest {
                    LabeledContent("登录版本", value: String(revision.prefix(8)))
                }
            }
            if let exchanges = record.httpExchanges, !exchanges.isEmpty {
                Section("HTTP 请求记录") { SourceHTTPExchangeFactsView(exchanges: exchanges) }
            }
            Section("对应源码") {
                if let source {
                    Text(source.name + " · " + source.version)
                    if let extraction = record.extraction, let responseID = extraction.responseID {
                        NavigationLink("查看失败响应") {
                            NativeSourceResponseView(model: model, installation: source, responseID: responseID, extraction: extraction)
                        }.frame(minHeight: 44)
                    }
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
                        Text("此操作未提供可用源码位置。可查看对应版本的完整文件。").font(.footnote).foregroundStyle(.secondary)
                    }
                    Button("查看对应源码") {
                        editor = .init(installation: model.installations.first { $0.id == source.id } ?? source, text: source.source)
                    }.frame(minHeight: 44)
                    if source.format == .nativeModule, let operation = SourceOperation(rawValue: record.operation.rawValue) {
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
        .sheet(item: $editor) { request in
            NativeSourceEditorView(model: model, installation: request.installation, initialText: request.text).id(request.id)
        }
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
