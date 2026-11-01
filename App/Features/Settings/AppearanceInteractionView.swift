import SwiftUI

/// 底部标签的稳定标识。顺序与显隐状态都围绕它持久化，隐藏能力由 `isHideable` 收口。
enum AppTabItem: String, CaseIterable, Identifiable {
    case bookshelf, explore, statistics, my

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bookshelf: return "书架"
        case .explore: return "发现"
        case .statistics: return "统计"
        case .my: return "我的"
        }
    }

    var systemImage: String {
        switch self {
        case .bookshelf: return "book.fill"
        case .explore: return "safari"
        case .statistics: return "chart.bar"
        case .my: return "person.crop.circle"
        }
    }

    /// 书架与「我的」构成主导航骨架，不参与隐藏。
    var isHideable: Bool { self == .explore || self == .statistics }

    static var defaultOrder: [AppTabItem] { [.bookshelf, .explore, .statistics, .my] }
}

/// 底部导航配置的编解码层：顺序、显隐都存为可读字符串，便于回滚与迁移。
enum TabBarSettings {
    static let orderKey = "tabBarOrder"
    static let hiddenKey = "tabBarHidden"

    static var defaultOrderRaw: String { encodeOrder(AppTabItem.defaultOrder) }

    static func encodeOrder(_ order: [AppTabItem]) -> String {
        order.map(\.rawValue).joined(separator: ",")
    }

    static func decodeOrder(_ raw: String) -> [AppTabItem] {
        var seen = Set<AppTabItem>()
        var ordered: [AppTabItem] = []
        for piece in raw.split(separator: ",") {
            let name = piece.trimmingCharacters(in: .whitespaces)
            guard let item = AppTabItem(rawValue: name), seen.insert(item).inserted else { continue }
            ordered.append(item)
        }
        for item in AppTabItem.defaultOrder where !seen.contains(item) {
            ordered.append(item)
        }
        return ordered
    }

    static func encodeHidden(_ hidden: Set<AppTabItem>) -> String {
        AppTabItem.defaultOrder
            .filter { hidden.contains($0) && $0.isHideable }
            .map(\.rawValue)
            .joined(separator: ",")
    }

    static func decodeHidden(_ raw: String) -> Set<AppTabItem> {
        var hidden = Set<AppTabItem>()
        for piece in raw.split(separator: ",") {
            let name = piece.trimmingCharacters(in: .whitespaces)
            if let item = AppTabItem(rawValue: name), item.isHideable { hidden.insert(item) }
        }
        return hidden
    }

    static func visibleOrder(orderRaw: String, hiddenRaw: String) -> [AppTabItem] {
        let hidden = decodeHidden(hiddenRaw)
        return decodeOrder(orderRaw).filter { !hidden.contains($0) }
    }
}

/// 外观模式的稳定取值：与既有 @AppStorage("themeMode") 字符串保持兼容。
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark, eink

    var id: String { rawValue }

    var storedValue: String {
        switch self {
        case .system: return "0"
        case .light: return "1"
        case .dark: return "2"
        case .eink: return "3"
        }
    }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        case .eink: return "E-Ink 模式"
        }
    }

    static func resolve(_ raw: String) -> AppearanceMode {
        allCases.first { $0.storedValue == raw } ?? .system
    }
}

/// 「我的」-「外观」的二级页：外观模式 + 导航入口。
struct AppearanceInteractionView: View {
    @AppStorage("themeMode") private var themeMode = "0"
    @AppStorage(TabBarSettings.orderKey) private var orderRaw = TabBarSettings.defaultOrderRaw
    @AppStorage(TabBarSettings.hiddenKey) private var hiddenRaw = ""
    @State private var showsNavigationSheet = false

    var body: some View {
        Form {
            Section {
                ReadingMenuPickerRow(
                    title: "外观模式",
                    selection: $themeMode,
                    options: AppearanceMode.allCases.map { ReadingMenuOption($0.storedValue, $0.title) },
                    identifier: "appearance.modePicker"
                )
                .frame(minHeight: 44)
                .accessibilityHint("点击展开外观模式选项")
            } header: {
                Text("外观模式")
            } footer: {
                Text("跟随系统会随设备的浅色/深色设置自动切换；E-Ink 模式关闭界面动画，适合墨水屏。")
            }

            Section {
                Button {
                    showsNavigationSheet = true
                } label: {
                    HStack(spacing: 12) {
                        Label("导航", systemImage: "rectangle.bottomthird.inset.filled")
                            .foregroundStyle(ReadingTheme.ink)
                        Spacer(minLength: 8)
                        Text(navigationSummary)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("appearance.navigation")
            } header: {
                Text("导航")
            } footer: {
                Text("自定义底部标签的顺序与显隐。「书架」和「我的」为固定入口，不参与隐藏。")
            }
        }
        .navigationTitle("外观与交互")
        .readingTabBarHidden()
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showsNavigationSheet) {
            TabBarNavigationSheet()
        }
    }

    private var navigationSummary: String {
        let hiddenCount = TabBarSettings.decodeHidden(hiddenRaw).count
        if hiddenCount > 0 { return "已隐藏 \(hiddenCount) 项" }
        return orderRaw == TabBarSettings.defaultOrderRaw ? "默认" : "已调整顺序"
    }
}

/// 底部导航设置抽屉：只提供 full 态，下拉关闭，左上角另有闭合按钮。
struct TabBarNavigationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(TabBarSettings.orderKey) private var orderRaw = TabBarSettings.defaultOrderRaw
    @AppStorage(TabBarSettings.hiddenKey) private var hiddenRaw = ""
    @State private var order: [AppTabItem] = []
    @State private var hidden: Set<AppTabItem> = []
    @State private var loaded = false

