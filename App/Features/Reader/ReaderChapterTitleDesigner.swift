import CoreGraphics
import Foundation
import SwiftUI
import UIKit
import WebKit

/// 设计器导出回来的东西。
///
/// 口径照 Juyue `ChapterTitleDesignExport`（`ChapterTitleDesignerView.swift:6`）：
/// `htmlTemplate` 是渲染用的 HTML 片段，`projectJSON` 是完整工程（元素 / 画布 / 资源），
/// 下次打开设计器要回灌；`canvasHeight` 是设计稿画布高度，换算预留高度时用。
struct ChapterTitleDesignExport {
    var htmlTemplate: String = ""
    var projectJSON: String = ""
    var canvasHeight: Double = 0
}

/// 章节标题的渲染侧。
///
/// 照 Juyue `ChapterTitleRenderer`（`ChapterTitleDesignerView.swift:155`）：
/// 设计器导出的 `htmlTemplate` 里图片是 `qireader-title-asset://<id>` 这种自定义协议，
/// 直接丢给 WebView 加载不出来，得先用 `projectJSON` 里的资源换成 data URI。
///
/// 与 Juyue 的差别只有一处：他是页内叠一层 `WKWebView`，我们页内是 CoreText 矢量绘制，
/// 叠 WebView 卷页时会糊，所以这里只负责「产出一张位图」，叠图的事交给页视图。
enum ChapterTitleRenderer {

    /// `render` 在排版路径里调，换字号 / 翻页都会跑一遍。
    /// 里面要 JSON 解析 + 正则替换 + 拼串，不缓存的话每次都在做这些。
    private final class Cache: @unchecked Sendable {
        static let shared = Cache()
        private var html: [String: String] = [:]
        private var canvas: [String: CGSize] = [:]
        private let lock = NSLock()

        func html(for key: String) -> String? {
            lock.lock(); defer { lock.unlock() }
            return html[key]
        }

        func storeHTML(_ value: String, for key: String) {
            lock.lock()
            if html.count > 64 { html.removeAll() }
            html[key] = value
            lock.unlock()
        }

        func canvas(for key: String) -> CGSize? {
            lock.lock(); defer { lock.unlock() }
            return canvas[key]
        }

        func storeCanvas(_ value: CGSize, for key: String) {
            lock.lock()
            if canvas.count > 64 { canvas.removeAll() }
            canvas[key] = value
            lock.unlock()
        }
    }

    /// 画布尺寸：拿不到就给个兜底，免得按 0 算高度把标题压成一条线。
    static func canvasSize(projectJSON: String) -> CGSize {
        guard !projectJSON.isEmpty else { return CGSize(width: 360, height: 120) }
        let key = "c\(projectJSON.hashValue)"
        if let cached = Cache.shared.canvas(for: key) { return cached }
        guard let data = projectJSON.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let canvas = root["canvas"] as? [String: Any] else {
            return CGSize(width: 360, height: 120)
        }
        let width = (canvas["width"] as? NSNumber)?.doubleValue ?? 360
        let height = (canvas["height"] as? NSNumber)?.doubleValue ?? 120
        let size = CGSize(width: max(80, width), height: max(24, height))
        Cache.shared.storeCanvas(size, for: key)
        return size
    }

    /// 按可用宽度等比缩放后的标题高度：分页预留与绘制共用这一个数。
    static func height(forWidth width: CGFloat, projectJSON: String, canvasHeight: Double = 0) -> CGFloat {
        guard width > 1 else { return 0 }
        let canvas = canvasSize(projectJSON: projectJSON)
        // 设计器回传的画布高度优先：工程 JSON 里缺 canvas 字段时它还能兜住。
        let base = canvasHeight > 0 ? CGFloat(canvasHeight) : canvas.height
        let raw = base * (width / max(1, canvas.width))
        guard raw.isFinite, raw > 0 else { return 24 }
        return max(20, raw)
    }

