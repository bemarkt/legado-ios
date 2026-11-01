import SwiftUI

struct RSSSourceEditorView: View {
    @EnvironmentObject private var library: RSSLibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var source: RssSource
    private let originalURL: String?

    init(source: RssSource? = nil) {
        let value = source ?? RssSource()
        _source = State(initialValue: value)
        originalURL = source?.sourceUrl
    }

    var body: some View {
        Form {
            Section("基本") {
                TextField("名称", text: $source.sourceName)
                TextField("URL", text: $source.sourceUrl).textInputAutocapitalization(.never).keyboardType(.URL)
                requiredField("图标", \.sourceIcon)
                optionalField("分组", \.sourceGroup)
                optionalField("注释", \.sourceComment, axis: .vertical)
                Toggle("启用", isOn: $source.enabled)
            }
            Section("请求与登录") {
                optionalField("自定义变量说明", \.variableComment, axis: .vertical)
                optionalField("JS库", \.jsLib, axis: .vertical)
                Toggle("自动保存Cookie", isOn: optionalBool(\.enabledCookieJar, default: true))
                optionalField("并发率", \.concurrentRate)
                optionalField("请求头", \.header, axis: .vertical)
                optionalField("登录地址", \.loginUrl)
                optionalField("登录UI", \.loginUi, axis: .vertical)
                optionalField("登录检测JS", \.loginCheckJs, axis: .vertical)
                optionalField("封面解密JS", \.coverDecodeJs, axis: .vertical)
            }
            Section("分类与列表规则") {
                optionalField("分类URL（名称::URL）", \.sortUrl, axis: .vertical)
                Toggle("单URL源", isOn: $source.singleUrl)
                ReadingMenuPickerRow(
                    title: "列表样式",
                    selection: $source.articleStyle,
                    options: (0..<5).map { ReadingMenuOption($0, "样式 \($0)") },
                    identifier: "rss.articleStyle"
                )
                optionalField("列表规则", \.ruleArticles, axis: .vertical)
                optionalField("下一页规则", \.ruleNextPage, axis: .vertical)
                optionalField("标题规则", \.ruleTitle, axis: .vertical)
                optionalField("发布日期规则", \.rulePubDate, axis: .vertical)
                optionalField("描述规则", \.ruleDescription, axis: .vertical)
                optionalField("图片规则", \.ruleImage, axis: .vertical)
                optionalField("链接规则", \.ruleLink, axis: .vertical)
                optionalField("正文规则", \.ruleContent, axis: .vertical)
            }
            Section("WebView规则") {
                optionalField("正文URL白名单", \.contentWhitelist, axis: .vertical)
                optionalField("正文URL黑名单", \.contentBlacklist, axis: .vertical)
                optionalField("跳转URL拦截JS", \.shouldOverrideUrlLoading, axis: .vertical)
                optionalField("样式", \.style, axis: .vertical)
                Toggle("启用JavaScript", isOn: $source.enableJs)
                Toggle("使用Base URL加载", isOn: $source.loadWithBaseUrl)
                optionalField("注入JS", \.injectJs, axis: .vertical)
                optionalField("预注入JS", \.preloadJs, axis: .vertical)
                optionalField("起始HTML", \.startHtml, axis: .vertical)
                optionalField("起始样式", \.startStyle, axis: .vertical)
                optionalField("起始JS", \.startJs, axis: .vertical)
                Toggle("输出网页日志", isOn: $source.showWebLog)
            }
            Section("其他") {
                Stepper("自定义排序：\(source.customOrder)", value: $source.customOrder)
                ReadingMenuPickerRow(
                    title: "类型",
                    selection: $source.type,
                    options: [ReadingMenuOption(0, "网页"), ReadingMenuOption(1, "图片"), ReadingMenuOption(2, "视频")],
                    identifier: "rss.sourceType"
                )
                Toggle("启用预加载", isOn: $source.preload)
                Toggle("优先加载缓存", isOn: $source.cacheFirst)
                optionalField("搜索URL", \.searchUrl, axis: .vertical)
            }
        }
        .navigationTitle(originalURL == nil ? "新建RSS源" : "编辑RSS源")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { Task { if await library.save(source, replacing: originalURL) { dismiss() } } }
            }
        }
    }

    @ViewBuilder private func optionalField(_ title: String, _ keyPath: WritableKeyPath<RssSource, String?>, axis: Axis = .horizontal) -> some View {
        ReadingTextField(title, text: optionalText(keyPath), axis: axis).textInputAutocapitalization(.never)
    }
    @ViewBuilder private func requiredField(_ title: String, _ keyPath: WritableKeyPath<RssSource, String>, axis: Axis = .horizontal) -> some View {
        ReadingTextField(title, text: Binding(get: { source[keyPath: keyPath] }, set: { source[keyPath: keyPath] = $0 }), axis: axis).textInputAutocapitalization(.never)
    }
    private func optionalText(_ keyPath: WritableKeyPath<RssSource, String?>) -> Binding<String> {
        Binding(get: { source[keyPath: keyPath] ?? "" }, set: { source[keyPath: keyPath] = $0.isEmpty ? nil : $0 })
    }
    private func optionalBool(_ keyPath: WritableKeyPath<RssSource, Bool?>, default defaultValue: Bool) -> Binding<Bool> {
        Binding(get: { source[keyPath: keyPath] ?? defaultValue }, set: { source[keyPath: keyPath] = $0 })
    }
}
