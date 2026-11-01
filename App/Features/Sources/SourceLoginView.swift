@preconcurrency import WebKit
import Combine
import SwiftUI
import UIKit

struct SourceLoginView: View {
    let source: BookSource
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @StateObject private var chrome = LoginWebChromeModel()
    @State private var reloadID = UUID()
    @State private var command: LoginWebCommand?
    @State private var status = "打开登录页后，Cookie 会自动同步给搜索与阅读请求。"
    @State private var isChecking = false
    /// 只读详情（登录头 / Cookie / 日志）。用 bottom sheet 承载，不用居中弹窗。
    @State private var detail: LoginDetail?
    /// 破坏性动作先二次确认：清空 Cookie 会直接掉登录态。
    @State private var pendingAction: DestructiveAction?

    var body: some View {
        // 内容铺满整屏、控件浮在上面（Nagram BrowserUI 的形态）：
        // 不再用 VStack 把头部、状态条、网页依次排开——那样既占两行高度，
        // 观感也像表单而不是浏览器。
        ZStack(alignment: .top) {
            ReadingTheme.canvas.ignoresSafeArea()
            webContent
            chromeOverlay
        }
        // full 态 bottom sheet：原生 sheet 自带背景滚动隔离与 Home Indicator 安全区，
        // 不需要手写 body 滚动锁死，也不该再挂导航栏。
        .readingPresentationDetents([.large])
        .readingPresentationDragIndicator()
        .sheet(item: $detail) { value in
            LoginDetailSheet(detail: value) { detail = nil }
        }
        .alert("确认操作", isPresented: Binding(
            get: { pendingAction != nil },
            set: { if !$0 { pendingAction = nil } }
        ), presenting: pendingAction) { action in
            Button("取消", role: .cancel) { pendingAction = nil }
            Button(action.title, role: .destructive) {
                pendingAction = nil
                perform(action)
            }
        } message: { action in
            Text(action.message)
        }
    }

    // MARK: - 内容层

    /// 内容层：铺满整屏（含安全区），由 `contentInsets` 把首尾让给玻璃控件。
    ///
    /// 这正是 Nagram 的做法——`contentContainerView` 占满 `layout.size`，
    /// WebView 只按 `insets` 收，控件是叠加层而不是布局的一部分。
    @ViewBuilder private var webContent: some View {
        if let request = loginRequest {
            SourceLoginWebView(
                request: request,
                userAgent: webViewUserAgent,
                source: source,
                sourceURL: source.bookSourceUrl,
                sourceID: source.id,
                loginCheckJavaScript: source.loginCheckJs,
                reloadID: reloadID,
                command: command,
                // 顶部要多留 30 而不是 20：`.large` sheet 的拖拽指示条画在
                // 内容区之上约 20pt 处，只按胶囊高度留白会让关闭/确认键与它重叠。
                contentInsets: UIEdgeInsets(
                    top: LoginChrome.headerHeight + 30,
                    left: 0,
                    bottom: LoginChrome.toolbarHeight + 26,
                    right: 0
                ),
                model: chrome,
                status: $status,
                isChecking: $isChecking
            )
            .ignoresSafeArea()
        } else {
            ReadingUnavailableView("登录地址无效", systemImage: "link.badge.plus", description: Text(source.loginUrl ?? "书源没有配置登录地址"))
        }
    }

    // MARK: - 悬浮玻璃控件层

