import SwiftUI
import UniformTypeIdentifiers

struct NativeSourceLibraryView: View {
    @StateObject private var model: NativeSourceLibrary
    private let allowsMigration: Bool
    init(model: NativeSourceLibrary = .init(), allowsMigration: Bool = true) {
        _model = StateObject(wrappedValue: model); self.allowsMigration = allowsMigration
    }
    @State private var query = ""
    @State private var importing = false
    @State private var adding: String?
    @FocusState private var searchFocused: Bool
    @State private var submittedQuery = ""

    var body: some View {
        List {
            Section {
                Text("单文件 JS 和 Legado JSON 书源的阅读预览。可下载章节并离线继续阅读。")
                    .font(.footnote).foregroundStyle(.secondary)
                if allowsMigration {
                    NavigationLink { LegacyMigrationView(library: model) } label: { Label("从旧书架导入", systemImage: "square.and.arrow.down") }.frame(minHeight: 44)
                } else {
                    Text("这是独立副本。这里的编辑和进度不会写回迁移草稿或原书架。").font(.footnote).foregroundStyle(.secondary)
                }
                Button { importing = true } label: { Label("添加书源", systemImage: "plus.circle") }
                NavigationLink { NativeSourceDiagnosticsView(model: model) } label: { Label("书源诊断", systemImage: "list.bullet.rectangle") }.frame(minHeight: 44)
                NavigationLink { NativeSourceStorageView(model: model) } label: {
                    Label("缓存与下载", systemImage: "internaldrive")
                }.frame(minHeight: 44)
            }
            Section("已安装书源") {
                if model.installations.isEmpty { Text("添加 .source.js 或 Legado JSON，也可以使用离线示例开始。 ").foregroundStyle(.secondary) }
                ForEach(model.installations) { installation in
                    NavigationLink {
                        NativeSourceSettingsView(model: model, initialInstallation: installation)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(installation.name)
                            Text(installation.version).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if !submittedQuery.isEmpty {
                Section("搜索结果") {
                    if model.searching { HStack { ProgressView(); Text("正在搜索…"); Spacer(); Button("取消") { model.cancelSearch() } } }
                    ForEach(model.results) { hit in
                        HStack {
                            NativeSourceCoverView(model: model, installation: hit.installation, scope: hit.identity.scope, cover: hit.book.cover, expectedIdentity: hit.identity)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(hit.book.title)
                                Text([hit.book.author, hit.installation.name].compactMap { $0 }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                adding = hit.id
                                Task {
                                    defer { adding = nil }
                                    do { try await model.add(hit) } catch { model.message = error.localizedDescription }
                                }
                            } label: {
                                if adding == hit.id { ProgressView() } else { Image(systemName: "books.vertical.badge.plus") }
                            }
                            .frame(minWidth: 44, minHeight: 44)
                            .disabled(adding != nil)
                            .accessibilityLabel("将\(hit.book.title)加入书架")
                        }
                    }
                    if !model.searching && model.results.isEmpty && model.searchFailures.isEmpty {
                        Text(model.canLoadMore ? "本页暂无结果，可以继续加载。" : "没有搜索结果").foregroundStyle(.secondary)
                    }
                    if model.canLoadMore {
                        Button(model.searchFailures.isEmpty ? "加载更多" : "继续加载 / 重试失败书源") { model.loadMore() }
                            .frame(minHeight: 44)
                    }
                    ForEach(model.searchFailures) { failure in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(failure.installation.name).font(.subheadline.bold())
                            NativeSourceIssueView(model: model, installation: failure.installation, issue: failure.issue, retry: { model.loadMore() })
                        }
                    }
                }
            }
            Section("书架") {
                if model.shelf.isEmpty { Text("搜索后加入书架，目录和阅读进度会保存在本机。 ").foregroundStyle(.secondary) }
                ForEach(model.shelf) { item in
                    NavigationLink {
                        NativeSourceBookView(model: model, item: item, initiallyOffline: !allowsMigration)
                    } label: {
                        HStack(spacing: 12) {
                            NativeSourceCoverView(model: model, installation: item.installation, scope: item.book.key.scope, cover: item.book.details.cover)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.book.details.title)
                                Text(item.installation.name).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("原生书源阅读")
        .searchable(text: $query, prompt: "搜索已安装书源")
        .searchFocused($searchFocused)
        .scrollDismissesKeyboard(.interactively)
        .onSubmit(of: .search) {
            searchFocused = false
            submittedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            model.search(submittedQuery)
        }
        .onChange(of: query) { model.cancelSearch(clearResults: true); submittedQuery = "" }
        .task { await model.reload() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            Task { await model.releaseCatalogMemory() }
        }
        .onDisappear { model.cancelSearch() }
        .sheet(isPresented: $importing) { NativeSourceImportView(model: model) }
        .alert("提示", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("好", role: .cancel) { model.message = nil }
        } message: { Text(model.message ?? "") }
    }
}

private struct NativeSourceImportView: View {
    @ObservedObject var model: NativeSourceLibrary
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var candidates: [NativeSourceCandidate] = []
    @State private var selected = Set<Int>()
    @State private var additionalOrigins = ""
    @State private var selecting = false
    @State private var busy = false
    @State private var error: String?
    @State private var sourceURL = ""
    @State private var downloadedText: String?
    @State private var downloadedURL: String?
    @State private var confirmingDiscard = false
    @State private var inspectionTask: Task<Void, Never>?
    @FocusState private var editing: Bool
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("HTTPS 原始文件地址（可选）", text: $sourceURL)
                        .keyboardType(.URL).textContentType(.URL).autocorrectionDisabled().textInputAutocapitalization(.never)
                    Button("下载文件") {
                        editing = false; busy = true
                        inspectionTask = Task {
                            defer { busy = false }
                            do {
                                let result = try await model.downloadSource(sourceURL)
                                try Task.checkCancellation()
                                text = result.source; downloadedText = result.source; downloadedURL = result.url
                            } catch is CancellationError { }
                            catch { self.error = error.localizedDescription }
                        }
                    }.disabled(sourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("打开 JS / JSON 文件") { selecting = true }
                    Button("使用离线示例") {
                        do { text = try SourceAssets.script("OfflineExample.source") } catch { self.error = error.localizedDescription }
                    }
                    TextEditor(text: $text).font(.caption.monospaced()).frame(minHeight: 180)
                        .autocorrectionDisabled().textInputAutocapitalization(.never).accessibilityLabel("书源源码")
                        .focused($editing)
                    if text.first(where: { !$0.isWhitespace }) == "{" || text.first(where: { !$0.isWhitespace }) == "[" {
                        TextField("其他访问网站（每行一个完整 origin）", text: $additionalOrigins, axis: .vertical)
                            .keyboardType(.URL).autocorrectionDisabled().textInputAutocapitalization(.never).focused($editing)
                        Text("Legado 的动态脚本无法静态确定所有请求网站。需要其他网站时，在此填写并审阅；未允许的网站请求会被拒绝。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Button("检查书源") {
                        editing = false; busy = true
                        let candidate = text
                        inspectionTask = Task {
                            defer { busy = false }
                            do {
                                let inspected = try await model.inspectCandidates(candidate, additionalOrigins: additionalOrigins)
                                try Task.checkCancellation()
                                if text == candidate { candidates = inspected; selected = Set(inspected.indices); error = nil }
                            } catch is CancellationError { }
                            catch { self.error = error.localizedDescription }
                        }
                    }.disabled(text.isEmpty)
                } footer: { Text("检查时不会运行源代码。每次添加保存为独立安装，不会覆盖同名书源。") }
                if !candidates.isEmpty {
                    Section("待添加书源") {
                        ForEach(candidates.indices, id: \.self) { index in
                            let candidate = candidates[index]
                            VStack(alignment: .leading, spacing: 8) {
                                Toggle(candidate.metadata.name, isOn: Binding(get: { selected.contains(index) }, set: {
                                    if $0 { selected.insert(index) } else { selected.remove(index) }
                                })).frame(minHeight: 44)
                                Text(candidate.formatName + " · " + candidate.metadata.version).font(.caption).foregroundStyle(.secondary)
                                ForEach(candidate.metadata.origins, id: \.self) { Text($0).font(.footnote).textSelection(.enabled) }
                            }
                        }
                        Button("保存所选书源并允许以上网站访问") {
                            busy = true
                            Task {
                                defer { busy = false }
                                do {
                                    try await model.install(candidates.enumerated().filter { selected.contains($0.offset) }.map(\.element),
                                                            originURL: text == downloadedText ? downloadedURL : nil)
                                    dismiss()
                                } catch { self.error = error.localizedDescription }
                            }
                        }.frame(minHeight: 44).disabled(selected.isEmpty)
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red).textSelection(.enabled) } }
            }
            .disabled(busy)
            .scrollDismissesKeyboard(.interactively)
            .overlay { if busy { ProgressView().padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
            .navigationTitle("添加书源").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        if text.isEmpty { dismiss() } else { confirmingDiscard = true }
                    }.disabled(busy)
                }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("收起键盘") { editing = false } }
            }
            .interactiveDismissDisabled(busy || !text.isEmpty)
            .confirmationDialog("放弃尚未保存的书源？", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                Button("放弃更改", role: .destructive) { inspectionTask?.cancel(); dismiss() }
                Button("继续编辑", role: .cancel) { }
            }
            .onDisappear { inspectionTask?.cancel() }
            .onChange(of: text) { candidates = []; selected = []; error = nil }
            .onChange(of: additionalOrigins) { candidates = []; selected = []; error = nil }
            .fileImporter(isPresented: $selecting, allowedContentTypes: [.javaScript, .json, .plainText, .data]) { result in
                do {
                    let url = try result.get(), scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { try? handle.close() }
                    let data = try handle.read(upToCount: 2_097_153) ?? Data()
                    guard data.count <= 2_097_152, let value = String(data: data, encoding: .utf8) else {
                        throw SourceFailure(code: "INVALID_INPUT", message: "书源必须是 UTF-8 文本且不超过 2 MiB")
                    }
                    text = value
                } catch { self.error = error.localizedDescription }
            }
        }
    }
}

struct NativeSourceSettingsView: View {
    @ObservedObject var model: NativeSourceLibrary
    let initialInstallation: SourceInstallation
    private var installation: SourceInstallation { model.installations.first { $0.id == initialInstallation.id } ?? initialInstallation }
    @State private var editing = false
    @State private var editingText = ""
    @State private var history: [SourceInstallation] = []
    @State private var snapshot: SourceSnapshot?
    @State private var configurationScope: SourceScope?
    private var accountID: String { model.activeAccounts[installation.id]?.id ?? "guest" }
    @State private var values: [String: SourceJSON] = [:]
    @State private var feedback: String?
    @State private var busy = false
    var body: some View {
        Form {
            Section("书源") {
                LabeledContent("名称", value: installation.name)
                LabeledContent("版本", value: installation.version)
                LabeledContent("格式", value: installation.format == .legado ? "Legado JSON" : "单文件 JS")
                ForEach(installation.origins, id: \.self) { Text($0).font(.footnote) }
            }
            Section("账号") {
                NavigationLink { NativeSourceAccountsView(model: model, initialInstallation: installation) } label: {
                    LabeledContent("账号与登录", value: model.activeAccounts[installation.id]?.name ?? "访客")
                }.frame(minHeight: 44)
            }
            Section("源代码") {
                Button("查看或修改源码") { editingText = installation.source; editing = true }
                if installation.originURL != nil {
                    Button("检查原始地址的更新") { editingText = installation.source; editing = true }
                }
                ForEach(Array(history.enumerated()), id: \.offset) { _, previous in
                    Button("审阅历史版本 \(previous.version) · \(previous.digest.prefix(8))") {
                        editingText = previous.source; editing = true
                    }
                }
            }
            if let settings = snapshot?.inspection.metadata.settings, !settings.isEmpty {
                Section("选项") {
                    ForEach(settings.keys.sorted(), id: \.self) { key in
                        if let setting = settings[key] { settingRow(key, setting: setting) }
                    }
                    Button("保存选项") {
                        busy = true
                        Task {
                            defer { busy = false }
                            do {
                                guard let configurationScope else { throw SourceDomainError(.stale, "请等待账号选项载入。") }
                                try await model.saveConfiguration(.object(values), installation: installation, scope: configurationScope)
                                feedback = "选项已保存"
                            }
                            catch { feedback = error.localizedDescription }
                        }
                    }.frame(minHeight: 44).disabled(busy || configurationScope?.accountID != accountID)
                }.disabled(busy || configurationScope?.accountID != accountID)
            }
            if let feedback { Section { Text(feedback).font(.footnote) } }
        }
        .navigationTitle("书源设置").navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .sheet(isPresented: $editing) {
            NativeSourceEditorView(model: model, installation: installation, initialText: editingText)
        }
        .task(id: installation.digest + ":" + accountID) {
            configurationScope = nil; snapshot = nil; values = [:]; feedback = nil
            do {
                let source = installation
                let scope = try await model.selectedScope(source)
                let history = try await model.services().0.installationHistory(source.id)
                if source.format == .legado {
                    self.history = history; configurationScope = scope
                    return
                }
                let snapshot = try await model.inspect(source.source)
                let stored = try await model.services().0.configuration(scope: scope)
                let effective = try snapshot.configuration(overrides: stored)
                try Task.checkCancellation()
                guard try await model.selectedScope(source) == scope else { return }
                try Task.checkCancellation()
                if case .object(let values) = effective { self.values = values }
                self.history = history; self.snapshot = snapshot; configurationScope = scope
            } catch is CancellationError { }
            catch { if !Task.isCancelled { feedback = error.localizedDescription } }
        }
    }
    @ViewBuilder private func settingRow(_ key: String, setting: SourceInspection.Metadata.Setting) -> some View {
        switch setting.type {
        case "boolean":
            Toggle(setting.label, isOn: Binding(get: { if case .some(.bool(let value)) = values[key] { return value }; return false }, set: { values[key] = .bool($0) }))
        case "enum":
            Picker(setting.label, selection: Binding(get: { if case .some(.string(let value)) = values[key] { return value }; return "" }, set: { values[key] = .string($0) })) {
                ForEach(setting.options ?? [], id: \.value) { Text($0.label).tag($0.value) }
            }
        case "number":
            TextField(setting.label, value: Binding(get: { if case .some(.number(let value)) = values[key] { return value }; return 0 }, set: { values[key] = .number($0) }), format: .number)
                .keyboardType(.numbersAndPunctuation)
        default:
            TextField(setting.label, text: Binding(get: { if case .some(.string(let value)) = values[key] { return value }; return "" }, set: { values[key] = .string($0) }))
        }
    }
}

private struct NativeSourceFile: FileDocument {
    static var readableContentTypes: [UTType] { [.javaScript, .json, .plainText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        self.text = text
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: Data(text.utf8)) }
}

private struct NativeSourceEditorView: View {
    @ObservedObject var model: NativeSourceLibrary
    let installation: SourceInstallation
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var reviewed: NativeSourceCandidate?
    @State private var additionalOrigins: String
    @State private var resetConfiguration = false
    @State private var acceptsStateCompatibility = false
    @State private var exporting = false
    @State private var discarding = false
    @State private var replacingDraft = false
    @State private var busy = false
    @State private var error: String?
    @State private var downloadedText: String?
    @State private var downloadedURL: String?
    @FocusState private var editing: Bool
    init(model: NativeSourceLibrary, installation: SourceInstallation, initialText: String) {
        self.model = model; self.installation = installation; _text = State(initialValue: initialText)
        _additionalOrigins = State(initialValue: installation.format == .legado ? installation.origins.joined(separator: "\n") : "")
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $text).font(.caption.monospaced()).frame(minHeight: 240)
                        .autocorrectionDisabled().textInputAutocapitalization(.never).focused($editing)
                        .accessibilityLabel("书源源码")
                    Button(installation.format == .legado ? "导出 JSON" : "导出 .source.js") { editing = false; exporting = true }
                    if let address = installation.originURL {
                        Button("从原始地址获取候选更新") {
                            if text != installation.source { replacingDraft = true }
                            else { fetchUpdate() }
                        }
                        Text(address).font(.footnote).textSelection(.enabled)
                    }
                    if installation.format == .legado {
                        TextField("允许访问的其他网站（每行一个完整 origin）", text: $additionalOrigins, axis: .vertical)
                            .keyboardType(.URL).autocorrectionDisabled().textInputAutocapitalization(.never).focused($editing)
                    }
                    Button("检查并审阅更改") {
                        editing = false; busy = true
                        Task {
                            defer { busy = false }
                            do {
                                let candidates = try await model.inspectCandidates(text, additionalOrigins: additionalOrigins, expectedFormat: installation.format)
                                guard candidates.count == 1 else { throw SourceDomainError(.invalidInput, "编辑单个安装时请使用一个 JSON 书源对象。") }
                                reviewed = candidates[0]; error = nil
                            }
                            catch { self.error = error.localizedDescription }
                        }
                    }.disabled(text.isEmpty)
                } footer: {
                    Text("导出只包含编辑器中的源码。下载和检查不会运行书源；保存前需审阅访问范围。")
                }
                if let reviewed {
                    Section("候选版本") {
                        LabeledContent("名称", value: reviewed.metadata.name)
                        LabeledContent("版本", value: installation.version + " → " + reviewed.metadata.version)
                        Text("摘要：" + reviewed.sha256).font(.caption.monospaced()).textSelection(.enabled)
                        ForEach(reviewed.metadata.origins, id: \.self) { origin in
                            Label(origin, systemImage: installation.origins.contains(origin) ? "globe" : "plus.circle")
                                .font(.footnote)
                        }
                        ForEach(installation.origins.filter { !reviewed.metadata.origins.contains($0) }, id: \.self) { origin in
                            Label("移除：" + origin, systemImage: "minus.circle").font(.footnote)
                        }
                        DisclosureGroup("对照当前安装的源码") {
                            TextEditor(text: .constant(installation.source)).font(.caption.monospaced()).frame(minHeight: 220)
                                .accessibilityLabel("当前安装的源码，仅供对照")
                        }
                        if reviewed.metadata.id != installation.publisherID {
                            Text("标识不同，请另存为新书源，避免改变已有书籍的身份。")
                        } else {
                            if installation.format == .nativeModule { Toggle("将所有账号的书源选项重置为默认值", isOn: $resetConfiguration) }
                            Toggle("已确认此源码兼容已有书源状态", isOn: $acceptsStateCompatibility)
                            Text("回滚只恢复源码，不恢复书源状态。无法确认状态兼容时，请另存为新书源。")
                                .font(.footnote).foregroundStyle(.secondary)
                            if installation.locallyModified == true {
                                Text("此安装包含本地修改。替换会保存当前源码到历史版本。")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            Button("保存并允许候选版本的网站访问") {
                                busy = true
                                Task {
                                    defer { busy = false }
                                    do {
                                        try await model.replace(installation, with: reviewed, resetConfiguration: resetConfiguration,
                                            originURL: downloadedURL ?? installation.originURL, locallyModified: text != downloadedText)
                                        dismiss()
                                    } catch { self.error = error.localizedDescription }
                                }
                            }.disabled(!acceptsStateCompatibility || (reviewed.sha256 == installation.digest && reviewed.metadata.origins.sorted() == installation.origins.sorted()))
                        }
                        Button("另存为独立书源") {
                            busy = true
                            Task {
                                defer { busy = false }
                                do { try await model.install(reviewed, originURL: text == downloadedText ? downloadedURL : nil); dismiss() }
                                catch { self.error = error.localizedDescription }
                            }
                        }
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red).textSelection(.enabled) } }
            }
            .disabled(busy)
            .scrollDismissesKeyboard(.interactively)
            .overlay { if busy { ProgressView().padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) } }
            .navigationTitle("书源源码").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { if text == installation.source { dismiss() } else { discarding = true } }.disabled(busy)
                }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("收起键盘") { editing = false } }
            }
            .interactiveDismissDisabled(busy || text != installation.source)
            .confirmationDialog("放弃尚未保存的更改？", isPresented: $discarding, titleVisibility: .visible) {
                Button("放弃更改", role: .destructive) { dismiss() }
                Button("继续编辑", role: .cancel) { }
            }
            .confirmationDialog("用下载内容替换编辑器里的草稿？", isPresented: $replacingDraft, titleVisibility: .visible) {
                Button("获取候选更新", role: .destructive) { fetchUpdate() }
                Button("保留草稿", role: .cancel) { }
            } message: { Text("当前安装的版本会保留；尚未保存或导出的草稿会被替换。") }
            .onChange(of: text) { reviewed = nil; acceptsStateCompatibility = false; error = nil }
            .onChange(of: additionalOrigins) { reviewed = nil; acceptsStateCompatibility = false; error = nil }
            .fileExporter(isPresented: $exporting, document: NativeSourceFile(text: text), contentType: installation.format == .legado ? .json : .javaScript,
                          defaultFilename: installation.publisherID + (installation.format == .legado ? ".json" : ".source.js")) { result in
                if case .failure(let failure) = result { error = failure.localizedDescription }
            }
        }
    }
    private func fetchUpdate() {
        guard let address = installation.originURL else { return }
        editing = false; busy = true
        Task {
            defer { busy = false }
            do {
                let result = try await model.downloadSource(address)
                text = result.source; downloadedText = result.source; downloadedURL = result.url
            } catch { self.error = error.localizedDescription }
        }
    }

}

