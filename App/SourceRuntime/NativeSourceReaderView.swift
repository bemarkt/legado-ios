import SwiftUI
import UIKit

struct NativeSourceBookView: View {
    @ObservedObject var model: NativeSourceLibrary
    let item: NativeSourceLibrary.ShelfBook
    @State private var catalog: SourceCatalog?
    @State private var selected: SourceWire.Chapter?
    @State private var offline = false
    @State private var busy = false
    @State private var task: Task<Void, Never>?
    @State private var message: String?
    @State private var resumeID: String?
    @State private var operationID = UUID()
    @State private var downloadProgress: SourceDownloadProgress?
    var body: some View {
        List {
            Section {
                HStack(alignment: .top, spacing: 14) {
                    NativeSourceCoverView(model: model, installation: item.installation, scope: item.book.key.scope, cover: item.book.details.cover, width: 70)
                    Text(item.book.details.title).font(.title2.bold())
                }
                if let author = item.book.details.author { Text(author).foregroundStyle(.secondary) }
                if let description = item.book.details.description, !description.isEmpty { Text(description).font(.footnote).lineLimit(6) }
                Toggle("仅使用离线章节", isOn: $offline)
            }
            Section {
                if let catalog, !catalog.chapters.isEmpty {
                    Button(resumeID == nil ? "开始阅读" : "继续阅读") {
                        selected = catalog.chapters.first(where: { $0.ref.id == resumeID }) ?? catalog.chapters.first
                    }
                    Button("下载全部章节") { start { try await download(catalog) } }.disabled(offline || busy)
                }
                Button("刷新目录") { start { try await refresh() } }.disabled(offline || busy)
                if let progress = downloadProgress {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: Double(progress.completed), total: Double(max(1, progress.total)))
                            .accessibilityLabel("章节下载进度")
                            .accessibilityValue("已保存 \(progress.completed) 章，共 \(progress.total) 章")
                        Text("已保存 \(progress.completed) / \(progress.total) 章").font(.footnote).monospacedDigit()
                        if busy, let chapter = progress.currentChapter { Text(chapter.title).font(.caption).foregroundStyle(.secondary) }
                    }
                }
                if busy {
                    HStack {
                        if downloadProgress == nil { ProgressView(); Text("处理中…") }
                        Spacer()
                        Button("取消") { task?.cancel() }.frame(minWidth: 44, minHeight: 44)
                    }
                }
                if let message { Text(message).font(.footnote).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            Section("目录 · \(catalog?.chapters.count ?? 0) 章") {
                if let catalog {
                    ForEach(catalog.chapters, id: \.ref.id) { chapter in
                        Button { selected = chapter } label: {
                            HStack {
                                Text(chapter.title).foregroundStyle(.primary)
                                Spacer()
                                if chapter.ref.id == resumeID { Image(systemName: "bookmark.fill").accessibilityLabel("上次阅读") }
                            }
                        }
                    }
                } else { Text("加载目录后即可阅读，已保存目录可离线打开。 ").foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("书籍详情").navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                let archive = try model.services().0
                await model.pendingPositionWrites()
                catalog = try await archive.catalog(book: item.book.key)
                try Task.checkCancellation()
                resumeID = try await archive.anchor(book: item.book.key)?.chapter.chapterID
                if catalog == nil { start { try await refresh() } }
            } catch { message = error.localizedDescription }
        }
        .navigationDestination(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } })) {
            if let selected, let catalog {
                NativeSourceReaderView(model: model, item: item, catalog: catalog, initialChapterID: selected.ref.id, offline: offline)
            }
        }
        .onDisappear { operationID = UUID(); task?.cancel(); task = nil; busy = false }
    }
    private func start(_ operation: @escaping @MainActor () async throws -> Void) {
        task?.cancel(); busy = true; message = nil; downloadProgress = nil
        let token = UUID(); operationID = token
        task = Task {
            defer { if operationID == token { busy = false; task = nil } }
            do { try await operation() }
            catch is CancellationError { if operationID == token { message = "已取消，已完成的章节仍保留。" } }
            catch { if operationID == token { message = error.localizedDescription } }
        }
    }
    private func refresh() async throws {
        let provider = try await model.provider(item.installation, scope: item.book.key.scope)
        let fresh = try await model.services().1.refreshCatalog(provider: provider, book: item.book.details.ref)
        try Task.checkCancellation()
        if let old = catalog {
            let changes = try fresh.changes(from: old)
            message = "新增 \(changes.inserted.count) · 移除 \(changes.removed.count) · 更新 \(changes.updated.count)" + (changes.reordered ? " · 顺序已调整" : "")
        }
        catalog = fresh
    }
    private func download(_ catalog: SourceCatalog) async throws {
        let provider = try await model.provider(item.installation, scope: item.book.key.scope)
        let token = operationID
        let count = try await model.services().1.download(provider: provider.prioritized(.background), catalog: catalog) { progress in
            await MainActor.run {
                if operationID == token { downloadProgress = progress }
            }
        }
        try Task.checkCancellation()
        message = "已保存 \(count) 章，可打开离线模式阅读。"
    }
}

