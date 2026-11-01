import Foundation
import CQuickJS

/// `JSONValue` 与 QuickJS 值之间的双向转换。
///
/// 两条与既有语义对齐的硬约束：
/// 1. `undefined` 与 `null` 都收敛成 `JSONValue.null`，不引入第二种空值表示
///    （既有 `JSONValue.bridge` 对 `NSNull` 就是这么处理的，上层诊断与判空逻辑依赖这一点）。
/// 2. 数字统一用 `JS_NewFloat64` 构造，不用 `JS_NewInt32`：书源脚本里
///    `result.length` 之类常常参与除法，退化成整数会改变结果。
public enum QuickJSValueConverter {

    /// `JSONValue` → `JSValue`。返回值所有权交给调用方（或直接交给 `JS_SetProperty*`）。
    public static func value(from json: JSONValue, in context: QuickJSContext) -> JSValue {
        switch json {
        case .null:
            return qjs_null()
        case .bool(let flag):
            return JS_NewBool(context.rawContext, flag)
        case .number(let number):
            return JS_NewFloat64(context.rawContext, number)
        case .string(let text):
            return stringValue(text, in: context)
        case .array(let items):
            let array = JS_NewArray(context.rawContext)
            for (index, item) in items.enumerated() {
                // JS_SetPropertyUint32 接管 value 的所有权。
                JS_SetPropertyUint32(
                    context.rawContext,
                    array,
                    UInt32(index),
                    value(from: item, in: context)
                )
            }
            return array
        case .object(let members):
            let object = JS_NewObject(context.rawContext)
            for (key, item) in members {
                JS_SetPropertyStr(
                    context.rawContext,
                    object,
                    key,
                    value(from: item, in: context)
                )
            }
            return object
        }
    }

    /// `String` → `JSValue`。用 `JS_NewStringLen` 而不是 `JS_NewString`，
    /// 这样 `\0` 与内嵌 NUL 不会被 C 字符串截断。
    public static func stringValue(_ text: String, in context: QuickJSContext) -> JSValue {
        text.withCString { pointer in
            JS_NewStringLen(context.rawContext, pointer, text.utf8.count)
        }
    }
}