private struct NativeSourceStorageView: View {
    @ObservedObject var model: NativeSourceLibrary
    @State private var usage: SourceChapterStorageUsage?
    @State private var coverUsage: SourceCoverStorageUsage?
    @State private var clearingCovers = false
    @State private var cacheMiB = 128
    @State private var offlineMiB = 1024
    @State private var busy = false
    @State private var feedback: String?
    @State private var clearing: SourceChapterStorageRemoval?
    private let mib = 1024 * 1024

    var body: some View {
        Form {
            Section {
                if let usage {
                    LabeledContent("阅读缓存", value: "\(usage.readingCacheCount) 章 · \(size(usage.readingCacheBytes))")
                    LabeledContent("离线下载", value: "\(usage.offlineCount) 章 · \(size(usage.offlineBytes))")
                } else { ProgressView("正在统计…") }
            } footer: {
                Text("阅读缓存会自动回收较久未使用的章节。主动下载和升级前已有的正文会保留，需手动移除。统计为正文记录的存储量。")
            }
            Section {
                if let coverUsage { LabeledContent("封面缓存", value: "\(coverUsage.count) 张 · \(size(coverUsage.bytes))") }
                Button("清理封面缓存", role: .destructive) { clearingCovers = true }
                    .frame(minHeight: 44).disabled(busy || coverUsage?.count == 0 || coverUsage == nil)
            } footer: { Text("缩略图最多保留 128 张或 32 MiB；超过上限会回收较久未查看的封面。") }
            Section("容量上限") {
                Picker("阅读缓存", selection: $cacheMiB) {
                    ForEach(Array(Set([64,128,256,512,cacheMiB])).sorted(), id: \.self) { Text(size($0 * mib)).tag($0) }
                }
                Picker("离线下载", selection: $offlineMiB) {
                    ForEach(Array(Set([256,512,1024,2048,4096,offlineMiB])).sorted(), id: \.self) { Text(size($0 * mib)).tag($0) }
                }
                Button("保存上限") { saveLimits() }.frame(minHeight: 44)
            }.disabled(busy || usage == nil)
            Section {
                Button("清理阅读缓存", role: .destructive) { clearing = .readingCache }
                    .frame(minHeight: 44).disabled(busy || usage?.readingCacheCount == 0 || usage == nil)
                Button("移除全部离线下载", role: .destructive) { clearing = .offlineDownloads }
                    .frame(minHeight: 44).disabled(busy || usage?.offlineCount == 0 || usage == nil)
            } footer: {
                Text("书架、目录和阅读位置会保留。移除的正文需要重新联网获取。")
            }
            if busy { Section { ProgressView("正在处理…") } }
            if let feedback { Section { Text(feedback).font(.footnote) } }
        }
        .navigationTitle("缓存与下载").navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .refreshable { await reload() }
        .confirmationDialog("清理所有账号的封面缓存？", isPresented: $clearingCovers, titleVisibility: .visible) {
            Button("清理封面", role: .destructive) {
                busy = true
                Task {
                    defer { busy = false }
                    do {
                        let count = try await model.services().0.clearCoverCache()
                        await reload(); feedback = "已清理 \(count) 张封面。"
                    } catch { feedback = error.localizedDescription }
                }
            }
            Button("取消", role: .cancel) { }
        } message: { Text("下次查看时会重新下载封面，书架和正文保留。") }
        .confirmationDialog(clearing == .offlineDownloads ? "移除全部离线下载？" : "清理阅读缓存？",
                            isPresented: Binding(get: { clearing != nil }, set: { if !$0 { clearing = nil } }), titleVisibility: .visible) {
            if let selection = clearing {
                Button(selection == .offlineDownloads ? "移除离线下载" : "清理缓存", role: .destructive) { remove(selection) }
            }
            Button("取消", role: .cancel) { clearing = nil }
        } message: {
            Text(clearing == .offlineDownloads ? "所有书源的离线下载和升级前保留的正文都会移除；书架与阅读位置保留。" : "只移除自动缓存的正文，主动下载和升级前保留的正文不受影响。")
        }
    }
    private func size(_ bytes: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary) }
    @MainActor private func reload() async {
        do {
            let value = try await model.services().0.chapterStorageUsage()
            usage = value
            coverUsage = try await model.services().0.coverStorageUsage()
            cacheMiB = max(1, value.limits.readingCacheBytes / mib)
            offlineMiB = max(1, value.limits.offlineBytes / mib)
        } catch { feedback = error.localizedDescription }
    }
    private func saveLimits() {
        busy = true; feedback = nil
        Task {
            defer { busy = false }
            do {
                try await model.services().0.setChapterStorageLimits(.init(readingCacheBytes: cacheMiB * mib, offlineBytes: offlineMiB * mib))
                await reload(); feedback = "容量上限已保存。"
            } catch { feedback = error.localizedDescription }
        }
    }
    private func remove(_ selection: SourceChapterStorageRemoval) {
        clearing = nil; busy = true; feedback = nil
        Task {
            defer { busy = false }
            do {
                let count = try await model.services().0.removeChapterStorage(selection)
                await reload(); feedback = "已移除 \(count) 章正文。"
            } catch { feedback = error.localizedDescription }
        }
    }
}