    /// 控件层：全屏内容之上只留两颗玻璃胶囊。
    ///
    /// 旧版是「自绘头部 + 系统色状态条」上下叠两行，既占高度又像表单；
    /// 现在照 Nagram BrowserUI，把标题与状态收进同一颗胶囊
    /// （等价于 `AddressBarContentComponent`），底部再加一颗工具条胶囊，
    /// 中间整块让给网页。滚动时底部工具条按 collapseFraction 下滑退出，
    /// 与 `BrowserScreen.Node.onContentScrollingUpdate` 的 0.5 阈值吸附一致。
    private var chromeOverlay: some View {
        VStack(spacing: 8) {
            glassHeader
            progressHairline.padding(.horizontal, 26)
            Spacer(minLength: 0)
            if let message = chrome.errorMessage {
                errorCard(message)
                Spacer(minLength: 0)
            }
            glassToolbar
                .opacity(Double(1 - chrome.collapseFraction))
                .offset(y: 72 * chrome.collapseFraction)
                .allowsHitTesting(chrome.collapseFraction < 0.5)
        }
        .padding(.horizontal, LoginChrome.sideInset)
        // 18 而不是 6：`.large` sheet 的拖拽指示条占据顶部约 20pt，
        // 留 6 会让头部胶囊与它压在一起。
        .padding(.top, 18)
        .padding(.bottom, 12)
        // 显式撑满：ZStack 里 Spacer 能拿到完整高度提案，但这是隐式行为——
        // 后续改动 VStack 内部任何一项都可能静默退回顶部，
        // 表现为「底部工具条贴着头部」。写死 frame 的成本为零。
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.18), value: chrome.collapseFraction)
    }

    /// 头部胶囊：关闭 / 站点标题与状态 / 确认 / 更多。
    ///
    /// 标题与状态收进同一颗胶囊，等于浏览器的地址栏——滚动态只折叠这一层，
    /// 不会出现「一条 bar 加一条状态条」两层叠着的旧观感。
    private var glassHeader: some View {
        HStack(spacing: LoginChrome.itemSpacing) {
            glassBarButton("xmark", label: "关闭") { dismiss() }
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Image(systemName: hostIsSecure ? "lock.fill" : "lock.open.fill")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(hostTitle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("确认") { confirmLogin() }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ReadingTheme.accent)
                .frame(minWidth: LoginChrome.minTouch, minHeight: LoginChrome.minTouch)
                .contentShape(Rectangle())
                .accessibilityHint("同步已登录的 Cookie 并关闭")
            Menu { menuContent } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: LoginChrome.minTouch, height: LoginChrome.minTouch)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("更多")
        }
        .padding(.horizontal, 4)
        .frame(height: LoginChrome.headerHeight)
        .modifier(GlassPill())
        .scaleEffect(1 - 0.03 * chrome.collapseFraction, anchor: .top)
    }

    private func glassBarButton(_ systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: LoginChrome.minTouch, height: LoginChrome.minTouch)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(label)
    }

    /// 加载进度：只在 1%–99% 之间显示，完成即刻消失。
    /// 与 Nagram `LoadingProgressComponent` 的显隐规则一致
    /// （`value < 0.01 || value > 0.99` 时 alpha 归零），
    /// 只是把线宽压到 2pt 收在胶囊下方，避免在登录这种短页面上抢注意力。
    @ViewBuilder private var progressHairline: some View {
        if chrome.progress > 0.01, chrome.progress < 0.99 {
            Capsule(style: .continuous)
                .fill(ReadingTheme.accent.opacity(0.55))
                .frame(height: 2)
                .scaleEffect(x: max(0.04, chrome.progress), anchor: .leading)
                .animation(.easeOut(duration: 0.25), value: chrome.progress)
        }
    }

    /// 底部工具条胶囊：后退 / 前进 / 刷新 / 在浏览器中打开。
    /// 不可用时降色并 disabled，但仍保留 44pt 热区——避免可点区域随状态跳动。
    private var glassToolbar: some View {
        HStack(spacing: LoginChrome.toolbarSpacing) {
            toolbarButton("chevron.backward", label: "后退", enabled: chrome.canGoBack) {
                command = LoginWebCommand(.back)
            }
            toolbarButton("chevron.forward", label: "前进", enabled: chrome.canGoForward) {
                command = LoginWebCommand(.forward)
            }
            toolbarButton("arrow.clockwise", label: "刷新", enabled: true) { reloadID = UUID() }
            toolbarButton("safari", label: "在浏览器中打开", enabled: source.loginUrl?.isEmpty == false) {
                openInBrowser()
            }
        }
        .frame(height: LoginChrome.toolbarHeight)
        .padding(.horizontal, 8)
        .modifier(GlassPill(cornerRadius: LoginChrome.toolbarHeight / 2))
    }

    private func toolbarButton(_ systemName: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: LoginChrome.minTouch, height: LoginChrome.minTouch)
                .contentShape(Rectangle())
        }
        .foregroundStyle(enabled ? ReadingTheme.accent : ReadingTheme.separator)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    /// 失败态：居中一张玻璃卡加重试，而不是留一片白屏。
    private func errorCard(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("登录页打不开")
                .font(.subheadline.weight(.semibold))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("重试") { reloadID = UUID() }
                .font(.subheadline.weight(.semibold))
                .frame(minWidth: LoginChrome.minTouch, minHeight: LoginChrome.minTouch)
                .contentShape(Rectangle())
        }
        .padding(20)
        .frame(maxWidth: 300)
        .modifier(GlassPill(cornerRadius: 22))
    }

    private var hostTitle: String {
        if !chrome.title.isEmpty { return chrome.title }
        if let host = URL(string: source.loginUrl ?? "")?.host { return host }
        return source.bookSourceName
    }

    private var hostIsSecure: Bool {
        URL(string: source.loginUrl ?? "")?.scheme?.lowercased() == "https"
    }

    /// 更多菜单按「读 → 操作 → 危险」三段。
    /// 先看清当前状态，再重来一次，破坏性动作物理隔到最后并走系统确认，
    /// 避免菜单里一按就清掉登录态。
    @ViewBuilder private var menuContent: some View {
        Button("查看登录头", systemImage: "list.bullet.rectangle") { showLoginHeaders() }
        Button("查看 Cookie", systemImage: "circle.grid.cross") { showCookies() }
        Button("查看日志", systemImage: "doc.text.magnifyingglass") { showLogs() }
        Divider()
        Button("刷新页面", systemImage: "arrow.clockwise") { reloadID = UUID() }
        Button("在浏览器中打开", systemImage: "safari") { openInBrowser() }
        Divider()
        Button("删除登录头", systemImage: "trash", role: .destructive) {
            pendingAction = .removeLoginHeader
        }
        Button("清空 Cookie", systemImage: "xmark.circle", role: .destructive) {
            pendingAction = .clearCookies
        }
    }

    // MARK: - 动作

    /// 「确认」= 把 WebView 里已经登录成功的 Cookie 落到书源会话，然后关闭。
    /// 与页面自动同步走同一套存储，不新增第三条通道。
    private func confirmLogin() {
        if let url = URL(string: source.bookSourceUrl) {
            let cookies = HTTPCookieStorage.shared.cookies(for: url) ?? []
            let header = HTTPCookie.requestHeaderFields(with: cookies)["Cookie"] ?? ""
            if !header.isEmpty {
                let sourceID = source.id
                // 用局部常量避免在 Task 里捕获 self，跨隔离域写状态是这里最容易踩的坑。
                // 三处都要写，缺一处就是「登录成功但书源说未登录」的分叉：
                // - `java.getCookie()` 读的是 `LegadoCookieStore`（SQLite 落盘）
                // - 规则请求带 Cookie 读的是 `SourceNetworkPolicy`（现已落盘）
                // - 系统 WebView / 媒体播放读的是 `HTTPCookieStorage`
                for cookie in cookies {
                    LegadoCookieStore.shared.setCookie("\(cookie.name)=\(cookie.value); Path=/", for: url.absoluteString)
                }
                Task { await SourceNetworkPolicy.shared.setCookieHeader(header, sourceID: sourceID, url: url) }
                DiagnosticLog.shared.record(category: "网络", message: "登录确认：同步 \(cookies.count) 条 Cookie")
            }
        }
        dismiss()
    }

    private func showLoginHeaders() {
        let headers = BookSourceRuntimeStore.shared.loginHeaders(sourceID: source.id)
        let text = headers.isEmpty
            ? "当前没有保存登录头。"
            : headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        detail = LoginDetail(title: "登录头", text: text)
    }

    private func showCookies() {
        var lines: [String] = []
        let saved = LegadoCookieStore.shared.cookieHeader(for: source.bookSourceUrl)
        if !saved.isEmpty { lines.append(saved) }
        if let url = URL(string: source.bookSourceUrl) {
            let session = HTTPCookie.requestHeaderFields(with: HTTPCookieStorage.shared.cookies(for: url) ?? [])["Cookie"] ?? ""
            if !session.isEmpty, session != saved { lines.append(session) }
        }
        detail = LoginDetail(
            title: "Cookie",
            text: lines.isEmpty ? "当前没有已保存的 Cookie。" : lines.joined(separator: "\n\n")
        )
    }

    private func showLogs() {
        let text = DiagnosticLog.shared.export()
        detail = LoginDetail(title: "日志", text: text.isEmpty ? "还没有记录日志。" : text)
    }

    /// 有些站点的登录页依赖 App 内没有的能力（人机校验、第三方 SDK），
    /// 给出「在系统浏览器里打开」这条出口，而不是让用户卡在 WebView 里。
    private func openInBrowser() {
        guard let value = source.loginUrl, let url = URL(string: value) else { return }
        openURL(url)
    }

    private func perform(_ action: DestructiveAction) {
        switch action {
        case .removeLoginHeader:
            BookSourceRuntimeStore.shared.put(sourceID: source.id, key: "loginHeader", value: "")
            status = "已删除登录头"
        case .clearCookies:
            LegadoCookieStore.shared.removeCookies(for: source.bookSourceUrl)
            if let url = URL(string: source.bookSourceUrl) {
                HTTPCookieStorage.shared.cookies(for: url)?.forEach { HTTPCookieStorage.shared.deleteCookie($0) }
                let sourceID = source.id
                Task { await SourceNetworkPolicy.shared.removeCookies(sourceID: sourceID) }
            }
            status = "已清空 Cookie"
        }
    }

    private var loginRequest: URLRequest? {
        guard let value = source.loginUrl,
              let prepared = try? LegadoURLBuilder().prepare(
                value,
                baseURL: URL(string: source.bookSourceUrl),
                defaultHeaders: sourceHeaders
              ) else { return nil }
        return prepared.urlRequest(handleCookies: source.enabledCookieJar ?? true)
    }

    /// 登录页实际使用的 UA。
    ///
    /// 登录页是 WKWebView，WebKit 只认 `customUserAgent`：`URLRequest` 上的
    /// `User-Agent` 会被静默丢弃，抓包看到的是系统默认串（`... Mobile/15E148`）。
    /// 因此「书源 header 设 UA」和「设置 - 网络与缓存设 UA」在登录界面原先都不生效——
    /// 不是设置没保存，而是这条链路根本没读。
    private var webViewUserAgent: String? {
        BookSourceHeaderResolver().webViewUserAgent(for: source)
    }

    /// 书源 header 必须走解析器，不能裸 `JSONSerialization`：
    /// header 支持 `@js:` / `<js>` 动态生成，裸解析会把这类头当成空字典，
    /// 登录页于是丢掉全部自定义头（不只是 UA，还有 Referer、Cookie 等）。
    private var sourceHeaders: [String: String] {
        (try? BookSourceHeaderResolver().resolve(source)) ?? [:]
    }
}

