import SwiftUI

@MainActor
final class LegacyMigrationModel: ObservableObject {
    @Published private(set) var report: LegacyMigrationReport?
    @Published private(set) var busy = false
    @Published private(set) var stage = "准备保留旧数据的副本。"
    @Published private(set) var failure: String?
    @Published private(set) var adopted = false
    @Published var previewURL: URL?
    private var operation: Task<Void, Never>?
    let directory: URL
    let legacyDatabase: URL
    var snapshot: URL { directory.appendingPathComponent("snapshot") }
    var mapping: URL { directory.appendingPathComponent("mapping") }
    init(directory: URL? = nil, legacyDatabase: URL = LegadoDatabase.defaultURL()) {
        self.legacyDatabase = legacyDatabase
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LegadoMigration/review-v1", isDirectory: true)
    }
    func restore(library: NativeSourceLibrary) {
        guard report == nil, !busy else { return }
        guard FileManager.default.fileExists(atPath: mapping.appendingPathComponent("report.json").path) else { return }
        perform {
            let mapping = self.mapping, snapshot = self.snapshot
            self.report = try await self.worker { try LegacyMigrationMapper.verify(at: mapping, snapshotAt: snapshot) }
            if let report = self.report { self.adopted = try await library.services().0.migrationReceipt(report.snapshotID) != nil }
            self.stage = "已恢复上次的迁移审阅。"
        }
    }
    func prepare() {
        perform {
            guard FileManager.default.fileExists(atPath: self.legacyDatabase.path) else { throw SourceDomainError(.unavailable, "尚未找到旧版书库。可以先在原书架导入一本书。") }
            let base = self.legacyDatabase.deletingLastPathComponent()
            let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Legado/Chapters")
            let directories = ["chapters": cache, "legacy-chapters": base.appendingPathComponent("Chapters"),
                               "local-books": base.appendingPathComponent("LocalBooks"), "fonts": FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("fonts"),
                               "legacy-fonts": base.appendingPathComponent("fonts")]
            let names = ["replace-rules": "replace-rules.json", "book-sources": "book-sources.json", "books": "books.json",
                         "book-groups": "book-groups.json", "bookmarks": "bookmarks.json", "read-records": "read-records.json",
                         "reader-background": "reader-background.jpg"]
            let files = names.mapValues { base.appendingPathComponent($0) }
            // Capture only this App's persistent domain, never global defaults or another application's settings.
            let settings = Bundle.main.bundleIdentifier.flatMap { UserDefaults.standard.persistentDomain(forName: $0) } ?? [:]
            let defaults = try PropertyListSerialization.data(fromPropertyList: settings, format: .binary, options: 0)
            let database = self.legacyDatabase, snapshot = self.snapshot, mapping = self.mapping
            self.stage = "正在复制旧书库、离线正文和本地文件…"
            _ = try await self.worker {
                if FileManager.default.fileExists(atPath: snapshot.appendingPathComponent("manifest.json").path) {
                    return try LegacyMigrationSnapshot.verify(at: snapshot)
                }
                return try LegacyMigrationSnapshot.capture(databaseURL: database, externalDirectories: directories,
                    externalFiles: files, defaults: defaults, destination: snapshot)
            }
            self.stage = "正在核对书籍、章节、阅读位置和笔记…"
            let report = try await self.worker { try await LegacyMigrationMapper.prepare(snapshotAt: snapshot, destination: mapping) }
            self.report = report
            self.stage = "副本已准备好，可以先离线预览，再导入阅读预览。"
        }
    }
    func preview() {
        perform {
            let mapping = self.mapping, snapshot = self.snapshot
            self.stage = "正在创建独立的阅读预览…"
            self.previewURL = try await self.worker { try LegacyMigrationMapper.makePreview(at: mapping, snapshotAt: snapshot) }
            self.stage = "预览使用独立副本。预览中的新进度不会写回迁移草稿。"
        }
    }
    func adopt(into library: NativeSourceLibrary) {
        perform {
            let archive = try library.services().0, mapping = self.mapping, snapshot = self.snapshot
            self.stage = "正在导入已核对的数据…"
            _ = try await self.worker { try await LegacyMigrationMapper.adopt(at: mapping, snapshotAt: snapshot, into: archive) }
            self.adopted = true
            await library.reload()
            self.stage = "已导入阅读预览。原书架及本地、RSS、语音和设置功能继续保留。"
        }
    }
    func cancel() { operation?.cancel() }
    private func worker<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let task = Task.detached(priority: .utility, operation: body)
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; failure = nil
        operation = Task {
            defer { busy = false; operation = nil }
            do { try await action() }
            catch is CancellationError { stage = "已取消，原数据仍保留。可以稍后重试。" }
            catch { failure = error.localizedDescription; stage = "迁移未完成，原数据仍保留。" }
        }
    }
}

