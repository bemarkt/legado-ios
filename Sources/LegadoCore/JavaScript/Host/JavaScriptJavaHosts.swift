import Foundation
import CQuickJS

/// `java.*` 宿主对象。
///
/// 与 JSC 版的差别只有一处：`@convention(block)` 换成 QuickJS host function。
/// 函数名、返回形状、双义 `java.get` 的重载规则全部原样保留——书源里
/// `java.get('k')` 取变量与 `java.get('https://…')` 发请求是同一个名字，
/// 拆成两个函数就是全量书源失效。
///
/// 挂载顺序有硬约束：本体必须在 `RhinoCompatibilityScripts.javaBridge` 之前注入，
/// 因为那段胶水要用 `var getVariable = java.get;` 先把原始取值器捕获下来，
/// 再覆盖成「取变量或发请求」的双义版本。
struct JavaScriptJavaHosts {
    /// 内容入参用 `JSONValue` 而不是 `JSValue`：闭包内部要再起一次求值，
    /// 可能落在另一个 Context，把某个 Context 的 `JSValue` 传出去再使用
    /// 在 QuickJS 下属于未定义行为，因此在宿主函数内当场收敛成值类型。
    typealias StringRuleEvaluator = (_ rule: String, _ content: JSONValue?, _ isURL: Bool) throws -> String

    /// 列表模式求值器。`java.getStringList` 不能对 `java.getString` 的结果按换行切分，
    /// 必须回到规则引擎走一遍真正的列表模式解析。
    typealias StringRuleListEvaluator = (_ rule: String, _ content: JSONValue?, _ isURL: Bool) throws -> [String]

    let variables: JavaScriptVariableBox
    let executionContext: RuleExecutionContext
    let byteLimit: Int
    let evaluateStringRule: StringRuleEvaluator
    let evaluateStringListRule: StringRuleListEvaluator

