import SwiftUI
import WebKit

/// A separate, temporary website session. It never hosts source author code or a sourceHost bridge.
@MainActor
final class NativeSourceLoginBrowser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published private(set) var webView: WKWebView?
    @Published private(set) var ready = false
    @Published private(set) var loading = false
    @Published private(set) var message: String?
    @Published private(set) var currentOrigin: String?
    let origin: String
    let credentialOrigins: Set<String>
    private let request: URLRequest
    private let allowLoopbackHTTP: Bool
    private var started = false
    private var closed = false
    init(origin: String, request: URLRequest? = nil, credentialOrigins: Set<String>? = nil, allowLoopbackHTTP: Bool = false) {
        self.origin = origin
        self.request = request ?? URLRequest(url: URL(string: origin + "/")!)
        self.credentialOrigins = credentialOrigins ?? [origin]
        self.allowLoopbackHTTP = allowLoopbackHTTP
        super.init()
    }
    func prepare(cookies: [SourceCredentialCookie]) async throws {
        guard !started, !closed else { throw SourceDomainError(.stale, "登录窗口已关闭，请重新打开。") }
        started = true
        guard let url = request.url, allowsNavigation(url) else { throw SourceDomainError(.invalidInput, "无效的登录网站。") }
        // An interactive website is not a source execution page. CDNs, redirects and identity
        // providers use ordinary WebKit HTTPS networking; no sourceHost bridge is installed.
        // This never expands the source's native HTTP or credential export permissions.
        var rules: [[String: Any]] = [
            ["trigger": ["url-filter": ".*"], "action": ["type": "block"]],
            ["trigger": ["url-filter": "^https://"], "action": ["type": "ignore-previous-rules"]],
            ["trigger": ["url-filter": "^(data|blob):"], "action": ["type": "ignore-previous-rules"]]
        ]
        if allowLoopbackHTTP {
            rules.append(["trigger": ["url-filter": #"^http://(127\.0\.0\.1|localhost|\[::1\])(:[0-9]+)?/"#], "action": ["type": "ignore-previous-rules"]])
        }
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: rules), as: UTF8.self)
        guard let store = WKContentRuleListStore.default(),
              let ruleList = try await store.compileContentRuleList(forIdentifier: "source-login-https-v2-" + String(allowLoopbackHTTP), encodedContentRuleList: encoded) else {
            throw SourceDomainError(.unavailable, "无法准备登录窗口的访问范围。")
        }
        try ensureOpen()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(ruleList)
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self; view.uiDelegate = self
        if let agent = request.value(forHTTPHeaderField: "User-Agent"), agent.lowercased() != "null" { view.customUserAgent = agent }
        view.allowsLinkPreview = false
        for cookie in cookies where credentialOrigins.contains(cookie.origin) {
            if let browserCookie = cookie.browserCookie() { await configuration.websiteDataStore.httpCookieStore.setCookie(browserCookie) }
            try ensureOpen()
        }
        try ensureOpen()
        webView = view; loading = true
        view.load(request)
    }
    func cookies() async throws -> [SourceCredentialCookie] {
        try ensureOpen()
        guard let webView, ready else { throw SourceDomainError(.unavailable, "请先等待登录页面载入。") }
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        try ensureOpen()
        guard ready else { throw SourceDomainError(.stale, "登录页面正在跳转，请载入后再保存。") }
        // Parent-domain and host cookies can collapse to one exact-origin key.
        // Keep the most specific domain, with host-only spelling first on a tie.
        let sorted = cookies.sorted {
            let a = $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let b = $1.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if a.count != b.count { return a.count > b.count }
            return !$0.domain.hasPrefix(".") && $1.domain.hasPrefix(".")
        }
        var values: [String: SourceCredentialCookie] = [:]
        for allowedOrigin in credentialOrigins.sorted() {
            for cookie in sorted {
                if let value = try SourceCredentialCookie.capture(cookie, origin: allowedOrigin) {
                    let key = allowedOrigin + "\n" + value.name + "\n" + value.path
                    if values[key] == nil { values[key] = value }
                }
            }
        }
        return values.keys.sorted().compactMap { values[$0] }
    }
    func close() {
        closed = true; ready = false; loading = false
        webView?.stopLoading()
        // Keep the rejecting delegates and resource rules on any view still retained by SwiftUI.
        webView?.removeFromSuperview()
        webView = nil
    }
    private func ensureOpen() throws {
        try Task.checkCancellation()
        guard !closed else { throw SourceDomainError(.stale, "登录窗口已关闭，请重新打开。") }
    }
    private func allowsNavigation(_ url: URL) -> Bool {
        guard let destination = SourceHostHTTPPolicy.origin(url) else { return false }
        return (try? SourceHostHTTPPolicy(origins: [destination], allowLoopbackHTTP: allowLoopbackHTTP).validate(url.absoluteString)) != nil
    }
    func reload() {
        guard !closed, let webView else { return }
        message = nil; ready = false; loading = true
        if webView.url == nil { webView.load(request) } else { webView.reload() }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let isLocalFrame = navigationAction.targetFrame?.isMainFrame == false &&
            ["about:blank", "about:srcdoc"].contains(navigationAction.request.url?.absoluteString ?? "")
        let allowed = !closed && !navigationAction.shouldPerformDownload &&
            (isLocalFrame || navigationAction.request.url.map(allowsNavigation) == true)
        if !allowed { message = "已停止不安全的跳转或下载，请使用 HTTPS 网站完成登录。" }
        decisionHandler(allowed ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        let allowed = !closed && navigationResponse.canShowMIMEType
            && navigationResponse.response.url.map { allowsNavigation($0) || (!navigationResponse.isForMainFrame && $0.scheme == "about") } == true
        if navigationResponse.isForMainFrame, allowed {
            currentOrigin = navigationResponse.response.url.flatMap(SourceHostHTTPPolicy.origin)
            if let response = navigationResponse.response as? HTTPURLResponse, response.statusCode >= 400 {
                message = "网站返回 HTTP \(response.statusCode)，可在网页内完成验证或刷新后重试。"
            }
        }
        decisionHandler(allowed ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { loading = true; ready = false; message = nil }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loading = false; ready = !closed }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    private func failed(_ error: Error) {
        guard (error as? URLError)?.code != .cancelled else { return }
        loading = false; ready = false
        message = "登录页未能载入，可点刷新重试（错误码 \((error as NSError).code)）。"
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ready = false; loading = false; message = "登录页面已停止，请关闭后重新打开。"
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if !closed, let url = navigationAction.request.url, allowsNavigation(url) { webView.load(navigationAction.request) }
        else { message = "已停止不安全的新窗口。" }
        return nil
    }
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
        decisionHandler(.deny)
    }
}

private struct NativeSourceLoginPage: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) { }
}

