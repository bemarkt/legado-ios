import SwiftUI
import WebKit

/// A separate, temporary website session. It never hosts source author code or a sourceHost bridge.
@MainActor
final class NativeSourceLoginBrowser: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    @Published private(set) var webView: WKWebView?
    @Published private(set) var ready = false
    @Published private(set) var loading = false
    @Published private(set) var message: String?
    let origin: String
    private let policy: SourceHostHTTPPolicy
    private var started = false
    private var closed = false
    init(origin: String, allowLoopbackHTTP: Bool = false) {
        self.origin = origin
        policy = .init(origins: [origin], allowLoopbackHTTP: allowLoopbackHTTP)
        super.init()
    }
    func prepare(cookies: [SourceCredentialCookie]) async throws {
        guard !started, !closed else { throw SourceDomainError(.stale, "登录窗口已关闭，请重新打开。") }
        started = true
        let url = try policy.validate(origin + "/")
        guard SourceHostHTTPPolicy.origin(url) == origin else { throw SourceDomainError(.invalidInput, "无效的登录网站。") }
        let scheme = url.scheme!, host = url.host!
        let defaultPort = scheme == "https" ? 443 : 80
        let port = url.port.map { ":\($0)" } ?? "(:\(defaultPort))?"
        let pattern = "^" + scheme + "://" + NSRegularExpression.escapedPattern(for: host) + port + "/"
        let rules: [[String: Any]] = [
            ["trigger": ["url-filter": ".*"], "action": ["type": "block"]],
            ["trigger": ["url-filter": pattern], "action": ["type": "ignore-previous-rules"]]
        ]
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: rules), as: UTF8.self)
        guard let store = WKContentRuleListStore.default(),
              let ruleList = try await store.compileContentRuleList(forIdentifier: "source-login-" + SourceCoding.digest(Data(origin.utf8)), encodedContentRuleList: encoded) else {
            throw SourceDomainError(.unavailable, "无法准备登录窗口的访问范围。")
        }
        try ensureOpen()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.add(ruleList)
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self; view.uiDelegate = self
        view.allowsLinkPreview = false
        for cookie in cookies where cookie.origin == origin {
            if let browserCookie = cookie.browserCookie() { await configuration.websiteDataStore.httpCookieStore.setCookie(browserCookie) }
            try ensureOpen()
        }
        try ensureOpen()
        webView = view; loading = true
        view.load(URLRequest(url: url))
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
        for cookie in sorted {
            if let value = try SourceCredentialCookie.capture(cookie, origin: origin) {
                let key = value.name + "\n" + value.path
                if values[key] == nil { values[key] = value }
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
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        let allowed = !closed && navigationAction.targetFrame != nil && !navigationAction.shouldPerformDownload
            && navigationAction.request.url.map { (try? policy.validate($0.absoluteString)) != nil } == true
        if !allowed { message = "此窗口只支持当前网站，其他网站、新窗口及下载已停止。" }
        decisionHandler(allowed ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationResponsePolicy) -> Void) {
        let allowed = !closed && navigationResponse.canShowMIMEType
            && navigationResponse.response.url.map { (try? policy.validate($0.absoluteString)) != nil } == true
        decisionHandler(allowed ? .allow : .cancel)
    }
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { loading = true; ready = false }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loading = false; ready = !closed }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    private func failed(_ error: Error) {
        loading = false
        if (error as? URLError)?.code != .cancelled { message = "登录页未能载入。请检查网络或重新打开。" }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ready = false; loading = false; message = "登录页面已停止，请关闭后重新打开。"
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        message = "此登录窗口不支持打开新窗口。"; return nil
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
        _browser = StateObject(wrappedValue: NativeSourceLoginBrowser(origin: request.origin))
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(request.origin).font(.footnote.monospaced()).textSelection(.enabled)
                    Text("登录完成后点“保存登录”。此窗口暂不支持跳转到其他网站登录。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if let message = feedback ?? browser.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
                    if browser.loading || busy { ProgressView().accessibilityLabel("正在处理登录") }
                }.frame(maxWidth: .infinity, alignment: .leading).padding()
                Divider()
                if let webView = browser.webView { NativeSourceLoginPage(webView: webView) }
                else { ContentUnavailableView("准备登录页面", systemImage: "person.crop.circle", description: Text(feedback ?? "正在建立临时登录窗口…")) }
            }
            .navigationTitle("网站登录").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { discarding = true }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) { Button("保存登录") { save() }.disabled(busy || !browser.ready) }
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
                try await model.saveLoginCookies(cookies, origin: request.origin, context: request.context)
                browser.close(); dismiss()
            } catch { feedback = error.localizedDescription }
        }
    }
}
