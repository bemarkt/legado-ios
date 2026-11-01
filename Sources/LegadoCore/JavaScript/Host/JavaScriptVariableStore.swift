import Foundation
import CQuickJS

/// `java.get` / `java.put` 的存储。
///
/// 语义与 JSC 版保持一致：`replacementEvaluator` 的多次匹配共享同一个实例，
/// 但每次匹配各自拥有全新的 JS 全局环境。因此这里必须是引用类型 + 内部锁，
/// 而不是值类型——否则 `java.put` 写进去的变量在下一次匹配就消失了。
final class JavaScriptVariableBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]

    init(_ values: [String: String] = [:]) {
        self.values = values
    }

    func get(_ key: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        return values[key] ?? ""
    }

    /// 返回写入后的字符串，方便 JS 侧 `var x = java.put('k', v)` 拿到值。
    @discardableResult
    func put(_ key: String, _ value: String) -> String {
        lock.lock()
        values[key] = value
        lock.unlock()
        return value
    }

    /// 导出快照。一定要拷贝，不能让调用方拿到可变字典的引用。
    var snapshot: [String: String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

/// Rhino 的 `Java byte[]` 在书源脚本里是有符号字节（-128...127）。
///
/// 这套转换必须逐字节保留 `Int8(bitPattern:)` 语义：AES 解密结果里
/// 负数字节如果被当成无符号处理，中文正文会立刻变成乱码，这是换引擎
/// 时最容易悄悄改变行为的地方。
enum JavaScriptByteCoding {

    static func signedBytes(_ data: Data) -> [Int] {
        data.map { Int(Int8(bitPattern: $0)) }
    }

    static func hexString(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func data(fromHex text: String) -> Data {
        let characters = Array(text.trimmingCharacters(in: .whitespacesAndNewlines))
        guard characters.count.isMultiple(of: 2) else { return Data() }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(characters.count / 2)
        for index in stride(from: 0, to: characters.count, by: 2) {
            guard let value = UInt8(String(characters[index...index + 1]), radix: 16) else {
                return Data()
            }
            bytes.append(value)
        }
        return Data(bytes)
    }

    /// 从 JS 数组读字节。
    ///
    /// 逐个 `JS_GetPropertyUint32` 取值而不是先字符串化：脚本里这些数组由
    /// `Base64.decode` / `Cipher.doFinal` 产出，是真实数字数组，走字符串会多一次
    /// 无损编码假设，并且对大数组产生不必要的拷贝。
    static func data(from value: JSValue, in context: QuickJSContext, limit: Int) -> Data? {
        guard qjs_is_array(value) else { return nil }
        var lengthOK = false
        let rawLength = qjs_get_length(context.rawContext, value, &lengthOK)
        guard lengthOK, rawLength >= 0, rawLength <= Int64(limit) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(Int(rawLength))
        for index in 0..<Int(rawLength) {
            let element = qjs_get_property_uint32(context.rawContext, value, UInt32(index))
            if qjs_is_exception(element) {
                context.release(element)
                return nil
            }
            var numberOK = false
            let number = qjs_to_double(context.rawContext, element, &numberOK)
            context.release(element)
            guard numberOK, number.isFinite else { return nil }
            // Int64(Double) 对超范围值直接 trap：脚本给个 1e30 就能让宿主进程崩溃。
            // 先夹到安全区间再位截断，语义与 Java 的 (byte) 强转一致。
            let rounded = number.rounded(.towardZero)
            guard rounded >= -1_000_000_000, rounded <= 1_000_000_000 else { return nil }
            bytes.append(UInt8(truncatingIfNeeded: Int64(rounded)))
        }
        return Data(bytes)
    }

    static func value(for data: Data, in context: QuickJSContext) -> JSValue {
        value(forSigned: signedBytes(data), in: context)
    }

    /// 构造 JS 数字数组。刻意用 `qjs_new_number`（浮点）：
    /// 书源脚本会对这些值做 `parseInt(x, 10)`、位移与比较，
    /// 用整数构造会让 `>> 24` 之类的高位运算在 QuickJS 里走不同分支。
    static func value(forSigned signed: [Int], in context: QuickJSContext) -> JSValue {
        let array = JS_NewArray(context.rawContext)
        for (index, byte) in signed.enumerated() {
            let element = qjs_new_number(context.rawContext, Double(byte))
            _ = qjs_set_property_uint32(context.rawContext, array, UInt32(index), element)
        }
        return array
    }

    /// JS 字符串 → Swift String（按 UTF-8 字节数解码，保留中文与 emoji）。
    static func string(from value: JSValue, in context: QuickJSContext) -> String {
        context.string(from: value) ?? ""
    }

    /// 任意 JS 值 → Swift String，行为对齐 `JSON.stringify` 之外的常见用法：
    /// 数字不带 `.0` 后缀，`null` / `undefined` 变空串。
    static func text(from value: JSValue, in context: QuickJSContext) -> String {
        if qjs_is_null(value) || qjs_is_undefined(value) { return "" }
        if qjs_is_number(value) {
            var ok = false
            let number = qjs_to_double(context.rawContext, value, &ok)
            guard ok, number.isFinite else { return "" }
            return number.rounded() == number ? String(format: "%.0f", number) : String(number)
        }
        if qjs_is_bool(value) { return qjs_to_bool(context.rawContext, value) == 1 ? "true" : "false" }
        if qjs_is_string(value) { return string(from: value, in: context) }
        let json = context.jsonValue(from: value)
        return json.stringValue
    }
}