/// 玻璃控件层的度量。
///
/// 数值对齐 Nagram `BrowserNavigationBarComponent`（`panelHeight = 44`、
/// `collapsedHeight = 54`、侧边距 16）与 `BrowserToolbarComponent`
/// （`contentHeight = 56`、胶囊高 48），再向 iOS HIG 的 44pt 最小热区取整。
private enum LoginChrome {
    static let sideInset: CGFloat = 12
    static let itemSpacing: CGFloat = 6
    static let minTouch: CGFloat = 44
    static let headerHeight: CGFloat = 52
    static let toolbarHeight: CGFloat = 48
    static let toolbarSpacing: CGFloat = 18
}

/// 「液态玻璃」底：交给系统的 Liquid Glass。
///
/// 项目整体已提到 iOS 26，`glassEffect` 就是系统原生材质：折射、高光、
/// 随内容变化的透明度都由系统给，并且会自动跟随外观、
/// 「降低透明度」「增强对比度」等可访问性设置退化。
/// 手绘 material + 渐变 + 描边的版本只能模仿到静态观感，
/// 既不会随内容变形，也拿不到系统那层折射。
///
/// 这里只保留一个圆角参数，让头部胶囊、工具条胶囊、错误卡
/// 共用同一份材质语言——玻璃的「厚度」由系统统一决定，
/// 各处只区分形状，不各自调浓度。
private struct GlassPill: ViewModifier {
    var cornerRadius: CGFloat = 26

