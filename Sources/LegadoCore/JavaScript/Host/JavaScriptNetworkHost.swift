import Foundation
import CQuickJS

/// 网络宿主层：`java.ajax` / `java.ajaxAll` / `java.connect` / `java.__directRequest`。
///
/// 闭包层次刻意抬到与书源语义同高，而不是「构造裸 URLRequest + 执行」：
/// `java.ajax` 的入参可以是 `/api?page=2,{"method":"POST","charset":"gb18030","retry":1,"bodyJs":"..."}`，
/// 这些选项由 `LegadoURLBuilder.prepare` 解析，决定编码、重试与响应体的二次 JS 变换。
/// 用裸 URLRequest 表达不了，宿主层若自行实现一遍 URL 解析，就会与既有实现慢慢分叉。
///
/// 因此这里只做「JS 值 ↔ 结构化请求」的翻译：
/// - `loadAjax` 对应既有 `loadJavaScriptRequest`（prepare / 重试 / charset / bodyJs）；
/// - `loadDirect` 对应既有 `loadDirectJavaScriptRequest`（`java.get/head/post`，
///   仅基址解析 + 请求头 + 超时，不解析 js 选项——这与 JSC 版行为一致，不能顺手统一）。
///
/// 同步语义保持不变（迁移指南第五节明确要求）：不改成 Promise。
/// 书源脚本是同步写法，改成 Promise 会让所有依赖返回值的规则一次性失效。
struct JavaScriptNetworkHost {
    typealias AjaxLoader = (_ rawURL: String, _ extraHeaders: [String: String], _ timeoutMilliseconds: Double?) throws -> HTTPResponse
    typealias DirectLoader = (_ method: String, _ rawURL: String, _ body: String?, _ headers: [String: String], _ timeoutMilliseconds: Double?) throws -> HTTPResponse

    let loadAjax: AjaxLoader
    let loadDirect: DirectLoader
    let maximumResultBytes: Int
    let propagateFailures: Bool

    func install(into context: QuickJSContext) {
        let loadAjax = self.loadAjax
        let loadDirect = self.loadDirect
        let resultLimit = self.maximumResultBytes

        // `java.get/head/post(...)` 返回结构化对象而不是字符串，
        // 因为书源高频使用 `.statusCode()` / `.header(name)` / `.body()`。
        context.defineFunction("__legadoDirectRequest", argumentCount: 5) { ctx, _, args in
            guard args.count >= 2 else { return Self.errorObject("java.get/post 参数不足", in: ctx) }
            let method = JavaScriptByteCoding.text(from: args[0], in: ctx).uppercased()
            let rawURL = JavaScriptByteCoding.text(from: args[1], in: ctx)
            let body = args.count > 2 ? JavaScriptByteCoding.text(from: args[2], in: ctx) : nil
            let headers = args.count > 3 ? Self.headerMap(from: args[3], in: ctx) : [:]
            let timeout = args.count > 4 ? Self.optionalNumber(from: args[4], in: ctx) : nil

            do {
                let response = try loadDirect(
                    method.isEmpty ? "GET" : method,
                    rawURL,
                    body,
                    headers,
                    timeout
                )
                return Self.responseObject(response, limit: resultLimit, in: ctx)
            } catch {
                if propagateFailures { throw error }
                return Self.errorObject(error.localizedDescription, in: ctx)
            }
        }

        // `java.ajax(url, timeout)` 返回正文文本而不是对象：
        // 书源里 `java.ajax(...)` 直接当 HTML 用，返回对象会让 `.indexOf(...)` 全部失效。
        context.defineFunction("__legadoAjax", argumentCount: 2) { ctx, _, args in
            guard let first = args.first else { return QuickJSValueConverter.stringValue("", in: ctx) }
            let rawURL = JavaScriptByteCoding.text(from: first, in: ctx)
            let timeout = args.count > 1 ? Self.optionalNumber(from: args[1], in: ctx) : nil
            do {
                let response = try loadAjax(rawURL, [:], timeout)
                return QuickJSValueConverter.stringValue(response.decodedText, in: ctx)
            } catch {
                if propagateFailures { throw error }
                // Only old application entry points retain their historical text fallback.
                return QuickJSValueConverter.stringValue(error.localizedDescription, in: ctx)
            }
        }

        // `java.ajaxAll(urls, timeout)` 按输入顺序返回结果对象数组，
        // 失败位保留占位而不是丢弃，否则书源按索引对齐时会整体错位。
        context.defineFunction("__legadoAjaxAll", argumentCount: 2) { ctx, _, args in
            let urls = args.first.map { Self.urlList(from: $0, in: ctx) } ?? []
            let timeout = args.count > 1 ? Self.optionalNumber(from: args[1], in: ctx) : nil
            var rows: [JSONValue] = []
            rows.reserveCapacity(urls.count)
            for rawURL in urls {
                do {
                    let response = try loadAjax(rawURL, [:], timeout)
                    rows.append(.object([
                        "url": .string(response.finalURL.absoluteString),
                        "body": .string(response.decodedText),
                        "code": .number(Double(response.statusCode)),
                        "headers": .object(response.headers.mapValues { .string($0) })
                    ]))
                } catch {
                    if propagateFailures { throw error }
                    rows.append(.object([
                        "url": .string(rawURL),
                        "body": .string(""),
                        "code": .number(0),
                        "headers": .object([:])
                    ]))
                }
            }
            return QuickJSValueConverter.value(from: .array(rows), in: ctx)
        }

        // `java.connect(url, headers, timeout)` 返回带 successful / message / callTime 的对象。
        context.defineFunction("__legadoConnect", argumentCount: 3) { ctx, _, args in
            guard let first = args.first else { return Self.errorObject("java.connect 参数不足", in: ctx) }
            let rawURL = JavaScriptByteCoding.text(from: first, in: ctx)
            let headers = args.count > 1 ? Self.headerMap(from: args[1], in: ctx) : [:]
            let timeout = args.count > 2 ? Self.optionalNumber(from: args[2], in: ctx) : nil
            do {
                let response = try loadAjax(rawURL, headers, timeout)
                return QuickJSValueConverter.value(from: .object([
                    "url": .string(response.finalURL.absoluteString),
                    "body": .string(response.decodedText),
                    "code": .number(Double(response.statusCode)),
                    "message": .string(HTTPURLResponse.localizedString(forStatusCode: response.statusCode)),
                    "headers": .object(response.headers.mapValues { .string($0) }),
                    "successful": .bool((200...299).contains(response.statusCode)),
                    "callTime": .number(0)
                ]), in: ctx)
            } catch {
                if propagateFailures { throw error }
                return QuickJSValueConverter.value(from: .object([
                    "url": .string(rawURL),
                    "body": .string(error.localizedDescription),
                    "code": .number(0),
                    "message": .string(error.localizedDescription),
                    "headers": .object([:]),
                    "successful": .bool(false),
                    "callTime": .number(0)
                ]), in: ctx)
            }
        }
    }

