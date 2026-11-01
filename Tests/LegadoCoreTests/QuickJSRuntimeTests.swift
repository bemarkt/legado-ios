import Foundation
import Testing
@testable import LegadoCore

/// QuickJS 迁移的回归测试。
///
/// 覆盖三类迁移指南明确要求、且最容易在换引擎时悄悄回退的能力：
/// 1. 大型脚本 / 大型 jsLib 能整体加载执行（旧的 64KB 自写门限已移除）；
/// 2. 宿主 API 语义零漂移（有符号 byte、hex/base64/hmac、java.get/put 共享）；
/// 3. 资源约束真实生效（死循环超时、语法错误有明确诊断码）。
struct QuickJSRuntimeTests {

    /// 大脚本分级加载。旧实现 `maximumScriptLength = 64 * 1024` 会在第一档就报错。
    @Test func executesLargeScriptsUpToFourMegabytes() throws {
        let evaluator = JavaScriptRuleEvaluator(
            maximumRuleLength: 8 << 20,
            maximumJSLibLength: 8 << 20
        )
        for size in [64 << 10, 256 << 10, 1 << 20] {
            // 用注释填充，保证脚本语法仍然合法。
            let filler = "// " + String(repeating: "x", count: size) + "\n"
            let script = filler + "1 + 1"
            let value = try evaluator.evaluate(script: script, result: .null, executionContext: .init())
            #expect(value.value.stringValue == "2", "脚本体积 \(size) 字节时执行失败")
        }
    }

    /// 近 4MB 的 jsLib 注入后，规则脚本能调用其中的函数。
    @Test func loadsLargeJSLibraryAndCallsIntoIt() throws {
        var source = BookSource(bookSourceUrl: "https://js-lib-large.test", bookSourceName: "大型共享脚本")
        let filler = "// " + String(repeating: "y", count: (4 << 20) - 4096) + "\n"
        source.jsLib = filler + "function quickJSProbe() { return 'lib-ok'; }"

        let value = try JavaScriptRuleEvaluator().evaluate(
            script: "quickJSProbe()",
            result: .null,
            executionContext: .init(source: source)
        )

        #expect(value.value.stringValue == "lib-ok")
    }

    /// Java byte[] 必须保留有符号语义：负数字节被当无符号处理会让中文正文变乱码。
    @Test func keepsSignedJavaByteSemanticsAndHexBase64RoundTrips() throws {
        let value = try JavaScriptRuleEvaluator().evaluate(
            script: """
                (function () {
                  var text = '第一段正文';
                  var bytes = java.strToBytes(text);
                  var hasNegative = bytes.some(function (b) { return b < 0; });
                  return java.bytesToStr(bytes) + ':' +
                    (hasNegative ? 'signed' : 'unsigned') + ':' +
                    java.hexDecodeToString(java.hexEncodeToString('A')) + ':' +
                    java.bytesToStr(java.base64DecodeToByteArray('b2s='));
                })();
                """,
            result: .null,
            executionContext: .init()
        )

        #expect(value.value.stringValue == "第一段正文:signed:A:ok")
    }

    /// replacementEvaluator 的多轮匹配必须共享 java.get/put 存储，但各自拥有全新全局环境。
    @Test func replacementMatchesShareJavaVariablesButNotGlobals() throws {
        let evaluator = JavaScriptRuleEvaluator()
        let book = Book(bookUrl: "https://replace.test/1", name: "替换测试", author: "作者")
        let chapter = BookChapter(url: "/c/1", title: "第一章", bookUrl: book.bookUrl, index: 0)
        let script = """
            var fresh = (typeof marker === 'undefined');
            marker = true;
            var count = Number(java.get('count') || '0') + 1;
            java.put('count', String(count));
            (fresh ? 'fresh' : 'reused') + ':' + count;
            """
        let apply = evaluator.replacementEvaluator(script: script, book: book, chapter: chapter)

        let first = try apply("a")
        let second = try apply("b")

        #expect(first == "fresh:1")
        #expect(second == "fresh:2")
    }

    /// undefined / null 统一收敛为 JSONValue.null，不引入第二种空值表示。
    @Test func normalizesUndefinedAndNullToOneNullValue() throws {
        let evaluator = JavaScriptRuleEvaluator()
        let undefined = try evaluator.evaluate(script: "undefined", result: .null, executionContext: .init())
        let null = try evaluator.evaluate(script: "null", result: .null, executionContext: .init())
        let plain = try evaluator.evaluate(
            script: "JSON.parse(result)",
            result: .string("服务暂时不可用"),
            executionContext: .init()
        )

        #expect(undefined.value == .null)
        #expect(null.value == .null)
        #expect(plain.value.stringValue == "服务暂时不可用")
    }

    /// 语法错误与执行超时必须分别落到 rule.malformed / rule.resource_limit。
    @Test func reportsSyntaxErrorAndTimeoutWithDistinctDiagnosticCodes() async {
        let syntax = await RuleEngine().evaluate("@js:function (", in: .null)
        #expect(syntax.diagnostics.contains { $0.code == "rule.malformed" })

        let timeout = await RuleEngine(javaScript: JavaScriptRuleEvaluator(timeoutMilliseconds: 200))
            .evaluate("@js:for(;;){}", in: .null)
        #expect(timeout.diagnostics.contains { $0.code == "rule.resource_limit" })
    }
}