    func body(content: Content) -> some View {
        content.glassEffect(
            .regular,
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
    }
}

/// 从控件层下发给 WebView 的一次性指令。
///
/// 用「带 id 的值」而不是闭包：`updateUIView` 每次状态变化都会跑，
/// 闭包无法自证是否已执行，会把一次点击变成连续 `goBack()`。
struct LoginWebCommand: Equatable {
    enum Kind: Equatable {
        case back
        case forward
    }

    let id = UUID()
    let kind: Kind

    init(_ kind: Kind) { self.kind = kind }
}

/// 网页控件层需要的全部事实：进度、前进/后退可用性、标题、失败原因、折叠比例。
///
/// 参照 Nagram `BrowserScreen.Node`：WebView 只管内容，这些量通过 KVO 与 delegate
/// 汇总到模型里，SwiftUI 只订阅。否则视图要反向持有 UIKit 对象，
/// 折叠动画与进度线都得跨层读 `WKWebView`，状态一多就互相打架。
final class LoginWebChromeModel: ObservableObject {
    @Published var title = ""
    @Published var progress: Double = 0
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var errorMessage: String?
    /// 0 = 完全展开，1 = 完全收起（Nagram 的 `panelCollapseFraction`）。
    @Published var collapseFraction: CGFloat = 0

