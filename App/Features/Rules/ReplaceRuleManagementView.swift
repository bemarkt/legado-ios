import SwiftUI
import UniformTypeIdentifiers

struct ReplaceRuleManagementView: View {
    @EnvironmentObject private var library: ReplaceRuleLibraryModel
    @State private var showsImporter = false
    @State private var showsTextImporter = false
    @State private var showsQRImporter = false
    @State private var editingRule: ReplaceRule?
    @State private var startsWithTest = false
    @State private var query = ""
    @State private var group: String?

    private var filtered: [ReplaceRule] {
        library.rules.filter { rule in
            (group == nil || rule.group == group) && (query.isEmpty || rule.name.localizedCaseInsensitiveContains(query)
                || rule.pattern.localizedCaseInsensitiveContains(query) || (rule.group?.localizedCaseInsensitiveContains(query) ?? false))
        }
    }

    var body: some View {
        List {
            if library.rules.isEmpty {
                ReadingUnavailableView("还没有净化规则", systemImage: "wand.and.stars", description: Text("新建规则，或导入 Legado 净化规则。"))
                Button("新建规则", systemImage: "plus") { edit(library.newRule()) }
            } else {
                Section {
                    ReadingLabeledContent("已启用", value: "\(library.rules.filter(\.isEnabled).count) / \(library.rules.count)")
                    ReadingMenuPickerRow(
                        title: "分组",
                        selection: $group,
                        options: [ReadingMenuOption<String?>(nil, "全部")]
                            + Array(Set(library.rules.compactMap(\.group))).sorted().map {
                                ReadingMenuOption<String?>(Optional($0), $0)
                            },
                        identifier: "rules.group"
                    )
                }
                Section {
                    ForEach(filtered) { rule in
                        HStack(spacing: 12) {
                            Button { edit(rule) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: rule.isRegex ? "textformat.alt" : "character.cursor.ibeam")
                                        .foregroundStyle(rule.isEnabled ? ReadingTheme.accent : .secondary)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(rule.name.isEmpty ? rule.pattern : rule.name).foregroundStyle(.primary).lineLimit(1)
                                        Text(rule.group ?? (rule.scopeTitle && rule.scopeContent ? "标题与正文" : rule.scopeTitle ? "标题" : "正文"))
                                            .font(.caption).foregroundStyle(.secondary)
                                        Text(rule.pattern).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer()
                                }
                            }.buttonStyle(.plain)
                            Toggle("启用", isOn: Binding(get: { rule.isEnabled }, set: { value in Task { await library.setEnabled(value, for: rule.id) } }))
                                .labelsHidden().accessibilityLabel("启用\(rule.name)")
                        }
                        .contextMenu {
                            Button("编辑", systemImage: "pencil") { edit(rule) }
                            Button("测试", systemImage: "play") { edit(rule, test: true) }
                            Button("复制", systemImage: "doc.on.doc") { edit(library.newRule(copying: rule)) }
                            Button("删除", systemImage: "trash", role: .destructive) { Task { await library.remove(id: rule.id) } }
                        }
                    }
                    .onDelete { offsets in
                        let ids = offsets.compactMap { filtered.indices.contains($0) ? filtered[$0].id : nil }
                        Task { for id in ids { await library.remove(id: id) } }
                    }
                    .onMove { offsets, destination in Task { await library.move(from: offsets, to: destination) } }
                    .moveDisabled(group != nil || !query.isEmpty)
                } footer: { Text("点击规则编辑，长按可复制或测试。拖动排序决定执行顺序。").font(.footnote) }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("净化规则")
        .readingTabBarHidden()
        .searchable(text: $query, prompt: "名称、匹配内容或分组")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton().disabled(library.rules.isEmpty || group != nil || !query.isEmpty) }
            ToolbarItem(placement: .primaryAction) {
                Menu("更多", systemImage: "plus") {
                    Button("新建规则", systemImage: "plus") { edit(library.newRule()) }
                    Button("从文件导入", systemImage: "doc.badge.plus") { showsImporter = true }
                    Button("URL 或粘贴 JSON", systemImage: "link.badge.plus") { showsTextImporter = true }
                    Button("二维码导入", systemImage: "qrcode.viewfinder") { showsQRImporter = true }
                    ReadingShareLink(item: exportJSON) { Label("导出全部规则", systemImage: "square.and.arrow.up") }
                }
            }
        }
        .sheet(item: $editingRule) { ReplaceRuleEditorView(rule: $0, startsWithTest: startsWithTest).environmentObject(library) }
        .sheet(isPresented: $showsQRImporter) { QRCodeImportView { value in Task { await library.importText(value) } } }
        .sheet(isPresented: $showsTextImporter) { ReplaceRuleTextImportView().environmentObject(library) }
        .fileImporter(isPresented: $showsImporter, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): Task { await library.importFiles(urls) }
            case .failure(let error): library.notice = .init(kind: .error, title: "无法选择文件", detail: error.localizedDescription)
            }
        }
        .alert(item: $library.notice) { notice in
            Alert(title: Text(notice.title), message: Text(notice.detail), dismissButton: .default(Text("好")))
        }
    }
    private func edit(_ rule: ReplaceRule, test: Bool = false) { startsWithTest = test; editingRule = rule }
    private var exportJSON: String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(library.rules)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
    }
}

private struct ReplaceRuleTextImportView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: ReplaceRuleLibraryModel
    @State private var value = ""
    var body: some View {
        ReadingNavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("粘贴净化规则 JSON、HTTP(S) 链接或 Legado 净化规则深链。").font(.footnote).foregroundStyle(.secondary)
                SyntaxCodeEditor(text: $value, language: .json)
            }.padding()
            .navigationTitle("导入净化规则").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入") {
                        let text = value
                        dismiss()
                        Task {
                            try? await Task.sleep(nanoseconds: 400_000_000)
                            await library.importText(text)
                        }
                    }.disabled(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
