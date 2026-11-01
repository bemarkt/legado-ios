@preconcurrency import WebKit
import SwiftUI
import UIKit

struct SourceLoginView: View {
    let source: BookSource
    @State private var reloadID = UUID()
    @State private var status = "打开登录页后，Cookie 会自动同步给搜索与阅读请求。"
    @State private var isChecking = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "lock.shield.fill").foregroundStyle(ReadingTheme.accent)
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                if isChecking { ProgressView().controlSize(.small) }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color(uiColor: .secondarySystemBackground))

            if let request = loginRequest {
                SourceLoginWebView(
                    request: request,
                    source: source,
                    sourceURL: source.bookSourceUrl,
                    sourceID: source.id,
                    loginCheckJavaScript: source.loginCheckJs,
                    reloadID: reloadID,
                    status: $status,
                    isChecking: $isChecking
                )
            } else {
                ReadingUnavailableView("登录地址无效", systemImage: "link.badge.plus", description: Text(source.loginUrl ?? "书源没有配置登录地址"))
            }
        }
        .navigationTitle("登录 · \(source.bookSourceName)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("重新载入", systemImage: "arrow.clockwise") { reloadID = UUID() }
            }
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

    private var sourceHeaders: [String: String] {
        guard let value = source.header,
              let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object.mapValues { String(describing: $0) }
    }
}

private struct SourceLoginWebView: UIViewRepresentable {
    let request: URLRequest
    /// 登录检测脚本要在书源 JS 环境里执行（需要 source 上下文），因此整个书源一并传入。
    let source: BookSource
    let sourceURL: String
    let sourceID: String
    let loginCheckJavaScript: String?
    let reloadID: UUID
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
        webView.navigationDelegate = context.coordinator
        context.coordinator.installExistingCookies(in: webView) { webView.load(request) }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        guard context.coordinator.lastReloadID != reloadID else { return }
        context.coordinator.lastReloadID = reloadID
        webView.reload()
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: SourceLoginWebView
        var lastReloadID: UUID

        init(parent: SourceLoginWebView) {
            self.parent = parent
            lastReloadID = parent.reloadID
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation?) {
            parent.status = "正在打开登录页…"
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
            parent.status = "登录页加载失败：\(error.localizedDescription)"
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation?, withError error: Error) {
            parent.status = "登录页加载失败：\(error.localizedDescription)"
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