    private var offsetToTopEdge: CGFloat = 0

    /// 与 `BrowserScreen.Node.onContentScrollingUpdate` 同一套算法：
    /// 用「到顶部偏移的增量 ÷ 顶部面板高度」累加比例，停下时按 0.5 吸附，
    /// 回到顶端直接归零。这样上下滑动手感一致，比例也不会漂到端点回不来。
    func updateCollapse(offsetToTopEdge offset: CGFloat, isInteracting: Bool, isReset: Bool) {
        let delta = offset - offsetToTopEdge
        offsetToTopEdge = offset
        var fraction = collapseFraction
        if isReset || offset <= 0 {
            fraction = 0
        } else {
            fraction = min(1, max(0, fraction - (-delta) / LoginChrome.headerHeight))
            if !isInteracting { fraction = fraction < 0.5 ? 0 : 1 }
        }
        if abs(fraction - collapseFraction) > 0.01 { collapseFraction = fraction }
    }

    func fail(_ message: String) { errorMessage = message }
    func clearError() { errorMessage = nil }
}

/// 只读详情的内容载体。
private struct LoginDetail: Identifiable {
    let id = UUID()
    let title: String
    let text: String
}

/// 破坏性动作：先确认再执行，每条都写清楚代价。
private enum DestructiveAction: String, Identifiable {
    case removeLoginHeader
    case clearCookies

    var id: String { rawValue }

    var title: String {
        switch self {
        case .removeLoginHeader: "删除登录头"
        case .clearCookies: "清空 Cookie"
        }
    }

    var message: String {
        switch self {
        case .removeLoginHeader: "删除后，依赖登录头的请求会退回书源默认头，需要重新登录。"
        case .clearCookies: "清空后需要重新登录此书源；已保存的登录头不受影响。"
        }
    }
}

/// 只读详情抽屉：等宽字体 + 可选中 + 一键复制。
///
/// 长文本一律走 bottom sheet 而不是居中 Alert（skill 的浮层选型矩阵）：
/// 居中弹窗留给破坏性二次确认，且严禁承载长内容。
private struct LoginDetailSheet: View {
    let detail: LoginDetail
    let onClose: () -> Void
    @State private var copied = false

