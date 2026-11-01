#include "qjs_shim.h"

#include <stdlib.h>

JSValue qjs_undefined(void)
{
    return JS_UNDEFINED;
}

JSValue qjs_null(void)
{
    return JS_NULL;
}

JSValue qjs_exception(void)
{
    return JS_EXCEPTION;
}

int qjs_eval_type_global(void)
{
    return JS_EVAL_TYPE_GLOBAL;
}

int qjs_eval_flag_compile_only(void)
{
    return JS_EVAL_FLAG_COMPILE_ONLY;
}

int qjs_gpn_string_mask(void)
{
    return JS_GPN_STRING_MASK;
}

int qjs_gpn_enum_only(void)
{
    return JS_GPN_ENUM_ONLY;
}

int qjs_prop_c_w_e(void)
{
    return JS_PROP_C_W_E;
}

bool qjs_is_null(JSValueConst value) { return JS_IsNull(value); }
bool qjs_is_undefined(JSValueConst value) { return JS_IsUndefined(value); }
bool qjs_is_exception(JSValueConst value) { return JS_IsException(value); }
bool qjs_is_uninitialized(JSValueConst value) { return JS_IsUninitialized(value); }
bool qjs_is_bool(JSValueConst value) { return JS_IsBool(value); }
bool qjs_is_number(JSValueConst value) { return JS_IsNumber(value); }
bool qjs_is_string(JSValueConst value) { return JS_IsString(value); }
bool qjs_is_object(JSValueConst value) { return JS_IsObject(value); }
bool qjs_is_array(JSValueConst value) { return JS_IsArray(value); }
bool qjs_is_function(JSContext *ctx, JSValueConst value) { return JS_IsFunction(ctx, value); }

int qjs_to_bool(JSContext *ctx, JSValueConst value)
{
    return JS_ToBool(ctx, value);
}

double qjs_to_double(JSContext *ctx, JSValueConst value, bool *ok)
{
    double number = 0;
    int status = JS_ToFloat64(ctx, &number, value);
    if (ok) *ok = (status == 0);
    return number;
}

double qjs_to_double_or(JSContext *ctx, JSValueConst value, double fallback)
{
    double number = 0;
    if (JS_ToFloat64(ctx, &number, value) != 0) return fallback;
    return number;
}

int64_t qjs_get_length(JSContext *ctx, JSValueConst value, bool *ok)
{
    int64_t length = 0;
    int status = JS_GetLength(ctx, value, &length);
    if (ok) *ok = (status == 0 && length >= 0);
    return length;
}

JSValue qjs_new_number(JSContext *ctx, double value)
{
    return JS_NewFloat64(ctx, value);
}

JSValue qjs_get_property_uint32(JSContext *ctx, JSValueConst obj, uint32_t index)
{
    return JS_GetPropertyUint32(ctx, obj, index);
}

int qjs_set_property_uint32(JSContext *ctx, JSValueConst obj, uint32_t index, JSValue value)
{
    return JS_SetPropertyUint32(ctx, obj, index, value);
}

/* ---- Host function bridge ---- */

typedef JSValue (*LegadoHostCall)(void *swiftContext, JSContext *ctx,
                                  JSValueConst thisVal, int argc,
                                  JSValueConst *argv, int32_t identifier);

typedef struct LegadoHostBridge {
    void *swiftContext;
    LegadoHostCall call;
} LegadoHostBridge;

/*
 * malloc / free instead of js_malloc / js_free on purpose: the bridge is owned by
 * the Swift context and must outlive JS_FreeRuntime. The runtime allocator would
 * reclaim it during JS_FreeRuntime, leaving the Swift side with a dangling handle.
 */
void *qjs_host_bridge_new(void *swiftContext, void *call)
{
    LegadoHostBridge *bridge = (LegadoHostBridge *)malloc(sizeof(LegadoHostBridge));
    if (!bridge) return NULL;
    bridge->swiftContext = swiftContext;
    bridge->call = (LegadoHostCall)call;
    return (void *)bridge;
}

void qjs_host_bridge_free(void *bridge)
{
    free(bridge);
}

static JSValue legado_host_trampoline(JSContext *ctx, JSValueConst thisVal, int argc,
                                      JSValueConst *argv, int magic, JSValueConst *funcData)
{
    (void)magic;
    LegadoHostBridge *bridge = (LegadoHostBridge *)JS_GetContextOpaque(ctx);
    if (!bridge || !bridge->call || !funcData) return JS_EXCEPTION;

    int32_t identifier = 0;
    if (JS_ToInt32(ctx, &identifier, funcData[0]) != 0) return JS_EXCEPTION;

    return bridge->call(bridge->swiftContext, ctx, thisVal, argc, argv, identifier);
}

JSValue qjs_new_host_function(JSContext *ctx, const char *name, int length, int32_t identifier)
{
    JSValue carrier = JS_NewInt32(ctx, identifier);
    /* JS_NewCFunctionData takes ownership of a dup of func_data, never of carrier. */
    JSValue function = JS_NewCFunctionData2(ctx, legado_host_trampoline, name, length,
                                            0, 1, &carrier);
    JS_FreeValue(ctx, carrier);
    return function;
}
