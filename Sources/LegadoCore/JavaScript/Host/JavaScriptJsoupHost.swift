import Foundation
import SwiftSoup
import CQuickJS

/// `org.jsoup.Jsoup` 宿主桥。
///
/// 书源里 `org.jsoup` 是 Rhino/Java 的顶层包名（Legado 文档里也是这个写法），典型用法：
///
///     var doc = org.jsoup.Jsoup.parse(result);
///     var box = doc.select('div.read-content,div.content_txt');
///     box.select('script,style,.ad-block').remove();
///     var content = box.html();
///
/// 不能用 JS 手写一个假的 Jsoup：`select` 的 CSS 选择器语义、`remove()` 的 DOM 变更、
/// `html()` 的序列化都必须由真实 HTML 解析器承担，否则书源拿到的正文要么为空、
/// 要么夹带 script/style（这类差异不会报错，只会让正文悄悄变脏，比崩溃更难发现）。
/// 工程里已有 SwiftSoup，因此这里把每个文档 / 元素集合包成整数句柄，
/// 真正的解析与查询全部落到 SwiftSoup 上。
///
/// 句柄表按 Context 隔离：每次 `install(into:)` 新建一个 `JavaScriptJsoupStore`，
/// 不跨执行共享，避免上一章 / 上一个书源的文档被后续脚本误用。
struct JavaScriptJsoupHost {
    /// 单个 HTML 文档的字节上限，避免脚本用超大页面把内存顶穿。
    let byteLimit: Int

