import Foundation

/// Rhino 兼容层：注入 QuickJS Context 的纯 JS 胶水。
///
/// 这些脚本与具体引擎无关——它们只依赖宿主函数（`__legado*`）与标准 JS，
/// 因此在 JSC → QuickJS 迁移中**原样保留**，只把原 `@convention(block)`
/// 原生 block 换成 QuickJS host function。这样做的好处是书源语义零漂移：
/// 书源作者实际依赖的是这套 JS 形状（`with (javaImport) { ... }`、
/// `new SecretKeySpec(...)`、`Cipher.getInstance('AES/CBC/PKCS5Padding')`），
/// 重写等价 JS 只会引入新的行为差异。
///
/// 注入顺序要求（不能打乱）：
/// 1. `consoleBridge`：依赖 `__legadoLog`；后续脚本里的调试输出依赖它。
/// 2. `jsonParsePatch`：书源常在 `java.ajax` 结果上直接 `JSON.parse`，
///    需要在任何脚本执行前就打好补丁。
/// 3. `cookieBridge`：依赖 `cookie.*` 宿主函数。
/// 4. `javaBridge`：依赖 `java.__directRequest` / `java.__getString` 等宿主函数，
///    并把 `java.get` 从「取变量」重载为「取变量或发请求」。
/// 5. `sourceBridge`：依赖 `source.__getLoginInfoMap`。
/// 6. `javaImporter`：依赖 `__legadoUTF8Bytes` / `__legadoAESCBC` /
///    `__legadoHmacSHA1` / `__legadoBase64*` / `__legadoHexEncodeBytes` /
///    `__legadoFormURLEncode`，必须先于 jsLib 与规则脚本注入。
enum RhinoCompatibilityScripts {