    var body: some View {
        ReadingNavigationStack {
            ScrollView {
                Text(detail.text)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .background(ReadingTheme.canvas)
            .navigationTitle(detail.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { onClose() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(copied ? "已复制" : "复制", systemImage: "doc.on.doc") {
                        UIPasteboard.general.string = detail.text
                        copied = true
                    }
                }
            }
        }
        .readingPresentationDetents([.medium, .large])
        .readingPresentationDragIndicator()
    }
}

private struct SourceLoginWebView: UIViewRepresentable {
    let request: URLRequest
    /// WebView 专用 UA（`customUserAgent`）。由 `SourceLoginView` 按
    /// 「书源 header > 全局设置 > 系统默认」解析后传入，避免两处各自解析出现分叉。
    let userAgent: String?
    /// 登录检测脚本要在书源 JS 环境里执行（需要 source 上下文），因此整个书源一并传入。
    let source: BookSource
    let sourceURL: String
    let sourceID: String
    let loginCheckJavaScript: String?
    let reloadID: UUID
    /// 控件层下发的导航指令（后退 / 前进）。刷新仍走 `reloadID`，
    /// 因为它还要顺带刷新 `customUserAgent`。
    let command: LoginWebCommand?
    /// 让给玻璃控件层的内容内边距。WebView 铺满整屏（含安全区），
    /// 靠这个值把首尾留出来——正是 Nagram `WebView.customBottomInset` 的思路。
    let contentInsets: UIEdgeInsets
    let model: LoginWebChromeModel
    @Binding var status: String
    @Binding var isChecking: Bool

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = UIColor(ReadingTheme.canvas)
        webView.scrollView.backgroundColor = UIColor(ReadingTheme.canvas)
        // UA 必须在首次 load 之前赋值：WebView 会沿用首个请求的 UA，
        // load 之后再改对已发出的导航无效。
        webView.customUserAgent = userAgent
        DiagnosticLog.shared.record(
            category: "网络",
            message: "登录页 WebView UA：\(userAgent ?? "系统默认")"
        )
        webView.navigationDelegate = context.coordinator
        // 内容铺满整屏后，安全区与控件避让都由我们自己给（Nagram 同做法）：
        // 关掉系统的自动内边距，再由 `contentInsets` 精确留出头部与工具条高度。
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.contentInset = contentInsets
        webView.scrollView.verticalScrollIndicatorInsets = contentInsets
        webView.scrollView.delegate = context.coordinator
        context.coordinator.observe(webView)
        context.coordinator.installExistingCookies(in: webView) { webView.load(request) }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        webView.scrollView.contentInset = contentInsets
        webView.scrollView.verticalScrollIndicatorInsets = contentInsets
        // 指令按 id 只执行一次：`updateUIView` 在每次状态变化时都会跑，
        // 直接调用会让一次「后退」点击变成连点。
        if let command, context.coordinator.lastCommandID != command.id {
            context.coordinator.lastCommandID = command.id
            switch command.kind {
            case .back: webView.goBack()
            case .forward: webView.goForward()
            }
        }
        guard context.coordinator.lastReloadID != reloadID else { return }
        context.coordinator.lastReloadID = reloadID
        // 重新载入时按当前设置刷新 UA：否则用户改完 UA 点「重新载入」，
        // WebView 仍沿用首次创建的旧值，看起来像「改了没用」。
        webView.customUserAgent = userAgent
        webView.reload()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, UIScrollViewDelegate {
        var parent: SourceLoginWebView
        var lastReloadID: UUID
        var lastCommandID: UUID?
        private weak var observedWebView: WKWebView?

        init(parent: SourceLoginWebView) {
            self.parent = parent
            lastReloadID = parent.reloadID
            lastCommandID = parent.command?.id
        }

        deinit {
            if let observedWebView { unobserve(observedWebView) }
        }

        // MARK: 状态汇总

        private static let observedKeyPaths = [
            #keyPath(WKWebView.title),
            #keyPath(WKWebView.estimatedProgress),
            #keyPath(WKWebView.canGoBack),
            #keyPath(WKWebView.canGoForward)
        ]

        func observe(_ webView: WKWebView) {
            guard observedWebView !== webView else { return }
            if let previous = observedWebView { unobserve(previous) }
            observedWebView = webView
            for keyPath in Self.observedKeyPaths {
                webView.addObserver(self, forKeyPath: keyPath, options: [.new], context: nil)
            }
        }

        private func unobserve(_ webView: WKWebView) {
            for keyPath in Self.observedKeyPaths {
                webView.removeObserver(self, forKeyPath: keyPath)
            }
        }

        override func observeValue(
            forKeyPath keyPath: String?,
            of object: Any?,
            change: [NSKeyValueChangeKey: Any]?,
            context: UnsafeMutableRawPointer?
        ) {
            guard let webView = observedWebView else { return }
            switch keyPath {
            case #keyPath(WKWebView.title):
                parent.model.title = webView.title ?? ""
            case #keyPath(WKWebView.estimatedProgress):
                parent.model.progress = webView.estimatedProgress
            case #keyPath(WKWebView.canGoBack):
                parent.model.canGoBack = webView.canGoBack
            case #keyPath(WKWebView.canGoForward):
                parent.model.canGoForward = webView.canGoForward
            default:
                super.observeValue(forKeyPath: keyPath, of: object, change: change, context: context)
            }
        }

        // MARK: 滚动折叠

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            updateCollapse(scrollView, isInteracting: scrollView.isDragging || scrollView.isDecelerating)
        }

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            guard !decelerate else { return }
            updateCollapse(scrollView, isInteracting: false)
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            updateCollapse(scrollView, isInteracting: false)
        }

        func scrollViewDidScrollToTop(_ scrollView: UIScrollView) {
            parent.model.updateCollapse(offsetToTopEdge: 0, isInteracting: false, isReset: true)
        }