    /// 资源 id → 可直接塞进 HTML 的地址。
    static func assetURLs(projectJSON: String) -> [String: String] {
        guard !projectJSON.isEmpty,
              let data = projectJSON.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assets = root["assets"] as? [[String: Any]] else { return [:] }
        var map: [String: String] = [:]
        for asset in assets {
            guard let id = asset["id"] as? String else { continue }
            let raw = (asset["url"] as? String) ?? (asset["src"] as? String) ?? ""
            if raw.isEmpty { continue }
            if raw.hasPrefix("data:") || raw.hasPrefix("http://") || raw.hasPrefix("https://") {
                map[id] = raw
            } else if raw.hasPrefix("file://"), let url = URL(string: raw), let inlined = inlineFile(url.path) {
                map[id] = inlined
            } else if raw.hasPrefix("/"), let inlined = inlineFile(raw) {
                map[id] = inlined
            } else {
                map[id] = raw
            }
        }
        return map
    }

    private static func inlineFile(_ path: String) -> String? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        let ext = (path as NSString).pathExtension.lowercased()
        let mime: String
        switch ext {
        case "png": mime = "image/png"
        case "jpg", "jpeg": mime = "image/jpeg"
        case "gif": mime = "image/gif"
        case "webp": mime = "image/webp"
        case "svg": mime = "image/svg+xml"
        default: mime = "application/octet-stream"
        }
        return "data:\(mime);base64,\(data.base64EncodedString())"
    }

    /// 把 `data-qr-type="chapterName"/"chapterNumber"` 节点里的占位文字换成真章节。
    private static func fill(_ html: String, type: String, value: String) -> String {
        let pattern = "(<[^>]*data-qr-type=\"\(type)\"[^>]*>)(.*?)(</)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return html
        }
        let range = NSRange(html.startIndex..., in: html)
        // 值里的 $ 会被当成反向引用，先转义
        let safe = value.replacingOccurrences(of: "$", with: "\\$")
        return regex.stringByReplacingMatches(in: html, options: [], range: range, withTemplate: "$1\(safe)$3")
    }

    /// 拼成一张自包含的页面：模板 + 透明底 + 禁滚动。
    static func render(
        htmlTemplate: String,
        projectJSON: String,
        chapterTitle: String = "",
        chapterNumber: String = ""
    ) -> String {
        guard !htmlTemplate.isEmpty else { return "" }
        let key = "r\(htmlTemplate.hashValue)|\(projectJSON.hashValue)|\(chapterTitle)|\(chapterNumber)"
        if let cached = Cache.shared.html(for: key) { return cached }
        var html = htmlTemplate
        for (id, url) in assetURLs(projectJSON: projectJSON) {
            html = html.replacingOccurrences(of: "qireader-title-asset://\(id)", with: url)
        }
        if !chapterTitle.isEmpty { html = fill(html, type: "chapterName", value: chapterTitle) }
        if !chapterNumber.isEmpty { html = fill(html, type: "chapterNumber", value: chapterNumber) }
        let page = """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
        <style>
        html,body{margin:0;padding:0;background:transparent;overflow:hidden;
        -webkit-text-size-adjust:100%;-webkit-user-select:none;user-select:none;}
        </style></head><body>\(html)</body></html>
        """
        Cache.shared.storeHTML(page, for: key)
        return page
    }
}