struct LegacyMigrationView: View {
    @ObservedObject var library: NativeSourceLibrary
    @StateObject private var model: LegacyMigrationModel
    @State private var acknowledged = false
    @State private var confirmAdoption = false
    init(library: NativeSourceLibrary, model: LegacyMigrationModel = .init()) {
        self.library = library; _model = StateObject(wrappedValue: model)
    }
    var body: some View {
        List {
            Section {
                Text("从旧书架导入").font(.title2.bold())
                Text("先创建副本，再检查书籍、章节和笔记。导入后仍可从原入口打开旧书架、本地 TXT / EPUB、RSS、朗读与设置。")
                    .font(.subheadline).foregroundStyle(.secondary)
                Text("准备副本时请暂停下载、书架更新和正文编辑；检测到数据变化后会停止并保留原数据。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("当前进度") {
                if model.busy { ProgressView().accessibilityLabel("迁移处理中") }
                Text(model.stage).font(.subheadline)
                if let failure = model.failure { Text(failure).foregroundStyle(.red).font(.footnote).textSelection(.enabled) }
                if model.busy {
                    Button("取消当前操作") { model.cancel() }.frame(minHeight: 44)
                } else if model.report == nil {
                    Button(model.failure == nil ? "创建并核对副本" : "重试副本准备") { model.prepare() }.frame(minHeight: 44)
                }
            }
            if let report = model.report {
                Section("核对结果") {
                    LabeledContent("可导入书源", value: String(report.sources.count))
                    LabeledContent("可导入书籍", value: String(report.books.count))
                    LabeledContent("离线章节", value: String(report.cacheFilesMapped))
                    LabeledContent("已定位阅读进度", value: String(report.books.filter(\.progressMapped).count))
                    LabeledContent("待核对项目", value: String(report.reviewCount))
                    NavigationLink("查看全部数据及处理结果") { LegacyMigrationReportView(report: report) }.frame(minHeight: 44)
                    Button("先用副本预览阅读") { model.preview() }.disabled(model.busy).frame(minHeight: 44)
                }
                Section("书源访问范围") {
                    ForEach(report.sources) { source in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(source.installation.name).font(.headline)
                            Text(source.enabled ? "保留启用状态" : "保留停用状态 · 不参与搜索").font(.caption).foregroundStyle(.secondary)
                            ForEach(source.installation.origins, id: \.self) { origin in
                                Text(origin).font(.footnote.monospaced()).textSelection(.enabled)
                            }
                        }.padding(.vertical, 4)
                    }
                }
                Section {
                    if model.adopted {
                        Label("已导入阅读预览", systemImage: "checkmark.circle").foregroundStyle(.green)
                    } else {
                        Toggle("已查看访问范围与待处理项目", isOn: $acknowledged)
                        Button("导入阅读预览") { confirmAdoption = true }
                            .disabled(!acknowledged || model.busy).frame(minHeight: 44)
                    }
                } footer: {
                    Text("登录状态需在书源的“网站登录”中重新确认。无法定位的笔记和未支持的数据保留在本机副本；恢复旧副本不会包含导入之后新增的进度或笔记。")
                }
            }
        }
        .navigationTitle("旧数据迁移").navigationBarTitleDisplayMode(.inline)
        .task { model.restore(library: library) }
        .onDisappear { if model.busy { model.cancel() } }
        .confirmationDialog("将已核对的数据加入阅读预览？", isPresented: $confirmAdoption, titleVisibility: .visible) {
            Button("确认导入") { model.adopt(into: library) }
            Button("取消", role: .cancel) { }
        } message: { Text("将新增独立书源和书架条目。重复执行同一迁移不会重复导入。") }
        .sheet(isPresented: Binding(get: { model.previewURL != nil }, set: { if !$0 { model.previewURL = nil } })) {
            if let url = model.previewURL {
                NavigationStack {
                    NativeSourceLibraryView(model: NativeSourceLibrary(databaseURL: url, credentials: SourceCredentialVault(persistence: SourceEphemeralCredentials())), allowsMigration: false)
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭副本预览") { model.previewURL = nil }.frame(minHeight: 44) } }
                }
            }
        }
    }
}

private struct LegacyMigrationReportView: View {
    let report: LegacyMigrationReport
    var body: some View {
        List {
            Section("逐表数量") {
                ForEach(report.tables.keys.sorted(), id: \.self) { name in
                    if let table = report.tables[name] {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(name).font(.subheadline.monospaced())
                            Text("原记录 \(table.total) · 已映射 \(table.mapped) · 待处理 \(table.needsReview) · 原样保留 \(table.retained)")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("待处理") {
                if report.reviewCount == 0 { Text("没有发现需要手动处理的记录。") }
                ForEach(report.records.filter { $0.disposition == .needsReview }) { record in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(record.table) · 记录 \(record.rowID)").font(.subheadline)
                        Text(reason(record.reason)).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            Section("笔记原文") {
                ForEach(report.annotations) { note in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(note.bookmark.bookName).font(.headline)
                        Text(note.bookmark.chapterName).font(.subheadline).foregroundStyle(.secondary)
                        if !note.bookmark.bookText.isEmpty { Text(note.bookmark.bookText).font(.callout) }
                        if !note.bookmark.content.isEmpty { Text(note.bookmark.content).textSelection(.enabled) }
                        Text(note.anchor == nil ? "保留原文，位置待确认" : "已关联章节位置").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("迁移核对").navigationBarTitleDisplayMode(.inline)
    }
    private func reason(_ value: LegacyMigrationReport.Reason) -> String {
        switch value {
        case .imported: "已映射"
        case .localFeature: "由原有本地阅读功能保留"
        case .unsupportedSource: "书源格式或类型暂不支持，原始书源已保留"
        case .malformedRecord: "记录内容损坏或身份不一致，原记录已保留"
        case .missingSource: "未找到对应书源"
        case .invalidCatalog: "目录记录不完整或存在重复身份"
        case .missingCache: "缺少离线正文"
        case .ambiguousCache: "同一章节存在多个缓存版本，需确认"
        case .foreignCache: "缓存记录属于其他书源"
        case .supplementalContent: "补充正文暂不能转换，原内容已保留"
        case .positionChanged: "正文或原排版状态不足以确认阅读位置"
        case .ambiguousBookmark: "书签位置不能唯一确认，笔记原文已保留"
        case .reauthentication: "登录信息需要重新确认"
        case .preservedFeature: "由现有功能和恢复副本保留"
        case .capacity: "迁移容量不足"
        case .orphanedRecord: "未找到可确定的书籍或章节关联"
        }
    }
}
