#ifndef QJS_SHIM_H
#define QJS_SHIM_H

#include "quickjs.h"

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Swift cannot see C macros, but the QuickJS embedding API relies on several of
 * them (value constants and eval flags are all #define). These thin wrappers are
 * the only additive code in the vendored tree; the engine itself is untouched.
 */

JSValue qjs_undefined(void);
JSValue qjs_null(void);
JSValue qjs_exception(void);

int qjs_eval_type_global(void);
int qjs_eval_flag_compile_only(void);

/* Property enumeration / definition flags are macros too. */
int qjs_gpn_string_mask(void);
int qjs_gpn_enum_only(void);
int qjs_prop_c_w_e(void);

/*
 * Value predicates and accessors. Every function below wraps a `static inline`
 * or pointer-out-parameter API from quickjs.h, so the Swift side only ever binds
 * against real exported symbols.
 */
bool qjs_is_null(JSValueConst value);
bool qjs_is_undefined(JSValueConst value);
bool qjs_is_exception(JSValueConst value);
bool qjs_is_uninitialized(JSValueConst value);
bool qjs_is_bool(JSValueConst value);
bool qjs_is_number(JSValueConst value);
bool qjs_is_string(JSValueConst value);
bool qjs_is_object(JSValueConst value);
bool qjs_is_array(JSValueConst value);
bool qjs_is_function(JSContext *ctx, JSValueConst value);

int qjs_to_bool(JSContext *ctx, JSValueConst value);
double qjs_to_double(JSContext *ctx, JSValueConst value, bool *ok);
double qjs_to_double_or(JSContext *ctx, JSValueConst value, double fallback);
int64_t qjs_get_length(JSContext *ctx, JSValueConst value, bool *ok);
JSValue qjs_new_number(JSContext *ctx, double value);
JSValue qjs_get_property_uint32(JSContext *ctx, JSValueConst obj, uint32_t index);
int qjs_set_property_uint32(JSContext *ctx, JSValueConst obj, uint32_t index, JSValue value);

/*
 * Host function bridge.
 *
 * JS_NewCFunctionData takes a C function pointer plus JSValueConst *func_data;
 * Swift's type checker cannot resolve that call (CI reports "type of expression
 * is ambiguous without a type annotation"), and @convention(c) may only annotate
 * function types, never func declarations. So the trampoline lives in this
 * translation unit and only untyped pointers cross the module boundary:
 * an unretained Swift context pointer and a function pointer cast to void *.
 */
void *qjs_host_bridge_new(void *swiftContext, void *call);
void qjs_host_bridge_free(void *bridge);

/* Creates a JS function whose C trampoline forwards to the bridge stored in
 * ctx's opaque pointer. |name| may be NULL. */
JSValue qjs_new_host_function(JSContext *ctx, const char *name, int length, int32_t identifier);

#ifdef __cplusplus
}
#endif

#endif /* QJS_SHIM_H */
