import SwiftUI
import UniformTypeIdentifiers

struct NativeSourceLibraryView: View {
    @StateObject private var model = NativeSourceLibrary()
    @State private var query = ""
    @State private var importing = false
    @State private var adding: String?
    @FocusState private var searchFocused: Bool
    @State private var submittedQuery = ""

    var body: some View {
        List {
            Section {
                Text("自有 JS 书源的阅读预览。可保存书源、下载章节并离线继续阅读。")
                    .font(.footnote).foregroundStyle(.secondary)
                Button { importing = true } label: { Label("添加 JS 书源", systemImage: "plus.circle") }
            }
            Section("已安装书源") {
                if model.installations.isEmpty { Text("添加一个 .source.js 文件，或使用离线示例开始。 ").foregroundStyle(.secondary) }
                ForEach(model.installations) { installation in
                    NavigationLink {
                        NativeSourceSettingsView(model: model, installation: installation)
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
                    if !model.searching && model.results.isEmpty { Text("没有搜索结果").foregroundStyle(.secondary) }
                    ForEach(Array(model.searchFailures.enumerated()), id: \.offset) { _, error in Text(error).font(.footnote).foregroundStyle(.secondary) }
                }
            }
            Section("书架") {
                if model.shelf.isEmpty { Text("搜索后加入书架，目录和阅读进度会保存在本机。 ").foregroundStyle(.secondary) }
                ForEach(model.shelf) { item in
                    NavigationLink {
                        NativeSourceBookView(model: model, item: item)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.book.details.title)
                            Text(item.installation.name).font(.caption).foregroundStyle(.secondary)
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
    @State private var snapshot: SourceSnapshot?
    @State private var selecting = false
    @State private var busy = false
    @State private var error: String?
    @State private var confirmingDiscard = false
    @State private var inspectionTask: Task<Void, Never>?
    @FocusState private var editing: Bool
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button("打开 .source.js 文件") { selecting = true }
                    Button("使用离线示例") {
                        do { text = try SourceAssets.script("OfflineExample.source") } catch { self.error = error.localizedDescription }
                    }
                    TextEditor(text: $text).font(.caption.monospaced()).frame(minHeight: 180)
                        .autocorrectionDisabled().textInputAutocapitalization(.never).accessibilityLabel("书源源码")
                        .focused($editing)
                    Button("检查书源") {
                        editing = false; busy = true
                        let candidate = text
                        inspectionTask = Task {
                            defer { busy = false }
                            do {
                                let inspected = try await model.inspect(candidate)
                                try Task.checkCancellation()
                                if text == candidate { snapshot = inspected; error = nil }
                            } catch is CancellationError { }
                            catch { self.error = error.localizedDescription }
                        }
                    }.disabled(text.isEmpty)
                } footer: { Text("检查时不会运行源代码。每次添加保存为独立安装，不会覆盖同名书源。") }
                if let snapshot {
                    Section("书源信息") {
                        LabeledContent("名称", value: snapshot.inspection.metadata.name)
                        LabeledContent("版本", value: snapshot.inspection.metadata.version)
                        ForEach(snapshot.inspection.metadata.origins, id: \.self) { Text($0).font(.footnote) }
                        Button("保存并允许访问声明的网站") {
                            busy = true
                            Task {
                                defer { busy = false }
                                do { try await model.install(snapshot); dismiss() } catch { self.error = error.localizedDescription }
                            }
                        }
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
            .onChange(of: text) { snapshot = nil; error = nil }
            .fileImporter(isPresented: $selecting, allowedContentTypes: [.javaScript, .plainText, .data]) { result in
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

private struct NativeSourceSettingsView: View {
    @ObservedObject var model: NativeSourceLibrary
    let installation: SourceInstallation
    @State private var snapshot: SourceSnapshot?
    @State private var values: [String: SourceJSON] = [:]
    @State private var feedback: String?
    @State private var busy = false
    var body: some View {
        Form {
            Section("书源") {
                LabeledContent("名称", value: installation.name)
                LabeledContent("版本", value: installation.version)
                ForEach(installation.origins, id: \.self) { Text($0).font(.footnote) }
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
                            do { try await model.saveConfiguration(.object(values), installation: installation); feedback = "选项已保存" }
                            catch { feedback = error.localizedDescription }
                        }
                    }.disabled(busy)
                }.disabled(busy)
            }
            if let feedback { Section { Text(feedback).font(.footnote) } }
        }
        .navigationTitle("书源设置").navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .task {
            do {
                let snapshot = try await model.inspect(installation.source)
                let stored = try await model.services().0.configuration(scope: .init(installationID: installation.id))
                if case .object(let values) = try snapshot.configuration(overrides: stored) { self.values = values }
                self.snapshot = snapshot
            } catch { feedback = error.localizedDescription }
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