    /// `JSON.parse` 的 Legado 宽容语义：去 BOM、去首尾空白，
    /// 非 JSON 文本原样返回（服务端返回纯文本错误页时不能让脚本直接崩）。
    static let jsonParsePatch = #"""
        (function () {
          var nativeParse = JSON.parse;
          JSON.parse = function (value) {
            if (typeof value !== 'string') return value;
            var text = value;
            if (text.charCodeAt(0) === 0xFEFF) text = text.slice(1);
            text = text.trim();
            if (!text || '[{"-0123456789tfn'.indexOf(text.charAt(0)) < 0) return value;
            return nativeParse(text);
          };
        })();
        """#

    /// `console.log/warn/error` 统一落到 `__legadoLog`，由 Swift 侧写诊断日志。
    static let consoleBridge = #"""
        var console = {
          log: function() { __legadoLog(Array.prototype.join.call(arguments, ' ')); },
          warn: function() { __legadoLog(Array.prototype.join.call(arguments, ' ')); },
          error: function() { __legadoLog(Array.prototype.join.call(arguments, ' ')); }
        };
        """#

    /// `cookie.*` 的 map/header 互转，纯 JS 无需宿主函数（除 `cookie.getCookie` 等）。
    static let cookieBridge = #"""
        (function () {
          cookie.cookieToMap = function (header) {
            var map = {};
            String(header || '').split(';').forEach(function (part) {
              var separator = part.indexOf('=');
              if (separator <= 0) return;
              var key = part.slice(0, separator).trim();
              var value = part.slice(separator + 1).trim();
              if (value || value === 'null') map[key] = value;
            });
            return map;
          };
          cookie.mapToCookie = function (map) {
            if (!map) return null;
            var values = [];
            for (var key in map) {
              if (Object.prototype.hasOwnProperty.call(map, key)) {
                values.push(key + '=' + map[key]);
              }
            }
            return values.length ? values.join('; ') : null;
          };
        })();
        """#

    /// `java.*` 的高层重载。`java.get` 是双义的：单参数且不像 URL 时取变量，
    /// 否则当 GET 请求——这是 Legado 书源里极常见的写法，不能拆成两个函数。
    static var javaBridge: String {
        """
        (function () {
          var getVariable = java.get;
          function responseOf(raw) {
            if (raw.error) throw new Error(raw.error);
            return {
              statusCode: function () { return raw.code; },
              body: function () { return raw.bodyText; },
              header: function (name) {
                var wanted = String(name).toLowerCase();
                for (var key in raw.headers) if (key.toLowerCase() === wanted) return raw.headers[key];
                return null;
              },
              headers: function () { return raw.headers; },
              url: function () { return { toString: function () { return raw.urlText; } }; }
            };
          }
          java.get = function (url, headers, timeout) {
            var target = String(url);
            var networkURL = /^(https?:|data:)/i.test(target) || target[0] === '/' ||
              target.indexOf('./') === 0 || target.indexOf('../') === 0;
            if (arguments.length === 1 && !networkURL) {
              return getVariable(target);
            }
            return responseOf(java.__directRequest('GET', target, null, headers || {}, timeout));
          };
          // `java.setContent()` 之后，不带 content 的 `java.getString(rule)` 必须读到
          // 刚设置的内容而不是全局 `src`——这是 Legado 的既定语义，顺序反过来会让
          // 「先 setContent 再连续取字段」整段落空。
          var contentOverride = null;
          var baseUrlOverride = null;
          var redirectUrl = null;
          // 这两个取值器挂到全局：`java.getString`、`java.getElement(s)` 与 jsoupBridge
          // 都必须按同一份「当前内容 / 当前 baseUrl」解析，各自读 `src` 迟早分叉。
          var root = globalThis;
          root.__legadoCurrentContent = function () {
            return contentOverride !== null ? contentOverride : src;
          };
          root.__legadoCurrentBaseUrl = function () {
            if (baseUrlOverride !== null) return baseUrlOverride;
            return typeof baseUrl === 'string' ? baseUrl : '';
          };
          function bytesOf(value) {
            if (Array.isArray(value)) return value;
            return __legadoUTF8Bytes(String(value == null ? '' : value));
          }
          java.getString = function (rule, content, isUrl) {
            var absent = arguments.length < 2 || content == null;
            var input = absent && contentOverride !== null ? contentOverride : (absent ? src : content);
            return java.__getString(
              String(rule == null ? '' : rule),
              input,
              Boolean(isUrl)
            );
          };
          // 必须走真正的列表模式求值，不能对 getString 的结果按换行切分：
          // 正文与简介本身含换行，切分会把一条内容拆成多条，也会丢掉多命中之间的边界。
          java.getStringList = function (rule, content, isUrl) {
            var absent = arguments.length < 2 || content == null;
            var input = absent ? root.__legadoCurrentContent() : content;
            var values = java.__getStringList(String(rule == null ? '' : rule), input, Boolean(isUrl));
            if (Array.isArray(values)) return values;
            if (values == null) return [];
            return [String(values)];
          };
          java.setContent = function (content, base) {
            contentOverride = String(content == null ? '' : content);
            if (base != null) baseUrlOverride = String(base);
            return java;
          };
          java.setBaseUrl = function (url) {
            baseUrlOverride = url == null ? null : String(url);
            return java;
          };
          java.setRedirectUrl = function (url) {
            redirectUrl = String(url == null ? '' : url);
            return java;
          };
          java.getRedirectUrl = function () { return redirectUrl; };
          // `md5Encode16` 是 Legado 的「16 位 md5」别名：取 32 位结果的中段 16 位，
          // 不是新算法。签名站点常直接写这个名字。
          java.md5Encode16 = function (text) {
            return java.md5Encode(String(text == null ? '' : text)).substring(8, 24);
          };
          java.getUserAgent = function () { return String(__legadoUserAgent || ''); };
          java.importScript = function (url) {
            var script = java.ajax(String(url));
            if (typeof script !== 'string' || !script) return null;
            (0, eval)(script);
            return script;
          };
          // AES 便利方法：`__legadoAESCBC` 的入参是 Java byte[]，
          // 书源侧传的是字符串，这里统一按 UTF-8 转字节，key/iv 同规则。
          java.aesEncodeToBase64 = function (content, key, iv) {
            var output = __legadoAESCBC(1, bytesOf(key), bytesOf(iv), bytesOf(content));
            if (!Array.isArray(output)) throw new Error('AES/CBC operation failed');
            return __legadoBase64EncodeBytes(output);
          };
          java.aesDecodeToString = function (content, key, iv) {
            var input = Array.isArray(content)
              ? content
              : __legadoBase64DecodeBytes(String(content == null ? '' : content));
            var output = __legadoAESCBC(2, bytesOf(key), bytesOf(iv), input);
            if (!Array.isArray(output)) throw new Error('AES/CBC operation failed');
            return __legadoUTF8String(output);
          };
          java.head = function (url, headers, timeout) {
            return responseOf(java.__directRequest('HEAD', String(url), null, headers || {}, timeout));
          };
          java.post = function (url, body, headers, timeout) {
            return responseOf(java.__directRequest('POST', String(url), body, headers || {}, timeout));
          };
          java.getCookie = function (tag, key) {
            return arguments.length < 2 || key == null
              ? java.getCookieHeader(String(tag))
              : java.__getCookieValue(String(tag), String(key));
          };
          java.getSource = function () { return typeof source === 'undefined' ? null : source; };
          java.getWebViewUA = function () { return String(__legadoUserAgent || ''); };
          java.getHeaderMap = function () {
            var map = typeof source === 'undefined' ? {} : source.getHeaderMap(true);
            map.put = function (key, value) { map[String(key)] = String(value); return value; };
            map.putAll = function (other) { for (var key in other) if (typeof other[key] !== 'function') map[key] = other[key]; };
            return map;
          };
          java.ajaxTestAll = function (urls, timeout) {
            return java.ajaxAll(urls, timeout).map(function (raw) {
              var bodyText = raw.body;
              raw.callTime = function () { return raw.code >= 200 && raw.code < 300 ? 0 : -1; };
              raw.body = function () { return bodyText; };
              return raw;
            });
          };
          java.clearTtsCache = function () { return true; };
        })();
        """
    }

    /// `source.*` 的辅助方法：`getKey` / `getTag` / `getLoginInfoMap` / `login`。
    /// `login` 用间接 `eval` 让登录脚本落在全局作用域，随后取全局 `login()`。
    static let sourceBridge = #"""
        (function () {
          source.getKey = function () { return source.bookSourceUrl; };
          source.getTag = function () { return source.bookSourceName; };
          source.getLoginInfoMap = function () {
            var map = source.__getLoginInfoMap() || {};
            map.get = function (key) { return map[String(key)]; };
            map.put = function (key, value) { map[String(key)] = value; return value; };
            map.putAll = function (other) { for (var key in other) if (typeof other[key] !== 'function') map[key] = other[key]; };
            return map;
          };
          source.login = function () {
            if (!source.loginUrl) return null;
            (0, eval)(String(source.loginUrl));
            return typeof login === 'function' ? login() : null;
          };
        })();
        """#

    /// JavaImporter / Packages 兼容层。
    ///
    /// 只放行书源实际用到的有限类族（String / Base64 / Arrays / URLEncoder /
    /// DatatypeConverter / Cipher / Mac / SecretKeySpec / IvParameterSpec），
    /// 且全部 `Object.freeze`——`javaImporterDoesNotExposeArbitraryNativeClasses`
    /// 测试断言 `Packages.java.lang.Runtime` 必须为 undefined，这条不能破。
    static let javaImporter = #"""
        (function (global) {
          'use strict';
          var NativeString = global.String;
          global.__legadoUnboxString = function (value) {
            return Object.prototype.toString.call(value) === '[object String]' ? NativeString(value) : value;
          };
          function javaClass(name, value) {
            Object.defineProperty(value, '__javaSimpleName', { value: name });
            return Object.freeze(value);
          }
          function checkedBytes(value) {
            if (!Array.isArray(value)) throw new TypeError('Java byte[] required');
            return value;
          }
          function JavaString(value) {
            var text = new NativeString(Array.isArray(value) ? __legadoUTF8String(value) : (value == null ? '' : value));
            Object.defineProperty(text, 'getBytes', {
              value: function (charset) {
                if (charset && !/^utf-?8$/i.test(NativeString(charset))) {
                  throw new Error('Unsupported charset: ' + charset);
                }
                return __legadoUTF8Bytes(NativeString(this));
              }
            });
            return text;
          }
          function SecretKeySpec(bytes, algorithm) {
            if (!(this instanceof SecretKeySpec)) return new SecretKeySpec(bytes, algorithm);
            this.key = checkedBytes(bytes).slice();
            this.algorithm = NativeString(algorithm || '');
            Object.freeze(this.key);
            Object.freeze(this);
          }
          function IvParameterSpec(bytes) {
            if (!(this instanceof IvParameterSpec)) return new IvParameterSpec(bytes);
            this.bytes = checkedBytes(bytes).slice();
            if (this.bytes.length !== 16) throw new Error('AES IV must contain 16 bytes');
            Object.freeze(this.bytes);
            Object.freeze(this);
          }
          var Cipher = javaClass('Cipher', {
            ENCRYPT_MODE: 1,
            DECRYPT_MODE: 2,
            getInstance: function (algorithm) {
              if (NativeString(algorithm).toUpperCase() !== 'AES/CBC/PKCS5PADDING') {
                throw new Error('Unsupported Cipher algorithm: ' + algorithm);
              }
              var key = null, iv = null, operation = null;
              return {
                init: function (mode, spec, parameters) {
                  if ((mode !== 1 && mode !== 2) || !(spec instanceof SecretKeySpec) ||
                      spec.algorithm.toUpperCase() !== 'AES' || !(parameters instanceof IvParameterSpec)) {
                    throw new TypeError('AES key, IV and cipher mode required');
                  }
                  operation = mode; key = spec.key; iv = parameters.bytes;
                },
                doFinal: function (bytes) {
                  if (key === null) throw new Error('Cipher not initialized');
                  var result = __legadoAESCBC(operation, key, iv, checkedBytes(bytes));
                  if (!Array.isArray(result)) throw new Error('AES/CBC operation failed');
                  return result;
                }
              };
            }
          });
          var Mac = javaClass('Mac', {
            getInstance: function (algorithm) {
              if (NativeString(algorithm).toUpperCase() !== 'HMACSHA1') {
                throw new Error('Unsupported Mac algorithm: ' + algorithm);
              }
              var key = null;
              return {
                init: function (spec) {
                  if (!(spec instanceof SecretKeySpec) || spec.algorithm.toUpperCase() !== 'HMACSHA1') {
                    throw new TypeError('HmacSHA1 SecretKeySpec required');
                  }
                  key = spec.key;
                },
                doFinal: function (bytes) {
                  if (key === null) throw new Error('Mac not initialized');
                  return __legadoHmacSHA1(key, checkedBytes(bytes));
                }
              };
            }
          });
          javaClass('SecretKeySpec', SecretKeySpec);
          javaClass('IvParameterSpec', IvParameterSpec);
          javaClass('String', JavaString);
          var Base64 = javaClass('Base64', {
            DEFAULT: 0,
            NO_WRAP: 2,
            encodeToString: function (bytes) { return __legadoBase64EncodeBytes(checkedBytes(bytes)); },
            decode: function (value) { return __legadoBase64DecodeBytes(NativeString(value)); },
            getDecoder: function () { return Object.freeze({ decode: this.decode }); },
            getEncoder: function () { return Object.freeze({ encodeToString: this.encodeToString }); }
          });
          var Arrays = javaClass('Arrays', {
            copyOfRange: function (bytes, from, to) {
              checkedBytes(bytes);
              if (!Number.isInteger(from) || !Number.isInteger(to) || from < 0 || from > bytes.length || to < from || to - from > 2097152) {
                throw new RangeError('Invalid byte array range');
              }
              var copied = bytes.slice(from, to);
              while (copied.length < to - from) copied.push(0);
              return copied;
            }
          });
          var URLEncoder = javaClass('URLEncoder', {
            encode: function (value, charset) {
              if (charset && !/^utf-?8$/i.test(NativeString(charset))) {
                throw new Error('Unsupported charset: ' + charset);
              }
              return __legadoFormURLEncode(NativeString(value));
            }
          });
          var DatatypeConverter = javaClass('DatatypeConverter', {
            printBase64Binary: function (bytes) { return __legadoBase64EncodeBytes(checkedBytes(bytes)); },
            parseBase64Binary: function (value) { return __legadoBase64DecodeBytes(NativeString(value)); },
            printHexBinary: function (bytes) { return __legadoHexEncodeBytes(checkedBytes(bytes)); }
          });
          var packages = {
            javax: {
              crypto: { Mac: Mac, Cipher: Cipher, spec: { SecretKeySpec: SecretKeySpec, IvParameterSpec: IvParameterSpec } },
              xml: { bind: { DatatypeConverter: DatatypeConverter } }
            },
            java: { net: { URLEncoder: URLEncoder }, lang: { String: JavaString }, util: { Base64: Base64, Arrays: Arrays } },
            android: { util: { Base64: Base64 } }
          };
          Object.freeze(packages.javax.crypto.spec);
          Object.freeze(packages.javax.crypto);
          Object.freeze(packages.javax.xml.bind);
          Object.freeze(packages.javax.xml);
          Object.freeze(packages.javax);
          Object.freeze(packages.java.net);
          Object.freeze(packages.java.lang);
          Object.freeze(packages.java.util);
          Object.freeze(packages.java);
          Object.freeze(packages.android.util);
          Object.freeze(packages.android);
          global.Packages = Object.freeze(packages);
          global.JavaImporter = Object.freeze(function () {
            var imported = Object.create(null);
            var allowedPackages = [packages.java.lang, packages.java.net, packages.java.util,
              packages.javax.crypto, packages.javax.crypto.spec, packages.javax.xml.bind, packages.android.util];
            function addClass(value) {
              if (!value || typeof value.__javaSimpleName !== 'string') throw new TypeError('Unsupported Java class import');
              if (!Object.prototype.hasOwnProperty.call(imported, value.__javaSimpleName)) {
                Object.defineProperty(imported, value.__javaSimpleName, { value: value, enumerable: true });
              }
            }
            function addPackage(value) {
              if (allowedPackages.indexOf(value) < 0) throw new TypeError('Unsupported Java package import');
              Object.keys(value).forEach(function (name) {
                if (value[name] && typeof value[name].__javaSimpleName === 'string') addClass(value[name]);
              });
            }
            Object.defineProperty(imported, 'importPackage', { value: function () {
              for (var i = 0; i < arguments.length; i++) addPackage(arguments[i]);
            }});
            Object.defineProperty(imported, 'importClass', { value: function () {
              for (var i = 0; i < arguments.length; i++) addClass(arguments[i]);
            }});
            for (var index = 0; index < arguments.length; index++) {
              var value = arguments[index];
              if (allowedPackages.indexOf(value) >= 0) addPackage(value); else addClass(value);
            }
            return imported;
          });
        })(this);
        """#

    /// `org.jsoup.Jsoup` 兼容层。
    ///
    /// Legado/Rhino 里 `org` 是顶层可见包名，书源会直接写
    /// `org.jsoup.Jsoup.parse(result)`，继而 `select(...)` / `remove()` / `html()`。
    /// 这里把每个文档与元素集合包成整数句柄交给 Swift 侧的 SwiftSoup 桥，
    /// JS 只保留与 jsoup 同形的方法名——CSS 选择器解析、DOM 删除与序列化
    /// 都不能用 JS 假装实现，否则正文会悄悄变质（比如 script/style 没被移除）。
    ///
    /// 依赖的宿主函数：`__legadoJsoupParse` / `Select` / `Remove` / `Html` /
    /// `Text` / `OuterHtml` / `Attr` / `Size` / `First`，必须先于本脚本注入。
    static let jsoupBridge = #"""
        (function (global) {
          'use strict';
          // 先取原生 String 再做别的：`wrap` 内部会用到它，
          // 写成「后声明、靠调用时机侥幸已赋值」是隐患（脚本一旦提前触发 wrap 就会拿到 undefined）。
          var NativeString = String;
          var NativeArray = Array;
          // 元素对象要同时承担两种历史写法：既当 jsoup Element（select/attr/text/html），
          // 又当 HTML 文本（replace/indexOf/split/正则）。列表模式下 `@css:…@js:` 的
          // result 在 Legado 里就是 Element 数组，但社区书源里两种用法都有。
          var textMethods = ['indexOf', 'lastIndexOf', 'includes', 'startsWith', 'endsWith',
            'replace', 'replaceAll', 'match', 'search', 'split', 'trim', 'trimStart', 'trimEnd',
            'substring', 'substr', 'slice', 'toLowerCase', 'toUpperCase', 'charAt', 'concat', 'localeCompare'];
          function wrap(handle) {
            var node = {
              select: function (selector) {
                return wrap(__legadoJsoupSelect(handle, NativeString(selector)));
              },
              selectFirst: function (selector) {
                return wrap(__legadoJsoupSelectFirst(handle, NativeString(selector)));
              },
              remove: function () {
                __legadoJsoupRemove(handle);
                return this;
              },
              html: function () { return __legadoJsoupHtml(handle); },
              text: function () { return __legadoJsoupText(handle); },
              ownText: function () { return __legadoJsoupOwnText(handle); },
              outerHtml: function () { return __legadoJsoupOuterHtml(handle); },
              attr: function (name) { return __legadoJsoupAttr(handle, NativeString(name)); },
              hasAttr: function (name) { return __legadoJsoupHasAttr(handle, NativeString(name)); },
              // `absUrl` 与 `attr` 必须分开：`attr('href')` 给相对路径，
              // 书源写 `absUrl('href')` 就是要绝对地址，混成一个方法会让翻页链接失效。
              absUrl: function (name) { return __legadoJsoupAbsUrl(handle, NativeString(name)); },
              id: function () { return __legadoJsoupId(handle); },
              className: function () { return __legadoJsoupClassName(handle); },
              tagName: function () { return __legadoJsoupTagName(handle); },
              val: function () { return __legadoJsoupVal(handle); },
              parent: function () { return wrap(__legadoJsoupParent(handle)); },
              children: function () { return wrap(__legadoJsoupChildren(handle)); },
              next: function () { return wrap(__legadoJsoupNext(handle)); },
              prev: function () { return wrap(__legadoJsoupPrev(handle)); },
              size: function () { return __legadoJsoupSize(handle); },
              first: function () { return wrap(__legadoJsoupFirst(handle)); },
              last: function () { return wrap(__legadoJsoupGet(handle, -1)); },
              get: function (index) { return wrap(__legadoJsoupGet(handle, index == null ? 0 : index)); },
              eq: function (index) { return wrap(__legadoJsoupGet(handle, index == null ? 0 : index)); },
              hasClass: function (name) {
                return (' ' + __legadoJsoupAttr(handle, 'class') + ' ').indexOf(' ' + NativeString(name) + ' ') >= 0;
              },
              each: function (callback) {
                var total = __legadoJsoupSize(handle);
                for (var index = 0; index < total; index++) {
                  if (callback.call(this, index, wrap(__legadoJsoupGet(handle, index))) === false) break;
                }
                return this;
              },
              // jsoup 的 Elements 是 List：`.forEach(a => ...)` 的第一个参数是元素，
              // 不是下标。起点目录脚本就是 `$[i].select("li").forEach(a => a.select("a"))`，
              // 传成 (index, element) 会让 `a.select` 变成 undefined 而整段脚本抛错。
              // jQuery 风格的 `.each((index, el) => ...)` 由 each() 单独承担。
              forEach: function (callback) {
                var total = __legadoJsoupSize(handle);
                for (var index = 0; index < total; index++) {
                  callback(wrap(__legadoJsoupGet(handle, index)), index);
                }
                return node;
              }
            };
            textMethods.forEach(function (name) {
              if (node[name] !== undefined) return;
              node[name] = function () {
                return String.prototype[name].apply(node.outerHtml(), arguments);
              };
            });
            // `length` 走集合语义（元素个数）：书源写 `list.length` 是在数节点，
            // 不是数字符。要字符数自己走 `node.html().length`。
            Object.defineProperty(node, 'length', {
              get: function () { return __legadoJsoupSize(handle); }
            });
            // 书源常写 String(node)，jsoup 语义下应得到 outerHtml。
            node.toString = node.outerHtml;
            return node;
          }
          // 列表模式的 result 提升入口：只提升看起来像 HTML 片段的字符串。
          global.__legadoWrapHtmlNodes = function (list) {
            if (!NativeArray.isArray(list)) return list;
            return list.map(function (item) {
              if (typeof item !== 'string') return item;
              if (item.replace(/^\s+/, '').charAt(0) !== '<') return item;
              // baseUrl 必须取「当前值」：`java.setBaseUrl()` 改过之后再提升元素，
              // 用全局 `baseUrl` 会让相对链接按旧基址解析。
              var base = typeof __legadoCurrentBaseUrl === 'function' ? __legadoCurrentBaseUrl() : '';
              return wrap(__legadoJsoupParse(item, base));
            });
          };
          var Jsoup = Object.freeze({
            parse: function (html, baseUri) {
              // 未显式给 baseUri 时取「当前 baseUrl」：`java.setBaseUrl()` 改过之后再 parse，
              // 读全局 `baseUrl` 会让相对链接按旧基址解析，absUrl 跟着整片偏掉。
              var currentBase = typeof __legadoCurrentBaseUrl === 'function'
                ? __legadoCurrentBaseUrl()
                : (typeof baseUrl === 'string' ? baseUrl : '');
              return wrap(__legadoJsoupParse(
                NativeString(html == null ? '' : html),
                NativeString(baseUri == null ? currentBase : baseUri)
              ));
            }
          });
          var org = {};
          org.jsoup = Object.freeze({ Jsoup: Jsoup });
          global.org = Object.freeze(org);

          // `java.getElement` / `java.getElements` / `java.htmlFormat` 依赖真实 Jsoup，
          // 所以只能在本脚本里定义：`javaBridge` 早于 `org` 注入，在那里定义拿不到解析器。
          global.__legadoSelectElements = function (rule) {
            var content = typeof __legadoCurrentContent === 'function' ? __legadoCurrentContent() : src;
            var html = typeof content === 'string' ? content : NativeString(content == null ? '' : content);
            var base = typeof __legadoCurrentBaseUrl === 'function' ? __legadoCurrentBaseUrl() : '';
            return Jsoup.parse(html, base).select(NativeString(rule == null ? '' : rule));
          };
          if (global.java) {
            global.java.getElements = function (rule) {
              return global.__legadoSelectElements(NativeString(rule == null ? '' : rule));
            };
            global.java.getElement = function (rule) {
              return global.java.getElements(rule).first();
            };
            global.java.htmlFormat = function (html) {
              var text = NativeString(html == null ? '' : html);
              if (!text) return text;
              // 用 body 内层 HTML 而不是整份 outerHtml：后者会带上
              // `<html><head></head><body>` 外壳，书源把它拼进正文模板就会多出这层标签。
              var base = typeof __legadoCurrentBaseUrl === 'function' ? __legadoCurrentBaseUrl() : '';
              var bodies = Jsoup.parse(text, base).select('body');
              // first() 可能为 null（例如输入根本不是 HTML），此时不能再调 .html()：
              // wrap(null) 虽然不会崩，但语义上应当原样返回输入，而不是返回空串。
              if (bodies.size() === 0) return text;
              return bodies.first().html();
            };
          }
        })(this);
        """#
}