    // MARK: - 值转换辅助

    /// JS 对象 → 头字典。非对象入参一律当空字典，
    /// 因为书源常写 `java.get(url, null)`，把 null 当错误会让正常请求失败。
    private static func headerMap(from value: JSValue, in context: QuickJSContext) -> [String: String] {
        guard qjs_is_object(value) else { return [:] }
        guard case .object(let members) = context.jsonValue(from: value) else { return [:] }
        return members.mapValues { $0.stringValue }
    }

    /// JS 数组 → URL 列表；单值入参当单元素列表。
    private static func urlList(from value: JSValue, in context: QuickJSContext) -> [String] {
        if qjs_is_array(value), case .array(let items) = context.jsonValue(from: value) {
            return items.map(\.stringValue)
        }
        return [JavaScriptByteCoding.text(from: value, in: context)]
    }

    /// 超时入参可能是 number、undefined、null 或字符串数字，统一收敛成可选 Double。
    private static func optionalNumber(from value: JSValue, in context: QuickJSContext) -> Double? {
        if qjs_is_null(value) || qjs_is_undefined(value) { return nil }
        if qjs_is_number(value) {
            var ok = false
            let number = qjs_to_double(context.rawContext, value, &ok)
            return ok ? number : nil
        }
        return Double(JavaScriptByteCoding.text(from: value, in: context))
    }

    /// 直接请求成功：字段名与 JSC 版逐字一致（urlText / bodyText / code / headers）。
    /// JS 胶水层 `responseOf()` 依赖这四个名字，改名等于全量破坏。
    private static func responseObject(_ response: HTTPResponse, limit: Int, in context: QuickJSContext) -> JSValue {
        let body = response.decodedText
        guard body.utf8.count <= limit else {
            return errorObject("响应正文超过长度上限", in: context)
        }
        return QuickJSValueConverter.value(from: .object([
            "urlText": .string(response.finalURL.absoluteString),
            "bodyText": .string(body),
            "code": .number(Double(response.statusCode)),
            "headers": .object(response.headers.mapValues { .string($0) })
        ]), in: context)
    }

    private static func errorObject(_ message: String, in context: QuickJSContext) -> JSValue {
        QuickJSValueConverter.value(from: .object(["error": .string(message)]), in: context)
    }
}
