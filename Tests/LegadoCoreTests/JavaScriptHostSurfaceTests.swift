import Foundation
import Testing
@testable import LegadoCore

/// 宿主 API 表面的回归测试。
///
/// 覆盖的是「书源实际会写、而引擎原先没有」的那批名字：`java.getStringList` /
/// `java.setContent` 一族 / `java.getElement(s)` / jsoup 的结构与属性方法。
/// 这些缺口在书源侧一律表现为 `xxx is not a function`，没有一行会提示「少了个 API」，
/// 所以必须有测试把它们钉住。
struct JavaScriptHostSurfaceTests {

    /// `getStringList` 走真正的列表模式求值：每个命中各占一个元素。
    @Test func getStringListReturnsEachMatchAsSeparateValue() throws {
        let html = #"<ul><li><a href="/a">甲</a></li><li><a href="/b">乙</a></li></ul>"#

        let value = try JavaScriptRuleEvaluator().evaluate(
            script: "java.getStringList('a@href', result).join(',') + ':' + Array.isArray(java.getStringList('a@href', result))",
            result: .string(html),
            executionContext: .init()
        )

        #expect(value.value.stringValue == "/a,/b:true")
    }

    /// 无命中必须是空数组，而不是含一个空串的数组：
    /// 目录分页规则会写 `list.length === 0` 判断「没有下一页」。
    @Test func getStringListReturnsEmptyArrayWhenNothingMatches() throws {
        let value = try JavaScriptRuleEvaluator().evaluate(
            script: "JSON.stringify(java.getStringList('.no-such-node', result))",
            result: .string("<div>x</div>"),
            executionContext: .init()
        )

        #expect(value.value.stringValue == "[]")
    }

    /// `setContent` 之后再写 `java.getString(rule)`（不传 content）必须读到新内容。
    @Test func setContentFeedsSubsequentGetStringCalls() throws {
        let value = try JavaScriptRuleEvaluator().evaluate(
            script: "java.setContent('<div id=\"t\">正文</div>'); java.getString('#t@text')",
            result: .string(""),
            executionContext: .init()
        )

        #expect(value.value.stringValue == "正文")
    }

    /// jsoup 包装层要同时给出结构遍历（selectFirst/children/next）与属性读取
    /// （tagName/absUrl），这是「上一章/下一章」与「封面绝对地址」两条链路的底座。
    @Test func jsoupElementSurfaceExposesStructureAndAttributes() throws {
        let html = #"<div class="box"><a href="/one" data-id="7">一</a><a href="/two">二</a></div>"#
        let script = """
            var box = org.jsoup.Jsoup.parse(result).selectFirst('.box');
            var first = box.selectFirst('a');
            first.attr('data-id') + ':' + first.absUrl('href') + ':' + first.tagName() + ':' +
              box.children().size() + ':' + first.next().attr('href');
            """

        let value = try JavaScriptRuleEvaluator().evaluate(
            script: script,
            result: .string(html),
            executionContext: .init(baseURL: "https://jsoup-surface.test/book/")
        )

        #expect(value.value.stringValue == "7:https://jsoup-surface.test/one:a:2:/two")
    }

    /// `md5Encode16` 是 32 位 md5 取中段 16 位的别名；`htmlFormat` 必须真过解析器。
    @Test func htmlFormatAndMd5ShortFormMatchLegadoAliases() throws {
        // htmlFormat 要返回 body 内层 HTML，而不是带 <html><head><body> 外壳的整份文档：
        // 书源把它拼进正文模板时，外壳会原样出现在正文里。
        let value = try JavaScriptRuleEvaluator().evaluate(
            script: "java.md5Encode16('abc') + ':' + (java.htmlFormat('<p>x</p>').indexOf('<p>') >= 0) + ':' + (java.htmlFormat('<p>x</p>').indexOf('<body') < 0)",
            result: .null,
            executionContext: .init()
        )

        #expect(value.value.stringValue == "3cd24fb0d6963f7d:true:true")
    }