/// 离屏把设计稿截成一张位图。
///
/// 为什么不用页内 `WKWebView`：我们页内是 CoreText 逐行矢量绘制，卷页时整页被
/// Core Animation 卷曲，叠一层 WebView 会在卷起过程中糊掉。截成位图之后，标题与
/// 正文一样是页内绘制内容，卷页观感一致；分页只多一个「标题预留高度」，行内
/// 排版一个字符不动。
/// 主线程使用：调用点都在 `ReaderTextView` 的排版路径（主线程）。
///
/// `@MainActor`：CI 实测的两条错误都源于这里不是 actor-isolated ——
/// 1) `static property 'shared' is not concurrency-safe because non-'Sendable' type
///    'ReaderChapterTitleStore' may have shared mutable state`；
/// 2) `sending value of non-Sendable type '(UIImage?) -> Void' risks causing data races`，
///    因为 `ReaderTitleSnapshotRenderer` 遵从 `WKNavigationDelegate`，被 Swift 6 按
///    「main actor isolation inferred from conformance to protocol」推断成 `@MainActor`，
///    从非隔离方法体里构造它、并把非 Sendable 的完成闭包传进去，就是跨隔离域发送。
///
/// 标成 `@MainActor` 之后：构造、`start()`、`didFinish`、`takeSnapshot` 完成闭包全落在
/// 同一隔离域，闭包不再跨边界；`static let shared` 也因主 actor 隔离而天然并发安全，
/// 不需要 `@unchecked Sendable` 这种「骗过检查」的写法。
@MainActor
final class ReaderChapterTitleStore {
    static let shared = ReaderChapterTitleStore()

    private var images: [String: UIImage] = [:]
    private var renderers: [String: ReaderTitleSnapshotRenderer] = [:]
    /// 已经渲染失败过的签名：同一章同一尺寸只再试，不再无限重试
    /// （失败时 `renderers` 里的 key 会被移除，不加这个集合就会每次重建都重新起一个 WebView）。
    private var failed: Set<String> = []

    /// 已渲染好的标题图；没有就返回 nil，并在后台开始渲染，完成后回调一次。
    ///
    /// 高度由调用方按画布等比算好，所以「图还没回来」时排版不会重排两次：
    /// 预留高度先占住，图回来只是重绘。
    func image(
        htmlTemplate: String,
        projectJSON: String,
        chapterTitle: String,
        chapterNumber: String,
        size: CGSize,
        isDark: Bool,
        window: UIWindow?,
        onReady: @escaping () -> Void
    ) -> UIImage? {
        guard !htmlTemplate.isEmpty, size.width > 1, size.height > 1 else { return nil }
        let key = "i\(htmlTemplate.hashValue)|\(projectJSON.hashValue)|\(chapterTitle)|\(chapterNumber)|\(Int(size.width))x\(Int(size.height))|\(isDark)"
        if let cached = images[key] { return cached }
        guard !failed.contains(key) else { return nil }
        guard renderers[key] == nil else { return nil }

        let html = ChapterTitleRenderer.render(
            htmlTemplate: htmlTemplate,
            projectJSON: projectJSON,
            chapterTitle: chapterTitle,
            chapterNumber: chapterNumber
        )
        guard !html.isEmpty else { return nil }

        let renderer = ReaderTitleSnapshotRenderer(
            html: html,
            size: size,
            isDark: isDark,
            window: window
        ) { [weak self] image in
            guard let self else { return }
            self.renderers.removeValue(forKey: key)
            if let image {
                if self.images.count > 24 { self.images.removeAll() }
                self.images[key] = image
            } else if self.failed.count < 64 {
                // 记住失败：同一签名不再反复起 WebView，避免重建 → 失败 → 再重建的循环。
                self.failed.insert(key)
            }
            onReady()
        }
        renderers[key] = renderer
        renderer.start()
        return nil
    }

    /// 换书 / 清掉设计稿时把缓存一起丢掉，避免再来一本同名字章节串图。
    func clear() {
        images.removeAll()
        renderers.removeAll()
        failed.removeAll()
    }
}