struct NativeSourceReaderView: View {
    struct Passage: Identifiable {
        let id: Int
        let text: String
        let marks: [ChapterDocument.Mark]
        let headingLevel: Int?
    }
    @ObservedObject var model: NativeSourceLibrary
    let item: NativeSourceLibrary.ShelfBook
    let catalog: SourceCatalog
    let initialChapterID: String
    let offline: Bool
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var textScale = 1.0
    @State private var currentID = ""
    @State private var chapter: SourceCachedChapter?
    @State private var passages: [Passage] = []
    @State private var visibleID: Int?
    @State private var loading = false
    @State private var error: String?
    @State private var notice: String?
    @State private var requestedPolicy = SourceLibraryService.ReadPolicy.current
    @State private var loadTask: Task<Void, Never>?
    @State private var prefetch: Task<Void, Never>?
    @State private var generation = UUID()
    @State private var provider: WebKitSourceProvider?
    @AppStorage("native-source-font-size") private var fontSize = 20.0
    private var index: Int? { catalog.chapters.firstIndex { $0.ref.id == currentID } }
    private var title: String { catalog.chapters.first(where: { $0.ref.id == currentID })?.title ?? item.book.details.title }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    Text(title).font(.title2.bold()).padding(.bottom, 12)
                    if let notice { Text(notice).font(.footnote).foregroundStyle(.secondary) }
                    ForEach(passages) { passage in
                        Text(attributed(passage))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .lineSpacing(fontSize * textScale * 0.35)
                            .textSelection(.enabled)
                            .id(passage.id)
                    }
                    if let error {
                        ContentUnavailableView { Label("暂时无法读取", systemImage: "book.closed") }
                        description: { Text(error) }
                        actions: {
                            Button("重试") { load(currentID, policy: requestedPolicy) }
                            if !offline, requestedPolicy != .offline {
                                Button("阅读已下载副本") { load(currentID, policy: .offline) }
                            }
                        }
                    }
                }
                .scrollTargetLayout()
                .padding(.horizontal, 24).padding(.vertical, 28)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
            .scrollPosition(id: $visibleID, anchor: .top)
            .overlay { if loading { ProgressView("正在读取…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14)) } }
            .onChange(of: fontSize) { if let visibleID { proxy.scrollTo(visibleID, anchor: .top) } }
        }
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("增大字号", systemImage: "textformat.size.larger") { fontSize = min(36, fontSize + 2) }
                    Button("减小字号", systemImage: "textformat.size.smaller") { fontSize = max(14, fontSize - 2) }
                    Divider()
                    Button("刷新本章", systemImage: "arrow.clockwise") { load(currentID, policy: .reload) }
                        .disabled(offline || loading)
                } label: { Image(systemName: "textformat.size").accessibilityLabel("阅读设置") }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 12) {
                Button { move(-1) } label: {
                    if dynamicTypeSize.isAccessibilitySize { Image(systemName: "chevron.left") }
                    else { Text("上一章") }
                }.accessibilityLabel("上一章")
                    .frame(minWidth: 44, minHeight: 44).disabled(loading || (index ?? 0) == 0)
                Spacer()
                if loading { Button("取消") { loadTask?.cancel() }.frame(minWidth: 44, minHeight: 44) }
                else { Text("\((index ?? 0) + 1) / \(catalog.chapters.count)").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button { move(1) } label: {
                    if dynamicTypeSize.isAccessibilitySize { Image(systemName: "chevron.right") }
                    else { Text("下一章") }
                }.accessibilityLabel("下一章")
                    .frame(minWidth: 44, minHeight: 44).disabled(loading || (index ?? 0) >= catalog.chapters.count - 1)
            }.padding().background(.bar)
        }
        .task { load(initialChapterID) }
        .onChange(of: visibleID) { savePosition() }
        .onChange(of: scenePhase) {
            if scenePhase != .active { savePosition(); prefetch?.cancel() }
        }
        .onDisappear {
            savePosition(); generation = UUID(); loadTask?.cancel(); prefetch?.cancel()
        }
    }
    private func load(_ id: String, policy: SourceLibraryService.ReadPolicy? = nil) {
        let policy: SourceLibraryService.ReadPolicy = offline ? .offline : policy ?? .current
        guard let selected = catalog.chapters.first(where: { $0.ref.id == id }) else { return }
        savePosition(); loadTask?.cancel(); prefetch?.cancel()
        let token = UUID(); generation = token
        currentID = id; requestedPolicy = policy; loading = true; error = nil; notice = nil
        chapter = nil; passages = []; visibleID = nil
        loadTask = Task {
            defer { if generation == token { loading = false; loadTask = nil } }
            do {
                let provider: WebKitSourceProvider
                if let existing = self.provider { provider = existing }
                else { provider = try await model.provider(item.installation, scope: item.book.key.scope); self.provider = provider }
                let (archive, service) = try model.services()
                guard policy == .offline || catalog.identity == provider.descriptor.identity else {
                    throw SourceDomainError(.stale, "书源或选项已改变，请返回书籍详情刷新目录后再阅读。已下载内容仍可在离线模式打开。")
                }
                let content = try await service.chapter(provider: provider, book: catalog.book, chapter: selected.ref, policy: policy, catalog: catalog)
                try Task.checkCancellation()
                guard generation == token else { return }
                await model.pendingPositionWrites()
                let anchor = try await archive.anchor(book: item.book.key)
                try Task.checkCancellation()
                guard generation == token else { return }
                let pieces = makePassages(content.document)
                chapter = content; passages = pieces
                if let anchor, anchor.chapter == content.key {
                    let resolution = try anchor.resolve(chapter: content.key, document: content.document)
                    visibleID = pieces.last(where: { $0.id <= resolution.offsetUTF16 })?.id ?? pieces.first?.id
                    if resolution.method == .nearest { notice = "章节内容有变化，已恢复到最接近的阅读位置。" }
                } else { visibleID = pieces.first?.id }
                if policy == .offline {
                    notice = "正在阅读已下载的离线副本，未检查网站更新。" + (notice.map { " " + $0 } ?? "")
                }
                if policy != .offline, let index = catalog.chapters.firstIndex(where: { $0.ref.id == id }), index + 1 < catalog.chapters.count {
                    let next = catalog.chapters[index + 1]
                    prefetch = Task { _ = try? await service.chapter(provider: provider.prioritized(.background), book: catalog.book, chapter: next.ref, catalog: catalog) }
                }
            } catch is CancellationError { if generation == token { error = "读取已取消" } }
            catch { if generation == token { self.error = error.localizedDescription } }
        }
    }
    private func move(_ distance: Int) {
        guard let index, catalog.chapters.indices.contains(index + distance) else { return }
        load(catalog.chapters[index + distance].ref.id)
    }
    private func savePosition() {
        guard let chapter, let visibleID else { return }
        model.savePosition(SourceReadingAnchor(chapter: chapter.key, document: chapter.document, offsetUTF16: visibleID))
    }
    private func makePassages(_ document: ChapterDocument) -> [Passage] {
        var result: [Passage] = [], base = 0
        for block in document.blocks {
            let text = block.text as NSString
            var start = 0
            while start < text.length {
                var length = min(1200, text.length - start)
                let paragraph = text.range(of: "\n\n", range: NSRange(location: start, length: length))
                if paragraph.location != NSNotFound { length = paragraph.location + 2 - start }
                let range = text.rangeOfComposedCharacterSequences(for: NSRange(location: start, length: length))
                let end = NSMaxRange(range)
                let marks = block.marks.compactMap { mark -> ChapterDocument.Mark? in
                    let lower = max(start, mark.startUTF16), upper = min(end, mark.endUTF16)
                    guard lower < upper else { return nil }
                    return .init(kind: mark.kind, startUTF16: lower - start, endUTF16: upper - start)
                }
                result.append(Passage(id: base + start, text: text.substring(with: range), marks: marks, headingLevel: block.headingLevel))
                start = end
            }
            base += text.length + 2
        }
        return result
    }
    private func attributed(_ passage: Passage) -> AttributedString {
        let base = UIFont.systemFont(ofSize: (passage.headingLevel == nil ? fontSize : fontSize + 4) * textScale,
                                     weight: passage.headingLevel == nil ? .regular : .semibold)
        let output = NSMutableAttributedString(string: passage.text, attributes: [.font: base, .foregroundColor: UIColor.label])
        for mark in passage.marks {
            let range = NSRange(location: mark.startUTF16, length: mark.endUTF16 - mark.startUTF16)
            guard NSMaxRange(range) <= output.length else { continue }
            output.enumerateAttribute(.font, in: range) { value, subrange, _ in
                let current = value as? UIFont ?? base
                let trait: UIFontDescriptor.SymbolicTraits = mark.kind == .strong ? .traitBold : .traitItalic
                if let descriptor = current.fontDescriptor.withSymbolicTraits(current.fontDescriptor.symbolicTraits.union(trait)) {
                    output.addAttribute(.font, value: UIFont(descriptor: descriptor, size: current.pointSize), range: subrange)
                }
            }
        }
        return AttributedString(output)
    }
}