    func install(into context: QuickJSContext) {
        let store = JavaScriptJsoupStore(byteLimit: byteLimit)

        context.defineFunction("__legadoJsoupParse", argumentCount: 2) { ctx, _, args in
            let html = args.first.map { JavaScriptByteCoding.string(from: $0, in: ctx) } ?? ""
            let baseURI = args.count > 1 ? JavaScriptByteCoding.string(from: args[1], in: ctx) : ""
            guard let handle = store.parse(html: html, baseURI: baseURI) else { return qjs_null() }
            return qjs_new_number(ctx.rawContext, Double(handle))
        }

        context.defineFunction("__legadoJsoupSelect", argumentCount: 2) { ctx, _, args in
            guard args.count == 2 else { return qjs_null() }
            let selector = JavaScriptByteCoding.string(from: args[1], in: ctx)
            guard let selected = store.select(Self.handle(args[0], in: ctx), selector: selector) else {
                return qjs_null()
            }
            return qjs_new_number(ctx.rawContext, Double(selected))
        }

        context.defineFunction("__legadoJsoupRemove", argumentCount: 1) { ctx, _, args in
            guard let first = args.first else { return qjs_null() }
            store.remove(Self.handle(first, in: ctx))
            return qjs_null()
        }

        context.defineFunction("__legadoJsoupHtml", argumentCount: 1) { ctx, _, args in
            let handle = args.first.map { Self.handle($0, in: ctx) } ?? -1
            return QuickJSValueConverter.stringValue(store.html(handle), in: ctx)
        }

        context.defineFunction("__legadoJsoupText", argumentCount: 1) { ctx, _, args in
            let handle = args.first.map { Self.handle($0, in: ctx) } ?? -1
            return QuickJSValueConverter.stringValue(store.text(handle), in: ctx)
        }

        context.defineFunction("__legadoJsoupOuterHtml", argumentCount: 1) { ctx, _, args in
            let handle = args.first.map { Self.handle($0, in: ctx) } ?? -1
            return QuickJSValueConverter.stringValue(store.outerHTML(handle), in: ctx)
        }

        context.defineFunction("__legadoJsoupAttr", argumentCount: 2) { ctx, _, args in
            guard args.count == 2 else { return QuickJSValueConverter.stringValue("", in: ctx) }
            let name = JavaScriptByteCoding.string(from: args[1], in: ctx)
            return QuickJSValueConverter.stringValue(store.attr(Self.handle(args[0], in: ctx), name: name), in: ctx)
        }

        context.defineFunction("__legadoJsoupSize", argumentCount: 1) { ctx, _, args in
            let handle = args.first.map { Self.handle($0, in: ctx) } ?? -1
            return qjs_new_number(ctx.rawContext, Double(store.size(handle)))
        }

        context.defineFunction("__legadoJsoupFirst", argumentCount: 1) { ctx, _, args in
            guard let first = args.first else { return qjs_null() }
            guard let value = store.first(Self.handle(first, in: ctx)) else { return qjs_null() }
            return qjs_new_number(ctx.rawContext, Double(value))
        }

        // `.get(i)` / `.last()`：起点这类目录脚本会用 `$[i].select('li').get(0)`。
        context.defineFunction("__legadoJsoupGet", argumentCount: 2) { ctx, _, args in
            guard args.count == 2 else { return qjs_null() }
            var ok = false
            let raw = qjs_to_double(ctx.rawContext, args[1], &ok)
            guard ok, raw.isFinite, abs(raw) <= Double(Int32.max) else { return qjs_null() }
            guard let value = store.element(Self.handle(args[0], in: ctx), at: Int(raw)) else {
                return qjs_null()
            }
            return qjs_new_number(ctx.rawContext, Double(value))
        }

        // MARK: 结构与遍历

        // `selectFirst` 是书源取「封面 / 第一章链接 / 下一页」的固定写法。
        // 单独开一个宿主函数而不是让 JS 写 `select(...).first()`：后者会先为整页
        // 匹配结果分配一个句柄数组，列表页上就是上千个节点，白占内存。
        context.defineFunction("__legadoJsoupSelectFirst", argumentCount: 2) { ctx, _, args in
            guard args.count == 2 else { return qjs_null() }
            let selector = JavaScriptByteCoding.string(from: args[1], in: ctx)
            guard let selected = store.selectFirst(Self.handle(args[0], in: ctx), selector: selector) else {
                return qjs_null()
            }
            return qjs_new_number(ctx.rawContext, Double(selected))
        }

        context.defineFunction("__legadoJsoupChildren", argumentCount: 1) { ctx, _, args in
            let handle = args.first.map { Self.handle($0, in: ctx) } ?? -1
            guard let value = store.children(handle) else { return qjs_null() }
            return qjs_new_number(ctx.rawContext, Double(value))
        }

        context.defineFunction("__legadoJsoupParent", argumentCount: 1) { ctx, _, args in
            let handle = args.first.map { Self.handle($0, in: ctx) } ?? -1
            guard let value = store.parent(handle) else { return qjs_null() }
            return qjs_new_number(ctx.rawContext, Double(value))
        }

        // `next()` / `prev()` 走的是 **元素** 兄弟而不是文本节点：
        // 书源拿它们翻「下一章 / 上一章」，给成文本节点会让随后的 `.select('a')` 落空。
        context.defineFunction("__legadoJsoupNext", argumentCount: 1) { ctx, _, args in
            let handle = args.first.map { Self.handle($0, in: ctx) } ?? -1
            guard let value = store.nextElementSibling(handle) else { return qjs_null() }
            return qjs_new_number(ctx.rawContext, Double(value))
        }

        context.defineFunction("__legadoJsoupPrev", argumentCount: 1) { ctx, _, args in
            let handle = args.first.map { Self.handle($0, in: ctx) } ?? -1
            guard let value = store.previousElementSibling(handle) else { return qjs_null() }
            return qjs_new_number(ctx.rawContext, Double(value))
        }

        // MARK: 属性读取

        context.defineFunction("__legadoJsoupTagName", argumentCount: 1) { ctx, _, args in
            let handle = args.first.map { Self.handle($0, in: ctx) } ?? -1
            return QuickJSValueConverter.stringValue(store.tagName(handle), in: ctx)
        }

        context.defineFunction("__legadoJsoupId", argumentCount: 1) { ctx, _, args in
            let handle = args.first.map { Self.handle($0, in: ctx) } ?? -1
            return QuickJSValueConverter.stringValue(store.attr(handle, name: "id"), in: ctx)
        }

        context.defineFunction("__legadoJsoupClassName", argumentCount: 1) { ctx, _, args in
            let handle = args.first.map { Self.handle($0, in: ctx) } ?? -1
            return QuickJSValueConverter.stringValue(store.attr(handle, name: "class"), in: ctx)
        }

        // `absUrl` 必须由 SwiftSoup 拿文档 baseURI 解析：书源里 `absUrl('href')`
        // 期望直接拿到绝对地址，用 JS 拼相对路径会在 `<base>` 标签与 `../` 上出错。
        context.defineFunction("__legadoJsoupAbsUrl", argumentCount: 2) { ctx, _, args in
            guard args.count == 2 else { return QuickJSValueConverter.stringValue("", in: ctx) }
            let name = JavaScriptByteCoding.string(from: args[1], in: ctx)
            return QuickJSValueConverter.stringValue(store.absUrl(Self.handle(args[0], in: ctx), name: name), in: ctx)
        }

        context.defineFunction("__legadoJsoupHasAttr", argumentCount: 2) { ctx, _, args in
            guard args.count == 2 else { return QuickJSValueConverter.value(from: .bool(false), in: ctx) }
            let name = JavaScriptByteCoding.string(from: args[1], in: ctx)
            let present = store.hasAttr(Self.handle(args[0], in: ctx), name: name)
            return QuickJSValueConverter.value(from: .bool(present), in: ctx)
        }

        // `ownText()` 只取直接文本节点。正文清洗里 `el.ownText()` 用来排除子标签里的
        // 广告文字，与 `text()` 是两个不同语义，互相顶替会让正文多出或丢掉整段。
        context.defineFunction("__legadoJsoupOwnText", argumentCount: 1) { ctx, _, args in
            let handle = args.first.map { Self.handle($0, in: ctx) } ?? -1
            return QuickJSValueConverter.stringValue(store.ownText(handle), in: ctx)
        }

        context.defineFunction("__legadoJsoupVal", argumentCount: 1) { ctx, _, args in
            let handle = args.first.map { Self.handle($0, in: ctx) } ?? -1
            return QuickJSValueConverter.stringValue(store.val(handle), in: ctx)
        }
    }

