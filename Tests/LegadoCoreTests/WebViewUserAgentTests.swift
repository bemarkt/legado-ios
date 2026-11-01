import Foundation
import Testing
@testable import LegadoCore

/// WebView 链路的 User-Agent 解析回归测试。
///
/// 背景：WebKit 会丢弃 `URLRequest` 上的 `User-Agent`，只认
/// `WKWebView.customUserAgent`。书源 header 与「设置 - 网络与缓存」两条 UA
/// 入口都必须经过 `BookSourceHeaderResolver` 取值，否则实际发出的是系统默认串
/// （`... Mobile/15E148`），用户看到的就是「设了 UA 却无效」。
struct WebViewUserAgentTests {

    @Test func sourceHeaderUserAgentOverridesGlobalSetting() {
        let resolved = BookSourceHeaderResolver.userAgent(
            in: ["user-agent": "Source UA"],
            global: "Global UA"
        )
        #expect(resolved == "Source UA")
    }

    @Test func fallsBackToGlobalSettingWhenHeaderHasNoUserAgent() {
        #expect(BookSourceHeaderResolver.userAgent(in: [:], global: "Global UA") == "Global UA")
    }

    /// `"User-Agent": "null"` 在书源里是「禁用默认 UA」，不能被当成真实 UA 发出去。
    @Test func nullUserAgentSuppressesInsteadOfSendingLiteralNull() {
        #expect(BookSourceHeaderResolver.userAgent(in: ["User-Agent": "null"], global: "Global UA") == nil)
        #expect(BookSourceHeaderResolver.userAgent(in: ["User-Agent": "  "], global: "Global UA") == "Global UA")
    }

    @Test func preparedRequestCarriesSourceUserAgentIntoWebView() throws {
        let prepared = try LegadoURLBuilder().prepare(#"https://ua.test/,{headers:{'User-Agent':'Source UA'}}"#)
        #expect(BookSourceHeaderResolver().webViewUserAgent(prepared) == "Source UA")
    }

    @Test func preparedRequestHonorsSuppressedUserAgent() throws {
        let prepared = try LegadoURLBuilder().prepare(#"https://ua.test/,{headers:{'User-Agent':'null'}}"#)
        #expect(prepared.suppressesUserAgent)
        #expect(BookSourceHeaderResolver().webViewUserAgent(prepared) == nil)
    }

    /// 登录页只拿得到书源（没有 `PreparedRequest`），走这个重载。
    /// 登录界面此前完全没设 `customUserAgent`，所以抓包拿到的是系统默认串。
    @Test func sourceLevelUserAgentFeedsTheLoginWebView() {
        var source = BookSource(bookSourceUrl: "https://login-ua.test", bookSourceName: "登录 UA")
        source.header = #"{"User-Agent":"Source UA"}"#
        #expect(BookSourceHeaderResolver().webViewUserAgent(for: source) == "Source UA")
    }

    /// 书源 header 可以是 `@js:` 动态生成的。旧登录页用裸 `JSONSerialization` 解析，
    /// 这类头会退回空字典，登录页于是丢掉全部自定义头而不只是 UA。
    @Test func dynamicHeaderUserAgentIsResolvedForTheLoginWebView() {
        var source = BookSource(bookSourceUrl: "https://login-js-ua.test", bookSourceName: "动态 UA")
        source.header = #"@js:JSON.stringify({'User-Agent':'JS UA'})"#
        #expect(BookSourceHeaderResolver().webViewUserAgent(for: source) == "JS UA")
    }
}