        /// 距顶部偏移与 Nagram `BrowserWebContent.updateScrollingOffset` 一致：
        /// 取 `bounds.minY`，负值（橡皮筋下拉）按 0 处理。
        private func updateCollapse(_ scrollView: UIScrollView, isInteracting: Bool) {
            parent.model.updateCollapse(
                offsetToTopEdge: max(0, scrollView.bounds.minY),
                isInteracting: isInteracting,
                isReset: false
            )
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
            parent.status = "正在打开登录页…"
            parent.model.clearError()
            parent.model.progress = 0
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            syncCookies(from: webView)
            guard let script = parent.loginCheckJavaScript?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !script.isEmpty else {
                parent.status = "页面已载入；登录后 Cookie 会自动同步。"
                return
            }
            parent.isChecking = true
            // 关键修正：`loginCheckJs` 不能直接丢进网页的 JS 环境。
            // 书源的检测脚本按 Legado 语义写成 `String(result.body())`，并会调用
            // `java.toast(...)`；直接 evaluateJavaScript 时那里既没有 `result`
            // 也没有 `java`，于是只报出 WKWebView 的通用文案
            // "A JavaScript exception occurred"，看不出真正原因。
            // 正确做法是取回页面 HTML，交给书源 JS 引擎执行，
            // 并把 `result` 绑定成带 body() 的响应对象。
            webView.evaluateJavaScript("document.documentElement.outerHTML") { [weak self] value, error in
                guard let self else { return }
                let html = (value as? String) ?? ""
                if let error {
                    DispatchQueue.main.async {
                        self.parent.isChecking = false
                        self.parent.status = "登录页内容读取失败：\(error.localizedDescription)"
                    }
                    return
                }
                // 同步执行：登录检测脚本只是几条正则 + toast，耗时极短；
                // 放到后台队列会引入跨线程访问 @Binding 的并发问题，得不偿失。
                let outcome = Self.runLoginCheck(script: script, html: html, source: self.parent.source)
                DispatchQueue.main.async {
                    self.parent.isChecking = false
                    switch outcome {
                    case .success(let passed):
                        self.parent.status = passed ? "书源登录检测已通过" : "页面已载入，尚未检测到登录状态"
                    case .failure(let error):
                        self.parent.status = "登录检测脚本失败：\(error.localizedDescription)"
                    }
                }
            }
        }

        private static func runLoginCheck(
            script: String,
            html: String,
            source: BookSource
        ) -> Result<Bool, Error> {
            do {
                let context = RuleExecutionContext(
                    baseURL: source.bookSourceUrl,
                    source: source,
                    responseBody: html
                )
                let evaluated = try JavaScriptRuleEvaluator().evaluate(
                    script: script,
                    result: .string(html),
                    executionContext: context
                )
                return .success(truthy(evaluated.value))
            } catch {
                return .failure(error)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
            failLogin(with: error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: Error) {
            failLogin(with: error)
        }

        /// 失败同时落到状态文案与玻璃错误卡：只写状态条的话，
        /// 内容区就是一片白屏，用户看不出是「还没加载」还是「已经失败」。
        private func failLogin(with error: Error) {
            let message = error.localizedDescription
            parent.status = "登录页加载失败：\(message)"
            parent.model.fail(message)
            parent.model.progress = 0
        }

        func installExistingCookies(in webView: WKWebView, completion: @escaping () -> Void) {
            guard let url = URL(string: parent.sourceURL) else {
                completion()
                return
            }
            let cookies = HTTPCookieStorage.shared.cookies(for: url) ?? []
            guard !cookies.isEmpty else {
                completion()
                return
            }
            let group = DispatchGroup()
            for cookie in cookies {
                group.enter()
                webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) { group.leave() }
            }
            group.notify(queue: .main, execute: completion)
        }

        private func syncCookies(from webView: WKWebView) {
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                cookies.forEach(HTTPCookieStorage.shared.setCookie)
                guard let url = URL(string: self.parent.sourceURL) else { return }
                let matching = HTTPCookieStorage.shared.cookies(for: url) ?? []
                let header = HTTPCookie.requestHeaderFields(with: matching)["Cookie"] ?? ""
                Task {
                    await SourceNetworkPolicy.shared.setCookieHeader(
                        header,
                        sourceID: self.parent.sourceID,
                        url: url
                    )
                }
            }
        }

        /// 与 Legado 的判定保持一致：只有明确的假值才算未登录。
        /// 这条书源的检测脚本最后一句就是 `result;`（返回响应对象本身），
        /// 若把对象当成假值会永远报「未检测到登录状态」，与真实行为相反。
        private static func truthy(_ value: JSONValue) -> Bool {
            switch value {
            case .bool(let flag):
                return flag
            case .number(let number):
                return number != 0
            case .string(let text):
                let lower = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return !lower.isEmpty && !["false", "0", "null", "undefined"].contains(lower)
            case .null:
                return false
            case .object, .array:
                return true
            }
        }
    }
}

final class WKSourceWebViewExecutor: NSObject, SourceWebViewRequestExecuting, @unchecked Sendable {
    @MainActor
    func execute(_ prepared: PreparedRequest, source: BookSource, timeout: TimeInterval) async throws -> HTTPResponse {
        let override = ApplicationSettingsStore.shared.settings.timeoutSeconds
        return try await BackgroundWebViewRequest(prepared: prepared, source: source, timeout: override > 0 ? Double(override) : timeout).run()
    }
}

