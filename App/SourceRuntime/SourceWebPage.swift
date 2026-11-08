import Foundation
import WebKit

/// One-shot page. Native deadlines end the operation, not the WebContent process.
/// Discarding a WKWebView is not a proven hard kill for synchronous JavaScript.
@MainActor
final class SourceWebPage: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    private var continuation: CheckedContinuation<String, Error>?
    private var timer: Task<Void, Never>?
    private var body = ""
    private var arguments: [String: Any] = [:]
    private var executionTimeoutMs = 0
    private var executionTimeoutCode = "TIMEOUT"
    private var started = false
    private var finished = false
    var onClose: (() -> Void)?

    init(script: String, bridge: (any WKScriptMessageHandlerWithReply)? = nil) throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.addUserScript(WKUserScript(
            source: script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if let bridge {
            configuration.userContentController.addScriptMessageHandler(bridge, contentWorld: .page, name: "sourceHost")
        }
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
    }

    func perform(_ body: String, arguments: [String: Any], timeoutMs: Int, timeoutCode: String = "TIMEOUT") async throws -> String {
        guard !started else { throw SourceFailure(code: "HOST_ERROR", message: "Execution pages cannot be reused") }
        started = true
        self.body = body
        self.arguments = arguments
        executionTimeoutMs = timeoutMs
        executionTimeoutCode = timeoutCode
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                // Cold WebContent startup is distinct from parser/module execution time.
                resetDeadline(milliseconds: 15_000, code: "HOST_TIMEOUT")
                // No remote document, inline author script, forms, subframes, workers or direct networking.
                // User scripts are bundled host code. The only author module is an in-memory blob.
                webView.loadHTMLString("""
                <!doctype html><html><head><meta http-equiv="Content-Security-Policy"
                content="default-src 'none'; script-src blob:; connect-src 'none'; img-src 'none';
                style-src 'none'; frame-src 'none'; child-src 'none'; worker-src 'none';
                object-src 'none'; media-src 'none'; font-src 'none'; base-uri 'none'; form-action 'none'">
                </head><body></body></html>
                """, baseURL: nil)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.close(.failure(SourceFailure(code: "CANCELLED", message: "Operation cancelled"))) }
        }
    }

    func resetDeadline(milliseconds: Int, code: String = "TIMEOUT") {
        timer?.cancel()
        timer = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(milliseconds)) } catch { return }
            self?.close(.failure(SourceFailure(code: code, message: "Native deadline exceeded")))
        }
    }

    private func close(_ result: Result<String, Error>) {
        guard !finished else { return }
        finished = true
        timer?.cancel()
        timer = nil
        onClose?()
        onClose = nil
        webView.stopLoading()
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
        webView.configuration.userContentController.removeAllUserScripts()
        webView.navigationDelegate = nil
        webView.removeFromSuperview()
        arguments = [:]
        body = ""
        let pending = continuation
        continuation = nil
        pending?.resume(with: result)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !finished else { return }
        resetDeadline(milliseconds: executionTimeoutMs, code: executionTimeoutCode)
        webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .page) { [weak self] result in
            guard let self, !self.finished else { return }
            switch result {
            case .success(let value):
                guard let json = value as? String else {
                    self.close(.failure(SourceFailure(code: "INVALID_DATA", message: "Runtime result must be JSON text")))
                    return
                }
                self.close(.success(json))
            case .failure(let error):
                self.close(.failure(SourceFailure(code: "SCRIPT_ERROR", message: error.localizedDescription)))
            }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Only the host's initial blank document may navigate. This also rejects new-window requests.
        decisionHandler(!finished && navigationAction.request.url?.absoluteString == "about:blank"
                        && navigationAction.targetFrame?.isMainFrame == true ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        close(.failure(SourceFailure(code: "HOST_ERROR", message: error.localizedDescription)))
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        close(.failure(SourceFailure(code: "HOST_ERROR", message: error.localizedDescription)))
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        close(.failure(SourceFailure(code: "RUNTIME_TERMINATED", message: "WebContent process terminated")))
    }
}
