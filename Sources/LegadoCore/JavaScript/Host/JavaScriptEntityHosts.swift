import Foundation
import CQuickJS

/// `source` / `book` / `chapter` 三个命名空间对象的宿主层。
///
/// 字段名与函数名一律按 JSC 版逐字照搬。换引擎时这些名字就是书源作者的
/// API 契约，改名不是风格差异，是全量书源失效：书源里写的是
/// `source.getKey()`、`book.getTotalChapterNum()`、`chapter.isVolume`，
/// 换个拼写就等于换了一套接口。
///
/// 两套存储边界原样保留：
/// - `source.get/put` → `BookSourceRuntimeStore`（跨执行持久化，登录态靠它）；
/// - `java.get/put` → `JavaScriptVariableBox`（单次规则内共享，替换匹配复用）；
/// 把两者合并会让「登录变量泄漏进单次规则」或「规则变量被持久化」二者之一发生。
struct JavaScriptEntityHosts {
    let source: BookSource?
    let book: Book?
    let chapter: BookChapter?
    let state: any JavaScriptSourceState

    func install(into context: QuickJSContext) {
        installSource(into: context)
        installBook(into: context)
        installChapter(into: context)
    }

    // MARK: - source

    private func installSource(into context: QuickJSContext) {
        guard let source else { return }
        let sourceID = source.bookSourceUrl

        // 先放标量属性，再挂方法。属性顺序不影响语义，
        // 但方法必须在 `RhinoCompatibilityScripts.sourceBridge` 之前挂好，
        // 否则胶水脚本里引用到的是 undefined，调用时抛 not a function。
        let scalars: [String: JSONValue] = [
            "bookSourceName": .string(source.bookSourceName),
            "bookSourceUrl": .string(source.bookSourceUrl),
            "bookSourceGroup": .string(source.bookSourceGroup ?? ""),
            "bookSourceType": .number(Double(source.bookSourceType)),
            "bookUrlPattern": .string(source.bookUrlPattern ?? ""),
            "customOrder": .number(Double(source.customOrder)),
            "enabled": .bool(source.enabled),
            "enabledExplore": .bool(source.enabledExplore),
            "header": .string(source.header ?? ""),
            "loginUrl": .string(source.loginUrl ?? ""),
            "searchUrl": .string(source.searchUrl ?? ""),
            "exploreUrl": .string(source.exploreUrl ?? ""),
            "respondTime": .number(Double(source.respondTime)),
            "weight": .number(Double(source.weight)),
            "enabledCookieJar": .bool(source.enabledCookieJar ?? true),
            "concurrentRate": .string(source.concurrentRate ?? ""),
            "coverDecodeJs": .string(source.coverDecodeJs ?? ""),
            "bookSourceComment": .string(source.bookSourceComment ?? ""),
            "variableComment": .string(source.variableComment ?? "")
        ]
        let object = QuickJSValueConverter.value(from: .object(scalars), in: context)

        context.setProperty("get", on: object, value: context.makeFunction(argumentCount: 1) { ctx, _, args in
            let key = args.first.map { JavaScriptByteCoding.text(from: $0, in: ctx) } ?? ""
            return QuickJSValueConverter.stringValue(
                try state.get(sourceID: sourceID, key: key),
                in: ctx
            )
        })

        context.setProperty("put", on: object, value: context.makeFunction(argumentCount: 2) { ctx, _, args in
            guard args.count == 2 else { return QuickJSValueConverter.stringValue("", in: ctx) }
            let key = JavaScriptByteCoding.text(from: args[0], in: ctx)
            let value = JavaScriptByteCoding.text(from: args[1], in: ctx)
            try state.put(sourceID: sourceID, key: key, value: value)
            return QuickJSValueConverter.stringValue(value, in: ctx)
        })

        context.setProperty("getLoginHeader", on: object, value: context.makeFunction { ctx, _, _ in
            let value = try state.get(sourceID: sourceID, key: "loginHeader")
            return value.isEmpty ? qjs_null() : QuickJSValueConverter.stringValue(value, in: ctx)
        })

        context.setProperty("putLoginHeader", on: object, value: context.makeFunction(argumentCount: 1) { ctx, _, args in
            let value = args.first.map { JavaScriptByteCoding.text(from: $0, in: ctx) } ?? ""
            try state.put(sourceID: sourceID, key: "loginHeader", value: value)
            return QuickJSValueConverter.stringValue(value, in: ctx)
        })

        // `source.removeLoginHeader()`：登录 UI 的「清除会话」按钮动作里就是
        // `cookie.removeCookie(source.bookSourceUrl); source.removeLoginHeader();`，
        // 缺这个方法点一下就是 TypeError，而用户只会看到「清除失败」。
        context.setProperty("removeLoginHeader", on: object, value: context.makeFunction { ctx, _, _ in
            try state.put(sourceID: sourceID, key: "loginHeader", value: "")
            return QuickJSValueConverter.stringValue("", in: ctx)
        })

        // 名字带双下划线前缀，保持与 JS 胶水里 `source.__getLoginInfoMap()` 一致。
        context.setProperty("__getLoginInfoMap", on: object, value: context.makeFunction { ctx, _, _ in
            let raw = try state.get(sourceID: sourceID, key: "loginInfo")
            let json = (try? JSONValue.decode(data: Data(raw.utf8))) ?? .object([:])
            return QuickJSValueConverter.value(from: json, in: ctx)
        })

        context.setProperty("putLoginInfo", on: object, value: context.makeFunction(argumentCount: 1) { ctx, _, args in
            let value = args.first.map { JavaScriptByteCoding.text(from: $0, in: ctx) } ?? ""
            try state.put(sourceID: sourceID, key: "loginInfo", value: value)
            return QuickJSValueConverter.stringValue(value, in: ctx)
        })

        context.setProperty("getHeaderMap", on: object, value: context.makeFunction(argumentCount: 1) { ctx, _, args in
            let headerText = (source.header ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var headers: [String: String] = [:]
            if headerText.hasPrefix("{"),
               case .object(let members) = (try? JSONValue.decode(data: Data(headerText.utf8))) ?? .null {
                headers = members.mapValues { $0.stringValue }
            }
            let includeLogin = args.first.map { qjs_to_bool(ctx.rawContext, $0) == 1 } ?? false
            if includeLogin {
                headers.merge(try state.loginHeaders(sourceID: sourceID)) { _, login in login }
            }
            return QuickJSValueConverter.value(from: .object(headers.mapValues { .string($0) }), in: ctx)
        })

        // 书源偶尔把 `source.bookSourceXXX` 写成 getter 形式，
        // 缺了就是 `source.getBookSourceName is not a function`，整条 header 规则断掉。
        context.setProperty("getBookSourceUrl", on: object, value: context.makeFunction { ctx, _, _ in
            QuickJSValueConverter.stringValue(source.bookSourceUrl, in: ctx)
        })
        context.setProperty("getBookSourceName", on: object, value: context.makeFunction { ctx, _, _ in
            QuickJSValueConverter.stringValue(source.bookSourceName, in: ctx)
        })
        context.setProperty("getBookSourceGroup", on: object, value: context.makeFunction { ctx, _, _ in
            QuickJSValueConverter.stringValue(source.bookSourceGroup ?? "", in: ctx)
        })
        context.setProperty("getBookSourceType", on: object, value: context.makeFunction { ctx, _, _ in
            qjs_new_number(ctx.rawContext, Double(source.bookSourceType))
        })

        context.setGlobal("source", value: object)
    }

    // MARK: - book

    private func installBook(into context: QuickJSContext) {
        let scalars: [String: JSONValue] = [
            "name": .string(book?.name ?? ""),
            "author": .string(book?.author ?? ""),
            "bookUrl": .string(book?.bookUrl ?? ""),
            "tocUrl": .string(book?.tocUrl ?? ""),
            "origin": .string(book?.origin ?? ""),
            "originName": .string(book?.originName ?? ""),
            "kind": .string(book?.kind ?? ""),
            "coverUrl": .string(book?.coverUrl ?? ""),
            "intro": .string(book?.intro ?? ""),
            "type": .number(Double(book?.type ?? 0)),
            "group": .number(Double(book?.group ?? 0)),
            "latestChapterTitle": .string(book?.latestChapterTitle ?? ""),
            "totalChapterNum": .number(Double(book?.totalChapterNum ?? 0)),
            "durChapterIndex": .number(Double(book?.durChapterIndex ?? 0)),
            "durChapterTitle": .string(book?.durChapterTitle ?? ""),
            "durChapterPos": .number(Double(book?.durChapterPos ?? 0)),
            "wordCount": .string(book?.wordCount ?? ""),
            "variable": .string(book?.variable ?? "")
        ]
        let object = QuickJSValueConverter.value(from: .object(scalars), in: context)

        context.setProperty("getName", on: object, value: context.makeFunction { ctx, _, _ in
            QuickJSValueConverter.stringValue(book?.name ?? "", in: ctx)
        })
        context.setProperty("getAuthor", on: object, value: context.makeFunction { ctx, _, _ in
            QuickJSValueConverter.stringValue(book?.author ?? "", in: ctx)
        })
        context.setProperty("getBookUrl", on: object, value: context.makeFunction { ctx, _, _ in
            QuickJSValueConverter.stringValue(book?.bookUrl ?? "", in: ctx)
        })
        context.setProperty("getCoverUrl", on: object, value: context.makeFunction { ctx, _, _ in
            QuickJSValueConverter.stringValue(book?.coverUrl ?? "", in: ctx)
        })
        context.setProperty("getTotalChapterNum", on: object, value: context.makeFunction { ctx, _, _ in
            qjs_new_number(ctx.rawContext, Double(book?.totalChapterNum ?? 0))
        })

        // 详情页与「换源比对」会用这一批 getter 拼诊断信息：
        // 名字与属性同名但形态不同（`book.intro` vs `book.getIntro()`），书源两种写法都有，
        // 只给属性会让 `book.getIntro()` 直接抛 not a function。
        context.setProperty("getIntro", on: object, value: context.makeFunction { ctx, _, _ in
            QuickJSValueConverter.stringValue(book?.intro ?? "", in: ctx)
        })
        context.setProperty("getKind", on: object, value: context.makeFunction { ctx, _, _ in
            QuickJSValueConverter.stringValue(book?.kind ?? "", in: ctx)
        })
        context.setProperty("getOrigin", on: object, value: context.makeFunction { ctx, _, _ in
            QuickJSValueConverter.stringValue(book?.origin ?? "", in: ctx)
        })
        context.setProperty("getOriginName", on: object, value: context.makeFunction { ctx, _, _ in
            QuickJSValueConverter.stringValue(book?.originName ?? "", in: ctx)
        })
        context.setProperty("getLatestChapterTitle", on: object, value: context.makeFunction { ctx, _, _ in
            QuickJSValueConverter.stringValue(book?.latestChapterTitle ?? "", in: ctx)
        })
        context.setProperty("getDurChapterTitle", on: object, value: context.makeFunction { ctx, _, _ in
            QuickJSValueConverter.stringValue(book?.durChapterTitle ?? "", in: ctx)
        })
        context.setProperty("getDurChapterIndex", on: object, value: context.makeFunction { ctx, _, _ in
            qjs_new_number(ctx.rawContext, Double(book?.durChapterIndex ?? 0))
        })
        context.setProperty("getVariable", on: object, value: context.makeFunction { ctx, _, _ in
            QuickJSValueConverter.stringValue(book?.variable ?? "", in: ctx)
        })
        // `book.getVariableMap()` 在 Legado 里是解析后的对象，不是原始 JSON 串；
        // 解析失败回落成空对象，避免书源 `.xxx` 取字段时报 undefined is not an object。
        context.setProperty("getVariableMap", on: object, value: context.makeFunction { ctx, _, _ in
            let raw = book?.variable ?? ""
            let json = (try? JSONValue.decode(data: Data(raw.utf8))) ?? .object([:])
            return QuickJSValueConverter.value(from: json, in: ctx)
        })

        context.setGlobal("book", value: object)
    }

    // MARK: - chapter

    private func installChapter(into context: QuickJSContext) {
        let scalars: [String: JSONValue] = [
            "title": .string(chapter?.title ?? ""),
            "index": .number(Double(chapter?.index ?? 0)),
            "url": .string(chapter?.url ?? ""),
            "baseUrl": .string(chapter?.baseUrl ?? ""),
            "bookUrl": .string(chapter?.bookUrl ?? ""),
            "isVolume": .bool(chapter?.isVolume ?? false),
            "isVip": .bool(chapter?.isVip ?? false),
            "isPay": .bool(chapter?.isPay ?? false),
            "resourceUrl": .string(chapter?.resourceUrl ?? ""),
            "tag": .string(chapter?.tag ?? ""),
            "wordCount": .string(chapter?.wordCount ?? ""),
            "variable": .string(chapter?.variable ?? "")
        ]
        let object = QuickJSValueConverter.value(from: .object(scalars), in: context)

        context.setProperty("getTitle", on: object, value: context.makeFunction { ctx, _, _ in
            QuickJSValueConverter.stringValue(chapter?.title ?? "", in: ctx)
        })
        context.setProperty("getIndex", on: object, value: context.makeFunction { ctx, _, _ in
            qjs_new_number(ctx.rawContext, Double(chapter?.index ?? 0))
        })
        context.setProperty("getUrl", on: object, value: context.makeFunction { ctx, _, _ in
            QuickJSValueConverter.stringValue(chapter?.url ?? "", in: ctx)
        })

        context.setProperty("getBookUrl", on: object, value: context.makeFunction { ctx, _, _ in
            QuickJSValueConverter.stringValue(chapter?.bookUrl ?? "", in: ctx)
        })
        context.setProperty("getBaseUrl", on: object, value: context.makeFunction { ctx, _, _ in
            QuickJSValueConverter.stringValue(chapter?.baseUrl ?? "", in: ctx)
        })
        context.setProperty("getResourceUrl", on: object, value: context.makeFunction { ctx, _, _ in
            QuickJSValueConverter.stringValue(chapter?.resourceUrl ?? "", in: ctx)
        })
        context.setProperty("getVariable", on: object, value: context.makeFunction { ctx, _, _ in
            QuickJSValueConverter.stringValue(chapter?.variable ?? "", in: ctx)
        })
        context.setProperty("getTag", on: object, value: context.makeFunction { ctx, _, _ in
            QuickJSValueConverter.stringValue(chapter?.tag ?? "", in: ctx)
        })
        context.setProperty("getWordCount", on: object, value: context.makeFunction { ctx, _, _ in
            QuickJSValueConverter.stringValue(chapter?.wordCount ?? "", in: ctx)
        })

        context.setGlobal("chapter", value: object)
        // 规则脚本里 `title` 是全局变量（不是 `chapter.title`），
        // 与 JSC 版的 `context.setObject(chapter?.title, forKeyedSubscript: "title")` 对齐。
        context.setGlobal("title", value: QuickJSValueConverter.stringValue(chapter?.title ?? "", in: context))
    }
}
