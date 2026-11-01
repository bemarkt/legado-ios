import Foundation
import CQuickJS

/// 纯函数型宿主接口：只做字节 / 字符串 / 加解密变换，不依赖书源上下文。
///
/// 与「上下文型宿主接口」（`java.get` / `source.*` / `book` / `chapter`）分开，
/// 是因为它们可以整体复用、可单测、且没有生命周期耦合：`replacementEvaluator`
/// 每次匹配都会重建 Context，这些函数每次都要重新注入，但注入成本只是几个
/// `JS_NewCFunctionData`。
struct JavaScriptPrimitiveHosts {
    /// 单次 AES / 字节数组转换的上限，避免脚本用一个超大数组把内存顶穿。
    let byteLimit: Int

    init(byteLimit: Int) {
        self.byteLimit = max(0, byteLimit)
    }

    func install(into context: QuickJSContext) {
        let byteLimit = self.byteLimit

        // String.getBytes() → Java byte[]
        context.defineFunction("__legadoUTF8Bytes", argumentCount: 1) { ctx, _, args in
            let text = args.first.map { JavaScriptByteCoding.text(from: $0, in: ctx) } ?? ""
            return JavaScriptByteCoding.value(for: Data(text.utf8), in: ctx)
        }

        // Java byte[] → String（严格 UTF-8，与 String(decoding:as: UTF8.self) 一致）
        context.defineFunction("__legadoUTF8String", argumentCount: 1) { ctx, _, args in
            let data = args.first.flatMap {
                JavaScriptByteCoding.data(from: $0, in: ctx, limit: byteLimit)
            } ?? Data()
            return QuickJSValueConverter.stringValue(String(decoding: data, as: UTF8.self), in: ctx)
        }

        // Cipher.doFinal → 失败返回 null，与 Rhino 侧 `[Int]?` 的行为一致；
        // JS 胶水层会把它转成 `AES/CBC operation failed` 异常，不会被静默吞掉。
        context.defineFunction("__legadoAESCBC", argumentCount: 4) { ctx, _, args in
            guard args.count == 4 else { return qjs_null() }
            var operationOK = false
            let operation = Int32(qjs_to_double(ctx.rawContext, args[0], &operationOK))
            guard operationOK,
                  let key = JavaScriptByteCoding.data(from: args[1], in: ctx, limit: byteLimit),
                  let iv = JavaScriptByteCoding.data(from: args[2], in: ctx, limit: byteLimit),
                  let input = JavaScriptByteCoding.data(from: args[3], in: ctx, limit: byteLimit),
                  let output = JavaScriptCryptoBridge.aesCBC(
                    operation: operation,
                    key: key,
                    iv: iv,
                    input: input,
                    limit: byteLimit
                  ) else { return qjs_null() }
            return JavaScriptByteCoding.value(for: output, in: ctx)
        }

        context.defineFunction("__legadoBase64EncodeBytes", argumentCount: 1) { ctx, _, args in
            let data = args.first.flatMap {
                JavaScriptByteCoding.data(from: $0, in: ctx, limit: byteLimit)
            } ?? Data()
            return QuickJSValueConverter.stringValue(JavaScriptCryptoBridge.base64Encode(data), in: ctx)
        }

        context.defineFunction("__legadoBase64DecodeBytes", argumentCount: 1) { ctx, _, args in
            let text = args.first.map { JavaScriptByteCoding.text(from: $0, in: ctx) } ?? ""
            let data = JavaScriptCryptoBridge.base64Decode(text) ?? Data()
            return JavaScriptByteCoding.value(for: data, in: ctx)
        }

        // 大写：DatatypeConverter.printHexBinary 的既有行为。
        context.defineFunction("__legadoHexEncodeBytes", argumentCount: 1) { ctx, _, args in
            let data = args.first.flatMap {
                JavaScriptByteCoding.data(from: $0, in: ctx, limit: byteLimit)
            } ?? Data()
            return QuickJSValueConverter.stringValue(
                JavaScriptCryptoBridge.hexEncode(data, uppercase: true),
                in: ctx
            )
        }

        context.defineFunction("__legadoHmacSHA1", argumentCount: 2) { ctx, _, args in
            guard args.count == 2,
                  let key = JavaScriptByteCoding.data(from: args[0], in: ctx, limit: byteLimit),
                  let message = JavaScriptByteCoding.data(from: args[1], in: ctx, limit: byteLimit) else {
                return JavaScriptByteCoding.value(forSigned: [], in: ctx)
            }
            return JavaScriptByteCoding.value(for: JavaScriptCryptoBridge.hmacSHA1(key: key, message: message), in: ctx)
        }

        context.defineFunction("__legadoFormURLEncode", argumentCount: 1) { ctx, _, args in
            let text = args.first.map { JavaScriptByteCoding.text(from: $0, in: ctx) } ?? ""
            return QuickJSValueConverter.stringValue(JavaScriptCryptoBridge.formURLEncode(text), in: ctx)
        }

        // 诊断日志：写一行即可，返回值原样回传（脚本里能链式使用）。
        context.defineFunction("__legadoLog", argumentCount: 1) { ctx, _, args in
            guard let value = args.first else { return qjs_undefined() }
            DiagnosticLog.shared.record(
                category: "JS",
                message: JavaScriptByteCoding.text(from: value, in: ctx)
            )
            return ctx.duplicate(value)
        }
    }
}
