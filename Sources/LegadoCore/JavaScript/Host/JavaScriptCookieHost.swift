import Foundation
import CQuickJS

/// Cookie 宿主层：把既有 `LegadoCookieStore` 暴露给书源脚本。
///
/// 迁移要点：JSC 版把 `@convention(block)` 直接挂到 `cookie` 对象上，
/// QuickJS 侧改为 host function + 一层 JS 胶水（`RhinoCompatibilityScripts.cookieBridge`），
/// 但**对外形状必须一模一样**：书源脚本里写的是
/// `cookie.getCookie(url)` / `cookie.setCookie(url, v)` / `cookie.cookieToMap(header)`，
/// 形状一变就是全量书源失效，不是「风格差异」。
struct JavaScriptCookieHost {
    let cookies: any JavaScriptCookieState
    func install(into context: QuickJSContext) {
        // `java.getCookieHeader` / `java.__getCookieValue` / `java.setCookie`
        // 是 `java.getCookie(...)` 胶水的底层实现，必须先注册，否则胶水里调用不到。
        context.defineFunction("__legadoGetCookieHeader", argumentCount: 1) { ctx, _, args in
            let url = args.first.map { JavaScriptByteCoding.text(from: $0, in: ctx) } ?? ""
            let header = try cookies.cookieHeader(for: url)
            return QuickJSValueConverter.stringValue(header, in: ctx)
        }

        context.defineFunction("__legadoGetCookieValue", argumentCount: 2) { ctx, _, args in
            guard args.count == 2 else { return QuickJSValueConverter.stringValue("", in: ctx) }
            let url = JavaScriptByteCoding.text(from: args[0], in: ctx)
            let key = JavaScriptByteCoding.text(from: args[1], in: ctx)
            return QuickJSValueConverter.stringValue(try cookies.cookie(for: url, key: key), in: ctx)
        }

        context.defineFunction("__legadoSetCookie", argumentCount: 2) { ctx, _, args in
            guard args.count == 2 else { return qjs_undefined() }
            let url = JavaScriptByteCoding.text(from: args[0], in: ctx)
            let value = JavaScriptByteCoding.text(from: args[1], in: ctx)
            try cookies.setCookie(value, for: url)
            return qjs_undefined()
        }

        context.defineFunction("__legadoRemoveCookie", argumentCount: 1) { ctx, _, args in
            guard let first = args.first else { return qjs_undefined() }
            try cookies.removeCookies(for: JavaScriptByteCoding.text(from: first, in: ctx))
            return qjs_undefined()
        }

        // `cookie` 全局对象：直接建空对象，再在下面的脚本里挂方法。
        // 早期版本先用 `.bool(true)` 造占位属性再覆盖，那只是为了让
        // `typeof cookie === 'object'` 成立；空对象天然满足这一点，
        // 少一层占位就没有「占位与真实实现分叉」的可能。
        let object = JS_NewObject(context.rawContext)
        context.setGlobal("cookie", value: object)

        injectCookieObjectScript(into: context)
    }

    /// 把 `cookie` 对象的方法绑到宿主函数上。
    ///
    /// 这段脚本必须在 `__legadoGetCookieHeader` 等函数注册之后执行，
    /// 否则脚本里引用到的是 undefined，调用时抛 `not a function`——
    /// 这类错误在书源侧表现成「登录态拿不到」，很难从诊断里看出来。
    private func injectCookieObjectScript(into context: QuickJSContext) {
        let script = #"""
            (function () {
              cookie.getCookie = function (url) { return __legadoGetCookieHeader(String(url)); };
              cookie.getKey = function (url, key) { return __legadoGetCookieValue(String(url), String(key)); };
              cookie.setCookie = function (url, value) { __legadoSetCookie(String(url), String(value)); };
              cookie.replaceCookie = cookie.setCookie;
              cookie.setWebCookie = cookie.setCookie;
              cookie.removeCookie = function (url) { __legadoRemoveCookie(String(url)); };
            })();
            """#
        _ = try? context.evaluate(script, filename: "cookie-bridge.js")
    }
}