struct NativeSourceLoginView: View {
    @ObservedObject var model: NativeSourceLibrary
    let request: NativeSourceLoginRequest
    @StateObject private var browser: NativeSourceLoginBrowser
    @Environment(\.dismiss) private var dismiss
    @State private var busy = false
    @State private var feedback: String?
    @State private var discarding = false
    init(model: NativeSourceLibrary, request: NativeSourceLoginRequest) {
        self.model = model; self.request = request
        _browser = StateObject(wrappedValue: NativeSourceLoginBrowser(origin: request.origin, request: request.webRequest,
            credentialOrigins: request.context.session.allowedOrigins, allowLoopbackHTTP: model.allowsLoopbackHTTP))
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(browser.currentOrigin ?? request.origin).font(.footnote.monospaced()).textSelection(.enabled)
                    Text("在网站内登录或完成验证后点“保存登录”。仅为此书源保存已授权网站的 Cookie。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let message = feedback ?? browser.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                    if browser.loading || busy { ProgressView().accessibilityLabel("正在处理登录") }
                }.frame(maxWidth: .infinity, alignment: .leading).padding()
                Divider()
                if let webView = browser.webView { NativeSourceLoginPage(webView: webView).frame(maxWidth: .infinity, maxHeight: .infinity) }
                else { ContentUnavailableView("准备登录页面", systemImage: "person.crop.circle", description: Text(feedback ?? "正在建立临时登录窗口…")) }
            }
            .navigationTitle("网站登录").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { discarding = true }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) { Button("保存登录") { save() }.disabled(busy || !browser.ready) }
                ToolbarItem(placement: .bottomBar) { Button("刷新网页", systemImage: "arrow.clockwise") { browser.reload() }.frame(minWidth: 44, minHeight: 44).disabled(busy || browser.webView == nil) }
            }
            .interactiveDismissDisabled()
            .confirmationDialog("放弃此窗口的登录更改？", isPresented: $discarding, titleVisibility: .visible) {
                Button("放弃更改", role: .destructive) { browser.close(); dismiss() }
                Button("继续登录", role: .cancel) { }
            } message: { Text("此前保存在本机的登录凭据会保留；网站已执行的操作无法撤回。") }
            .task {
                do {
                    try await model.validateCredentialContext(request.context)
                    let cookies = try await model.credentials.browserCookies(session: request.context.session)
                    try await browser.prepare(cookies: cookies)
                } catch is CancellationError { }
                catch { feedback = error.localizedDescription }
            }
            .onDisappear { browser.close() }
        }
    }
    private func save() {
        busy = true; feedback = nil
        Task {
            defer { busy = false }
            do {
                let cookies = try await browser.cookies()
                try await model.saveLoginCookies(cookies, origins: request.context.session.allowedOrigins, context: request.context)
                browser.close(); dismiss()
            } catch { feedback = error.localizedDescription }
        }
    }
}