/// 一个离屏渲染任务：装页面 → 等绘制 → `takeSnapshot` 取图 → 回调。
///
/// WebView 必须挂在窗口上才会真正绘制（不在视图层级里截出来是空的），所以短暂
/// 贴在窗口左上角、透明度 0.02、不接收触摸，截完立刻移除，用户看不出闪。
/// 显式 `@MainActor`：本类遵从 `WKNavigationDelegate`，Swift 6 会按「main actor isolation
/// inferred from conformance to protocol」把它推断成 `@MainActor`。写出来是为了让调用方
/// 一眼看到隔离域 —— 上一版没写，CI 报的是「把非 Sendable 闭包发送到隔离域」。
@MainActor
private final class ReaderTitleSnapshotRenderer: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private let size: CGSize
    private let isDark: Bool
    /// 临时载体窗口：WebView 必须真的在窗口里才会绘制。
    /// 不用 `UIApplication.shared` —— 那是 main-actor 隔离的入口，在非隔离上下文里取会编译不过。
    private weak var hostWindow: UIWindow?
    private let onFinish: (UIImage?) -> Void
    private var finished = false

    init(
        html: String,
        size: CGSize,
        isDark: Bool,
        window: UIWindow?,
        onFinish: @escaping (UIImage?) -> Void
    ) {
        self.size = size
        self.isDark = isDark
        self.hostWindow = window
        self.onFinish = onFinish
        let configuration = WKWebViewConfiguration()
        webView = WKWebView(frame: CGRect(origin: .zero, size: size), configuration: configuration)
        super.init()
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isUserInteractionEnabled = false
        // 不要调低 alpha：`takeSnapshot` 会把视图透明度一起算进结果，0.02 的 alpha 截出来
        // 就是一张几乎全透明的图（实测「设计标题的字极其透明」）。靠叠放次序把它藏起来。
        webView.navigationDelegate = self
        webView.loadHTMLString(html, baseURL: nil)
    }

    func start() {
        guard let window = hostWindow else {
            finish(nil)
            return
        }
        // 塞到最底层：WebView 必须在窗口里才会真正绘制（否则截出来是白的），
        // 但压在根视图下面用户看不见，也就不需要靠降低 alpha 来藏。
        window.insertSubview(webView, at: 0)
        // 兜底：WebKit 若迟迟不回 didFinish（离线资源缺一块），1.5 秒后按空图收尾，
        // 否则这个 key 会一直挂在 renderers 里，下次再进这一章永远拿不到图。
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.finish(nil)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // 等一帧：didFinish 时首屏绘制可能还没提交，立刻截会截到空白。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self, !self.finished else { return }
            let configuration = WKSnapshotConfiguration()
            configuration.rect = CGRect(origin: .zero, size: self.size)
            self.webView.takeSnapshot(with: configuration) { image, _ in
                // takeSnapshot 的 completion 不是隔离闭包，回主线程再收尾：
                // 直接写 MainActor.assumeIsolated 在低版本 SDK 上没有这个入口。
                DispatchQueue.main.async {
                    self.finish(image)
                }
            }
        }
    }

    private func finish(_ image: UIImage?) {
        guard !finished else { return }
        finished = true
        webView.navigationDelegate = nil
        webView.removeFromSuperview()
        onFinish(image)
    }
}

/// 章节标题设计器。
///
/// 页面就是 `Resources/ChapterTitleDesigner`（index.html + designer.js），
/// 协议照它原有的走：原生注册 `chapterTitleDesigner` 消息处理器收 `{type, payload}`，
/// 下发用 `window.qireaderTitleDesigner.receive({command, payload})`。
struct ChapterTitleDesignerView: View {
    @Environment(\.dismiss) private var dismiss

    /// 上次的工程 JSON：打开设计器要回灌，否则每次都是白画布。
    let initialProjectJSON: String
    let isDark: Bool
    let onSave: (ChapterTitleDesignExport) -> Void

    @State private var exportTicket = 0
    @State private var pending: ChapterTitleDesignExport?
    @State private var status = "调好之后点右上角「保存」"

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("章节标题设计器")
                    .font(.system(size: 16, weight: .semibold))
                Spacer()
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button("取消") { dismiss() }
                    .font(.system(size: 14))
                Button("保存") {
                    status = "正在取设计结果…"
                    exportTicket += 1
                }
                .font(.system(size: 14, weight: .semibold))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            ChapterTitleDesignerWebView(
                initialProjectJSON: initialProjectJSON,
                isDark: isDark,
                exportTicket: exportTicket,
                onExport: { export in pending = export }
            )
        }
        .onChange(of: exportTicket) { _ in
            guard exportTicket > 0 else { return }
            // 等设计器把 exportProject 回传上来再落盘。
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                guard let export = pending, !export.projectJSON.isEmpty else {
                    status = "没取到设计结果，请重试"
                    exportTicket = 0
                    return
                }
                onSave(export)
                dismiss()
            }
        }
    }
}