@MainActor
private final class BackgroundWebViewRequest: NSObject, WKNavigationDelegate {
    private let prepared: PreparedRequest
    private let source: BookSource
    private let timeout: TimeInterval
    private let webView: WKWebView
    private var continuation: CheckedContinuation<HTTPResponse, Error>?
    private var responseStatus = 200
    private var responseHeaders: [String: String] = [:]
    private var completed = false
    private var timeoutTask: Task<Void, Never>?

    init(prepared: PreparedRequest, source: BookSource, timeout: TimeInterval) {
        self.prepared = prepared
        self.source = source
        self.timeout = timeout
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        // WebKit 只认 customUserAgent：URLRequest 上的 User-Agent 会被静默丢弃，
        // 实际发出的是系统默认串（`... Mobile/15E148`）。书源 header 与
        // 「设置 - 网络与缓存」里的 UA 在 WebView 链路上都只能从这一处生效。
        // 必须在 load 之前赋值：WebView 会缓存首个 UA。
        webView.customUserAgent = BookSourceHeaderResolver().webViewUserAgent(prepared)
    }

    func run() async throws -> HTTPResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                installRequestCookies { [weak self] in self?.startLoading() }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
        }
    }

    private func startLoading() {
        timeoutTask = Task { [weak self] in
            let seconds = min(max(self?.timeout ?? 30, 1), 300)
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.finish(.failure(URLError(.timedOut))) }
        }
        webView.load(prepared.urlRequest(timeout: timeout, handleCookies: true))
    }

    private func installRequestCookies(completion: @escaping () -> Void) {
        guard let header = prepared.headers.first(where: { $0.key.caseInsensitiveCompare("Cookie") == .orderedSame })?.value,
              let host = prepared.url.host, !header.isEmpty else {
            completion()
            return
        }
        let cookies = header.split(separator: ";").compactMap { part -> HTTPCookie? in
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { return nil }
            return HTTPCookie(properties: [
                .name: pair[0].trimmingCharacters(in: .whitespaces),
                .value: pair[1],
                .domain: host,
                .path: "/",
                .secure: prepared.url.scheme == "https" ? "TRUE" : "FALSE"
            ])
        }
        guard !cookies.isEmpty else { completion(); return }
        let group = DispatchGroup()
        for cookie in cookies {
            group.enter()
            webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) { group.leave() }
        }
        group.notify(queue: .main, execute: completion)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void
    ) {
        if let response = navigationResponse.response as? HTTPURLResponse {
            responseStatus = response.statusCode
            responseHeaders = response.allHeaderFields.reduce(into: [:]) { result, entry in
                result[String(describing: entry.key)] = String(describing: entry.value)
            }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
        Task { [weak self] in
            guard let self else { return }
            if prepared.webViewDelayMilliseconds > 0 {
                try? await Task.sleep(nanoseconds: UInt64(max(0, prepared.webViewDelayMilliseconds)) * 1_000_000)
            }
            guard !Task.isCancelled, !completed else { return }
            if let script = prepared.webJavaScript, !script.isEmpty {
                do { _ = try await webView.evaluateJavaScript(script) }
                catch { finish(.failure(error)); return }
            }
            do {
                let html = try await webView.evaluateJavaScript("document.documentElement.outerHTML") as? String ?? ""
                let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
                cookies.forEach(HTTPCookieStorage.shared.setCookie)
                let cookieHeader = HTTPCookie.requestHeaderFields(with: cookies)["Cookie"] ?? ""
                if !cookieHeader.isEmpty {
                    await SourceNetworkPolicy.shared.setCookieHeader(cookieHeader, sourceID: source.id, url: prepared.url)
                }
                var headers = responseHeaders
                if !cookieHeader.isEmpty { headers["Set-Cookie"] = cookieHeader }
                finish(.success(.init(
                    data: Data(html.utf8),
                    statusCode: responseStatus,
                    headers: headers,
                    finalURL: webView.url ?? prepared.url,
                    requestedCharset: "utf-8"
                )))
            } catch {
                finish(.failure(error))
            }
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation?, withError error: Error) {
        finish(.failure(error))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<HTTPResponse, Error>) {
        guard !completed else { return }
        completed = true
        timeoutTask?.cancel()
        webView.stopLoading()
        continuation?.resume(with: result)
        continuation = nil
    }
}

private extension WKHTTPCookieStore {
    func allCookies() async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            getAllCookies { continuation.resume(returning: $0) }
        }
    }
}