    func install(into context: QuickJSContext) {
        let object = JS_NewObject(context.rawContext)
        let environment = executionContext.hostEnvironment

        // MARK: 变量存储

        // `java.get('bookName')` / `java.get('title')` 是书源取当前书名与章节名的固定写法，
        // 其优先级高于同名规则变量；顺序反了会让用户变量把书名顶掉。
        context.setProperty("get", on: object, value: context.makeFunction(argumentCount: 1) { ctx, _, args in
            let key = args.first.map { JavaScriptByteCoding.text(from: $0, in: ctx) } ?? ""
            if key == "bookName", let book = executionContext.book {
                return QuickJSValueConverter.stringValue(book.name, in: ctx)
            }
            if key == "title", let chapter = executionContext.chapter {
                return QuickJSValueConverter.stringValue(chapter.title, in: ctx)
            }
            return QuickJSValueConverter.stringValue(variables.get(key), in: ctx)
        })

        context.setProperty("put", on: object, value: context.makeFunction(argumentCount: 2) { ctx, _, args in
            guard args.count == 2 else { return QuickJSValueConverter.stringValue("", in: ctx) }
            let key = JavaScriptByteCoding.text(from: args[0], in: ctx)
            let value = JavaScriptByteCoding.text(from: args[1], in: ctx)
            variables.put(key, value)
            return QuickJSValueConverter.stringValue(value, in: ctx)
        })

        // `java.putVolume(name)` 把卷名追加到 `__legadoVolumes`，目录解析依赖这个顺序。
        context.setProperty("putVolume", on: object, value: context.makeFunction(argumentCount: 1) { ctx, _, args in
            let title = args.first.map { JavaScriptByteCoding.text(from: $0, in: ctx) } ?? ""
            let existing = variables.get("__legadoVolumes")
            var volumes = (try? JSONDecoder().decode([String].self, from: Data(existing.utf8))) ?? []
            volumes.append(title)
            if let data = try? JSONEncoder().encode(volumes) {
                variables.put("__legadoVolumes", String(decoding: data, as: UTF8.self))
            }
            return QuickJSValueConverter.stringValue(title, in: ctx)
        })

        // MARK: 规则二次求值

        // `java.getString(rule, content, isUrl)` 会回到 Swift 侧再走一遍规则解析，
        // 可能涉及嵌套 `@js`，因此由外部注入闭包，而不是在这里自建求值器。
        context.setProperty("__getString", on: object, value: context.makeFunction(argumentCount: 3) { ctx, _, args in
            guard let first = args.first else { return QuickJSValueConverter.stringValue("", in: ctx) }
            let rule = JavaScriptByteCoding.text(from: first, in: ctx)
            let content: JSONValue? = args.count > 1 ? ctx.jsonValue(from: args[1]) : nil
            let isURL = args.count > 2 ? qjs_to_bool(ctx.rawContext, args[2]) == 1 : false
            let text = try evaluateStringRule(rule, content, isURL)
            return QuickJSValueConverter.stringValue(text, in: ctx)
        })

        context.setProperty("__getStringList", on: object, value: context.makeFunction(argumentCount: 3) { ctx, _, args in
            guard let first = args.first else {
                // 显式给出元素类型：`.array([])` 的空字面量在跨桥推断时容易变成
                // "type of expression is ambiguous without a type annotation"。
                return QuickJSValueConverter.value(from: .array([JSONValue]()), in: ctx)
            }
            let rule = JavaScriptByteCoding.text(from: first, in: ctx)
            let content: JSONValue? = args.count > 1 ? ctx.jsonValue(from: args[1]) : nil
            let isURL = args.count > 2 ? qjs_to_bool(ctx.rawContext, args[2]) == 1 : false
            let values = try evaluateStringListRule(rule, content, isURL)
            // 显式写 JSONValue.string：省略类型名的 `.string($0)` 依赖上下文推断，
            // 在 `value(from:)` 这座桥里是编译期歧义的高发点。
            let items: [JSONValue] = values.map { JSONValue.string($0) }
            return QuickJSValueConverter.value(from: .array(items), in: ctx)
        })

        // MARK: 编码与字节

        context.setProperty("md5Encode", on: object, value: context.makeFunction(argumentCount: 1) { ctx, _, args in
            let text = args.first.map { JavaScriptByteCoding.text(from: $0, in: ctx) } ?? ""
            return QuickJSValueConverter.stringValue(JavaScriptCryptoBridge.md5(text), in: ctx)
        })

        context.setProperty("base64Encode", on: object, value: context.makeFunction(argumentCount: 1) { ctx, _, args in
            let text = args.first.map { JavaScriptByteCoding.text(from: $0, in: ctx) } ?? ""
            return QuickJSValueConverter.stringValue(JavaScriptCryptoBridge.base64Encode(Data(text.utf8)), in: ctx)
        })

        context.setProperty("base64Decode", on: object, value: context.makeFunction(argumentCount: 1) { ctx, _, args in
            let text = args.first.map { JavaScriptByteCoding.text(from: $0, in: ctx) } ?? ""
            let data = JavaScriptCryptoBridge.base64Decode(text) ?? Data()
            return QuickJSValueConverter.stringValue(String(decoding: data, as: UTF8.self), in: ctx)
        })

        context.setProperty("base64DecodeToByteArray", on: object, value: context.makeFunction(argumentCount: 1) { ctx, _, args in
            let text = args.first.map { JavaScriptByteCoding.text(from: $0, in: ctx) } ?? ""
            let data = JavaScriptCryptoBridge.base64Decode(text) ?? Data()
            return JavaScriptByteCoding.value(for: data, in: ctx)
        })

        context.setProperty("strToBytes", on: object, value: context.makeFunction(argumentCount: 1) { ctx, _, args in
            let text = args.first.map { JavaScriptByteCoding.text(from: $0, in: ctx) } ?? ""
            return JavaScriptByteCoding.value(for: Data(text.utf8), in: ctx)
        })

        context.setProperty("bytesToStr", on: object, value: context.makeFunction(argumentCount: 1) { ctx, _, args in
            let data = args.first.flatMap {
                JavaScriptByteCoding.data(from: $0, in: ctx, limit: byteLimit)
            } ?? Data()
            return QuickJSValueConverter.stringValue(String(decoding: data, as: UTF8.self), in: ctx)
        })

        context.setProperty("hexDecodeToByteArray", on: object, value: context.makeFunction(argumentCount: 1) { ctx, _, args in
            let text = args.first.map { JavaScriptByteCoding.text(from: $0, in: ctx) } ?? ""
            return JavaScriptByteCoding.value(for: JavaScriptCryptoBridge.hexDecode(text), in: ctx)
        })

        context.setProperty("hexDecodeToString", on: object, value: context.makeFunction(argumentCount: 1) { ctx, _, args in
            let text = args.first.map { JavaScriptByteCoding.text(from: $0, in: ctx) } ?? ""
            let data = JavaScriptCryptoBridge.hexDecode(text)
            return QuickJSValueConverter.stringValue(String(decoding: data, as: UTF8.self), in: ctx)
        })

        // 小写：`java.hexEncodeToString` 与 `DatatypeConverter.printHexBinary`（大写）
        // 是两个不同行为，不能共用一个格式化函数。
        context.setProperty("hexEncodeToString", on: object, value: context.makeFunction(argumentCount: 1) { ctx, _, args in
            let text = args.first.map { JavaScriptByteCoding.text(from: $0, in: ctx) } ?? ""
            return QuickJSValueConverter.stringValue(
                JavaScriptCryptoBridge.hexEncode(Data(text.utf8), uppercase: false),
                in: ctx
            )
        })

        context.setProperty("encodeURI", on: object, value: context.makeFunction(argumentCount: 1) { ctx, _, args in
            let text = args.first.map { JavaScriptByteCoding.text(from: $0, in: ctx) } ?? ""
            return QuickJSValueConverter.stringValue(JavaScriptCryptoBridge.formURLEncode(text), in: ctx)
        })

        // MARK: 时间与标识

        context.setProperty("timeFormatUTC", on: object, value: context.makeFunction(argumentCount: 3) { ctx, _, args in
            var millisecondsOK = false
            let milliseconds = args.first.map { qjs_to_double(ctx.rawContext, $0, &millisecondsOK) } ?? 0
            let format = args.count > 1 ? JavaScriptByteCoding.text(from: args[1], in: ctx) : "yyyy/MM/dd HH:mm"
            var offsetOK = false
            let offset = args.count > 2 ? qjs_to_double(ctx.rawContext, args[2], &offsetOK) : 0
            let formatter = DateFormatter()
            formatter.locale = Locale.current
            formatter.timeZone = TimeZone(secondsFromGMT: offsetOK ? Int(offset) / 1_000 : 0)
            formatter.dateFormat = format.isEmpty ? "yyyy/MM/dd HH:mm" : format
            let date = Date(timeIntervalSince1970: (millisecondsOK ? milliseconds : 0) / 1_000)
            return QuickJSValueConverter.stringValue(formatter.string(from: date), in: ctx)
        })

        context.setProperty("timeFormat", on: object, value: context.makeFunction(argumentCount: 1) { ctx, _, args in
            var ok = false
            let milliseconds = args.first.map { qjs_to_double(ctx.rawContext, $0, &ok) } ?? 0
            let formatter = DateFormatter()
            formatter.locale = Locale.current
            formatter.dateFormat = "yyyy/MM/dd HH:mm"
            let date = Date(timeIntervalSince1970: (ok ? milliseconds : 0) / 1_000)
            return QuickJSValueConverter.stringValue(formatter.string(from: date), in: ctx)
        })

        context.setProperty("randomUUID", on: object, value: context.makeFunction { ctx, _, _ in
            QuickJSValueConverter.stringValue(UUID().uuidString, in: ctx)
        })

        // Identity, browser behavior and logging belong to the selected host environment.
        context.setProperty("androidId", on: object, value: context.makeFunction { ctx, _, _ in
            QuickJSValueConverter.stringValue(try environment.identifier(), in: ctx)
        })
        context.setProperty("webView", on: object, value: context.makeFunction(argumentCount: 3) { ctx, _, args in
            let html = args.first.map { JavaScriptByteCoding.text(from: $0, in: ctx) } ?? ""
            return QuickJSValueConverter.stringValue(try environment.renderWebPage(html), in: ctx)
        })
        context.setProperty("startBrowser", on: object, value: context.makeFunction(argumentCount: 2) { ctx, _, args in
            let target = args.first.map { JavaScriptByteCoding.text(from: $0, in: ctx) } ?? ""
            return QuickJSValueConverter.stringValue(try environment.openBrowser(target), in: ctx)
        })
        context.setProperty("longToast", on: object, value: context.makeFunction(argumentCount: 1) { ctx, _, args in
            guard let value = args.first else { return qjs_undefined() }
            environment.record(JavaScriptByteCoding.text(from: value, in: ctx))
            return ctx.duplicate(value)
        })

        context.setProperty("getTag", on: object, value: context.makeFunction { ctx, _, _ in
            QuickJSValueConverter.stringValue(executionContext.source?.id ?? "", in: ctx)
        })

        // MARK: 日志

        for name in ["log", "logType", "toast"] {
            context.setProperty(name, on: object, value: context.makeFunction(argumentCount: 1) { ctx, _, args in
                guard let value = args.first else { return qjs_undefined() }
                environment.record(JavaScriptByteCoding.text(from: value, in: ctx))
                // 入参所有权属于调用方，原样返回必须先 dup。
                return ctx.duplicate(value)
            })
        }

        // MARK: 网络与 Cookie（复用已注册的全局宿主函数）

        // 这里刻意按原名挂全局函数，而不是再写一遍实现：
        // 胶水层与单元测试都按这些名字断言，重复实现会让两处行为慢慢分叉。
        for (name, global) in [
            ("ajax", "__legadoAjax"),
            ("ajaxAll", "__legadoAjaxAll"),
            ("connect", "__legadoConnect"),
            ("__directRequest", "__legadoDirectRequest"),
            ("getCookieHeader", "__legadoGetCookieHeader"),
            ("__getCookieValue", "__legadoGetCookieValue"),
            ("setCookie", "__legadoSetCookie")
        ] {
            context.setProperty(name, on: object, value: globalFunction(global, in: context))
        }

        context.setGlobal("java", value: object)
    }

    /// 取出已注册的全局宿主函数值（所有权交给调用方）。
    private func globalFunction(_ name: String, in context: QuickJSContext) -> JSValue {
        let global = JS_GetGlobalObject(context.rawContext)
        let value = JS_GetPropertyStr(context.rawContext, global, name)
        JS_FreeValue(context.rawContext, global)
        return value
    }
}