/// 承载设计器页面的 WebView。
struct ChapterTitleDesignerWebView: UIViewRepresentable {
    let initialProjectJSON: String
    let isDark: Bool
    /// 自增一下就向设计器要一次导出结果
    let exportTicket: Int
    let onExport: (ChapterTitleDesignExport) -> Void

    func makeCoordinator() -> ChapterTitleDesignerCoordinator {
        let coordinator = ChapterTitleDesignerCoordinator()
        coordinator.initialProjectJSON = initialProjectJSON
        coordinator.isDark = isDark
        coordinator.onExport = onExport
        return coordinator
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "chapterTitleDesigner")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        if let url = ChapterTitleDesignerBundle.indexURL {
            view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.onExport = onExport
        if exportTicket > 0 { context.coordinator.requestExport(in: view) }
    }

    static func dismantleUIView(_ view: WKWebView, coordinator: ChapterTitleDesignerCoordinator) {
        view.configuration.userContentController.removeScriptMessageHandler(forName: "chapterTitleDesigner")
        view.navigationDelegate = nil
    }
}

/// 设计器静态资源的位置。目录是以 folder reference 进 bundle 的，所以子目录在。
enum ChapterTitleDesignerBundle {
    static var indexURL: URL? {
        Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "ChapterTitleDesigner")
    }

    static var isAvailable: Bool { indexURL != nil }
}

/// 设计器的原生侧：接 `chapterTitleDesigner` 消息，向下发 `setTheme` / `initProject` / `requestExport`。
final class ChapterTitleDesignerCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var initialProjectJSON = ""
    var isDark = false
    var onExport: ((ChapterTitleDesignExport) -> Void)?
    private var loaded = false

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "chapterTitleDesigner",
              let body = message.body as? [String: Any] else { return }
        let type = (body["type"] as? String) ?? ""
        guard type == "exportProject", let payload = body["payload"] as? [String: Any] else { return }
        var export = ChapterTitleDesignExport()
        export.htmlTemplate = (payload["htmlTemplate"] as? String) ?? ""
        export.projectJSON = (payload["projectJSON"] as? String) ?? ""
        export.canvasHeight = (payload["canvasHeight"] as? NSNumber)?.doubleValue ?? 0
        onExport?(export)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !loaded else { return }
        loaded = true
        send("setTheme", ["name": isDark ? "dark" : "light"], to: webView)
        if !initialProjectJSON.isEmpty {
            // initProject 收的是工程对象，不是字符串，所以在这里 parse。
            let js = "try{window.qireaderTitleDesigner.receive({command:'initProject',payload:"
                + "JSON.parse(\(ChapterTitleDesignerCoordinator.jsStringLiteral(initialProjectJSON)))});}catch(e){console.error(e);}"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }
    }

    func requestExport(in webView: WKWebView) {
        webView.evaluateJavaScript(
            "window.qireaderTitleDesigner && window.qireaderTitleDesigner.requestExport();",
            completionHandler: nil
        )
    }

    private func send(_ command: String, _ payload: [String: Any], to webView: WKWebView) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript(
            "window.qireaderTitleDesigner && window.qireaderTitleDesigner.receive({command:'\(command)',payload:\(text)});",
            completionHandler: nil
        )
    }

    /// 把字符串编成 JS 字面量：工程 JSON 里有中文和引号，不能直接拼。
    static func jsStringLiteral(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let text = String(data: data, encoding: .utf8) else { return "\"\"" }
        // 去掉外层数组的方括号，留下带转义的字符串字面量
        return String(text.dropFirst().dropLast())
    }
}