    /// JS 值 → 句柄。
    ///
    /// 必须做区间检查：`Int32(Double)` 在 Swift 里对超范围值直接 trap，
    /// 脚本随手传个 `1e30` 或 `NaN` 就能让宿主进程崩溃——这类崩溃在书源侧
    /// 只会表现为「阅读时闪退」，极难反推到某条规则传了野值。
    private static func handle(_ value: JSValue, in context: QuickJSContext) -> Int32 {
        var ok = false
        let number = qjs_to_double(context.rawContext, value, &ok)
        guard ok, number.isFinite, number >= 0, number <= Double(Int32.max) else { return -1 }
        return Int32(number)
    }
}

/// 句柄 → SwiftSoup 节点的映射表。
///
/// 统一存成 `[Element]`（`Document` 本身也是 `Element`）：
/// - `parse` 得到 `[document]`；
/// - `select` 在每个根节点下分别查询并合并结果，与 jsoup 的集合语义一致；
/// - `html()` / `text()` / `attr()` 取集合首元素，`size()` 取数量。
///
/// 失败一律用 `try?` 收敛：书源里的 CSS 选择器常常带非标准写法，
/// 一个选择器写错不该让整条正文规则抛异常，而应退化成空结果。
final class JavaScriptJsoupStore {
    private let byteLimit: Int
    private var nodes: [Int32: [Element]] = [:]
    private var nextHandle: Int32 = 1

    /// 句柄上限。超出后不再分配（返回 nil，宿主函数回 null）：
    /// 避免脚本在循环里反复 parse 把句柄表撑爆。
    private let maximumHandles = 20_000

    init(byteLimit: Int) {
        self.byteLimit = max(0, byteLimit)
    }

    func parse(html: String, baseURI: String) -> Int32? {
        let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= byteLimit else { return nil }
        guard let document = try? SwiftSoup.parse(trimmed, baseURI) else { return nil }
        // 显式标注 [Element]：Document 是 Element 子类，
        // 依赖数组字面量隐式上抛会让同类问题在别处再犯一次。
        let roots: [Element] = [document]
        return store(roots)
    }

    func select(_ handle: Int32, selector: String) -> Int32? {
        guard let roots = nodes[handle], !selector.isEmpty else { return nil }
        var matches: [Element] = []
        for root in roots {
            guard let found = try? root.select(selector) else { continue }
            // 用 Sequence 迭代而不是 `Array(found)`：SwiftSoup 的 `Elements`
            // 具体形态随版本变过，靠 Sequence 才稳。
            for element in found { matches.append(element) }
        }
        return store(matches)
    }

    func remove(_ handle: Int32) {
        guard let roots = nodes[handle] else { return }
        // SwiftSoup 的 `remove()` 是 throws；删不掉也不该让正文规则失败。
        for element in roots { _ = try? element.remove() }
    }

    func html(_ handle: Int32) -> String {
        guard let first = nodes[handle]?.first else { return "" }
        return (try? first.html()) ?? ""
    }

    func text(_ handle: Int32) -> String {
        guard let first = nodes[handle]?.first else { return "" }
        return (try? first.text()) ?? ""
    }

    func outerHTML(_ handle: Int32) -> String {
        guard let first = nodes[handle]?.first else { return "" }
        return (try? first.outerHtml()) ?? ""
    }