    var body: some View {
        ReadingNavigationStack {
            Form {
                Section {
                    ForEach(Array(order.enumerated()), id: \.element) { index, item in
                        TabBarOrderRow(
                            item: item,
                            isHidden: hidden.contains(item),
                            canMoveUp: index > 0,
                            canMoveDown: index < order.count - 1,
                            moveUp: { move(from: index, to: index - 1) },
                            moveDown: { move(from: index, to: index + 1) }
                        )
                    }
                } header: {
                    Text("顺序")
                } footer: {
                    Text("用右侧箭头调整底部标签的排列顺序，改动立即生效。")
                }

                Section {
                    ForEach(AppTabItem.defaultOrder.filter(\.isHideable)) { item in
                        Toggle(isOn: hiddenBinding(for: item)) {
                            Label {
                                Text(item.title)
                            } icon: {
                                Image(systemName: item.systemImage)
                            }
                        }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("navigation.hide.\(item.rawValue)")
                    }
                } header: {
                    Text("显示与隐藏")
                } footer: {
                    Text("隐藏后该标签不再出现在底部导航，仍可从「我的」菜单进入。「书架」和「我的」是固定入口，不参与隐藏。")
                }

                Section {
                    Button("恢复默认顺序与显示") {
                        order = AppTabItem.defaultOrder
                        hidden = []
                        orderRaw = TabBarSettings.defaultOrderRaw
                        hiddenRaw = ""
                    }
                    .frame(minHeight: 44)
                    .disabled(order == AppTabItem.defaultOrder && hidden.isEmpty)
                    .accessibilityIdentifier("navigation.reset")
                }
            }
            .navigationTitle("导航")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("关闭")
                    .accessibilityIdentifier("navigation.close")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Text("\(TabBarSettings.visibleOrder(orderRaw: orderRaw, hiddenRaw: hiddenRaw).count) 个标签")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .onAppear { loadOnce() }
        }
        .readingPresentationDetents([.large])
        .readingPresentationDragIndicator()
    }

    private func loadOnce() {
        guard !loaded else { return }
        loaded = true
        order = TabBarSettings.decodeOrder(orderRaw)
        hidden = TabBarSettings.decodeHidden(hiddenRaw)
    }

    private func move(from index: Int, to destination: Int) {
        guard order.indices.contains(index), order.indices.contains(destination) else { return }
        var updated = order
        let item = updated.remove(at: index)
        updated.insert(item, at: destination)
        order = updated
        orderRaw = TabBarSettings.encodeOrder(updated)
    }

    private func hiddenBinding(for item: AppTabItem) -> Binding<Bool> {
        Binding(
            get: { hidden.contains(item) },
            set: { isHidden in
                if isHidden { hidden.insert(item) } else { hidden.remove(item) }
                hiddenRaw = TabBarSettings.encodeHidden(hidden)
            }
        )
    }
}

private struct TabBarOrderRow: View {
    let item: AppTabItem
    let isHidden: Bool
    let canMoveUp: Bool
    let canMoveDown: Bool
    let moveUp: () -> Void
    let moveDown: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.systemImage)
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(ReadingTheme.accent)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            Text(item.title)
                .foregroundStyle(ReadingTheme.ink)
            if isHidden {
                Text("已隐藏")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .overlay(Capsule().strokeBorder(ReadingTheme.separator, lineWidth: 0.5))
            }
            Spacer(minLength: 8)
            Button(action: moveUp) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(!canMoveUp)
            .accessibilityLabel("上移\(item.title)")
            .accessibilityIdentifier("navigation.up.\(item.rawValue)")
            Button(action: moveDown) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(!canMoveDown)
            .accessibilityLabel("下移\(item.title)")
            .accessibilityIdentifier("navigation.down.\(item.rawValue)")
        }
        .frame(minHeight: 44)
        .accessibilityIdentifier("navigation.order.\(item.rawValue)")
    }
}