    /// `getElement` / `getElements` 以当前内容（全局 `src`）为解析对象。
    @Test func getElementAndGetElementsResolveAgainstCurrentContent() throws {
        let html = #"<div class="list"><a href="/1">一</a><a href="/2">二</a></div>"#

        let value = try JavaScriptRuleEvaluator().evaluate(
            script: "java.getElement('a').attr('href') + ':' + java.getElements('a').size()",
            result: .string(html),
            executionContext: .init()
        )

        #expect(value.value.stringValue == "/1:2")
    }

    /// 列表模式 + CSS 前缀时，`result` 必须是可 select 的元素数组而不是字符串数组，
    /// 书源写 `result.map(x => x.select('a').attr('href'))` 才会生效。
    /// 这条同时守住 `mentionsElementAPI` 的登记面：漏登一个方法名就整段落空。
    @Test func listModePromotesResultToJsoupElements() async throws {
        let html = #"<ul><li><a href="/1">一</a></li><li><a href="/2">二</a></li></ul>"#
        let engine = RuleEngine()

        let result = await engine.evaluate(
            "ul li@js:result.map(function (x) { return x.select('a').attr('href'); }).join(',')",
            inText: html,
            baseURL: "https://list-mode.test/",
            listMode: true
        )

        #expect(result.firstString == "/1,/2")
        #expect(result.diagnostics.isEmpty)
    }

    /// 列表模式里 `selectFirst` + `absUrl` 也必须拿到元素对象：
    /// 「详情页封面 / 下一章」两处固定这样写。
    @Test func listModeSupportsSelectFirstAndAbsUrl() async throws {
        let html = #"<div class="row"><a href="/a/1">甲</a></div><div class="row"><a href="/a/2">乙</a></div>"#
        let engine = RuleEngine()

        let result = await engine.evaluate(
            "div.row@js:result.map(function (x) { return x.selectFirst('a').absUrl('href'); }).join('|')",
            inText: html,
            baseURL: "https://list-mode.test/book/",
            listMode: true
        )

        #expect(result.firstString == "https://list-mode.test/a/1|https://list-mode.test/a/2")
    }

    /// `@js` 规则返回数组时必须按元素展开，而不是压成一条字符串。
    ///
    /// 依据：`RuleExpressionParser.parseBranch` 把 `@js:` 前缀识别为 `.javaScript`
    /// （Sources/LegadoCore/RuleEngine/RuleExpression.swift:79），而 `evaluateStringRuleValues`
    /// 的 `.javaScript` 分支原先只取 `value.stringValue`——`result.map(x => ...)` 这类写法
    /// 返回的是数组，会被压成一条，让 `java.getStringList` 的真列表求值在 `@js` 入口又退化回单值。
    @Test func javaScriptBranchExpandsArrayIntoSeparateValues() throws {
        let value = try JavaScriptRuleEvaluator().evaluate(
            script: "JSON.stringify(java.getStringList(\"@js:['甲','乙']\"))",
            result: .null,
            executionContext: .init()
        )

        #expect(value.value.stringValue == "[\"甲\",\"乙\"]")
    }

    /// 单值 `@js`（不返回数组）仍然只产出一个元素：展开逻辑不能把标量也打散。
    ///
    /// 换行必须用 `String.fromCharCode(10)` 现场拼，不能写字面量反斜杠-n：
    /// JS 会先把转义序列解成真实换行，规则表达式就变成跨行的字符串字面量，
    /// 而 JS 字符串字面量不允许裸换行——求值抛语法错误后会被 `try?` 收敛成空数组，
    /// 断言随之假失败。这条用例钉的是「标量不被打散」，不是「能否处理跨行字面量」。
    @Test func javaScriptBranchKeepsScalarAsSingleValue() throws {
        let value = try JavaScriptRuleEvaluator().evaluate(
            script: "java.getStringList(\"@js:'甲'+String.fromCharCode(10)+'乙'\").length",
            result: .null,
            executionContext: .init()
        )

        #expect(value.value.stringValue == "1")
    }
}