    func attr(_ handle: Int32, name: String) -> String {
        guard let first = nodes[handle]?.first else { return "" }
        return (try? first.attr(name)) ?? ""
    }

    func size(_ handle: Int32) -> Int {
        nodes[handle]?.count ?? 0
    }

    func first(_ handle: Int32) -> Int32? {
        guard let first = nodes[handle]?.first else { return nil }
        return store([first])
    }

    /// 支持负索引（`-1` 取最后一个），与 jsoup `Elements.get()` 的调用习惯对齐。
    func element(_ handle: Int32, at index: Int) -> Int32? {
        guard let roots = nodes[handle], !roots.isEmpty else { return nil }
        let resolved = index < 0 ? roots.count + index : index
        guard roots.indices.contains(resolved) else { return nil }
        return store([roots[resolved]])
    }

    // MARK: - 结构与遍历

    /// 每个根节点下取第一个匹配即返回。
    ///
    /// 逐个根节点查而不是把所有匹配合并后再取首个，是为了在首个根节点命中时
    /// 立刻停下：目录页的 `.select()` 常常要遍历几千个节点。
    func selectFirst(_ handle: Int32, selector: String) -> Int32? {
        guard let roots = nodes[handle], !selector.isEmpty else { return nil }
        for root in roots {
            guard let found = try? root.select(selector) else { continue }
            for element in found { return store([element]) }
        }
        return nil
    }

    /// 直接子元素。jsoup 的 `children()` 不含文本节点，与 SwiftSoup 同名语义一致。
    func children(_ handle: Int32) -> Int32? {
        guard let roots = nodes[handle] else { return nil }
        var matches: [Element] = []
        for root in roots {
            for element in root.children() { matches.append(element) }
        }
        return store(matches)
    }

    func parent(_ handle: Int32) -> Int32? {
        guard let root = nodes[handle]?.first, let value = root.parent() else { return nil }
        return store([value])
    }

    /// SwiftSoup 2.13.5 实测签名：`nextElementSibling() throws -> Element?`、
    /// `previousElementSibling() throws -> Element?`——两者都是 **throws**，
    /// 漏 `try` 是编译期硬失败（不是运行时退化）。解析异常时收敛成「没有下一个兄弟」。
    func nextElementSibling(_ handle: Int32) -> Int32? {
        guard let root = nodes[handle]?.first, let value = try? root.nextElementSibling() else { return nil }
        return store([value])
    }

    func previousElementSibling(_ handle: Int32) -> Int32? {
        guard let root = nodes[handle]?.first, let value = try? root.previousElementSibling() else { return nil }
        return store([value])
    }

    // MARK: - 属性

    func tagName(_ handle: Int32) -> String {
        nodes[handle]?.first?.tagName() ?? ""
    }

    /// `absUrl` 解析失败时退回原始属性值：书源要的是「能用的链接」，
    /// 拿不到绝对地址时给出相对路径，后续 `resolveJavaScriptRuleURL` 还能补齐。
    func absUrl(_ handle: Int32, name: String) -> String {
        guard let first = nodes[handle]?.first else { return "" }
        if let absolute = try? first.absUrl(name), !absolute.isEmpty { return absolute }
        return (try? first.attr(name)) ?? ""
    }

    /// SwiftSoup 2.13.5 实测：`Node.hasAttr(_:) -> Bool` 是 **非 throws**（与 `val()` 不同）。
    /// 这里不能加 `try`：会触发 "no calls to throwing functions occur within 'try' expression" 告警，
    /// 而告警在把 warning 当错误的 CI 配置下同样会让构建失败。
    func hasAttr(_ handle: Int32, name: String) -> Bool {
        guard let first = nodes[handle]?.first else { return false }
        return first.hasAttr(name)
    }

    /// SwiftSoup 2.13.5 实测：`Element.ownText() -> String` 是 **非 throws**。
    /// 与 `val()` / `absUrl()` 不同，这里加 `try?` 只会换来一条多余告警。
    func ownText(_ handle: Int32) -> String {
        guard let first = nodes[handle]?.first else { return "" }
        return first.ownText()
    }

    func val(_ handle: Int32) -> String {
        guard let first = nodes[handle]?.first else { return "" }
        return (try? first.val()) ?? ""
    }

    private func store(_ elements: [Element]) -> Int32? {
        guard nextHandle < Int32(maximumHandles) else { return nil }
        let handle = nextHandle
        nextHandle += 1
        nodes[handle] = elements
        return handle
    }
}
