# book source JS host API（QuickJS 引擎）

本文件是 `Sources/LegadoCore/JavaScript/` 的对外契约清单。书源作者依赖的是这套**名字与形状**，改任意一条都是全量书源失效，不是风格差异。

## 全局值

`result`、`src`、`$`、`baseUrl`、`key`、`page`、`title`、`book`、`chapter`、`source`（有书源上下文时）、`java`、`cookie`、`console`、`org.jsoup`、`Packages`、`JavaImporter`

## `java.*`

**变量**：`get`（双义：单参数且不像 URL 时取变量，否则发 GET）、`put`、`putVolume`

**规则二次求值**：`getString(rule, content?, isUrl?)`、`getStringList(rule, content?, isUrl?)`、`getElement(rule)`、`getElements(rule)`、`setContent(content, baseUrl?)`、`setBaseUrl(url)`、`setRedirectUrl(url)`、`getRedirectUrl()`

**编码 / 字节**：`md5Encode`、`md5Encode16`、`base64Encode`、`base64Decode`、`base64DecodeToByteArray`、`strToBytes`、`bytesToStr`、`hexDecodeToByteArray`、`hexDecodeToString`、`hexEncodeToString`、`encodeURI`、`aesEncodeToBase64`、`aesDecodeToString`、`htmlFormat`

**时间 / 标识**：`timeFormatUTC`、`timeFormat`、`randomUUID`、`androidId`、`getTag`

**网络**：`ajax`、`ajaxAll`、`ajaxTestAll`、`connect`、`get`、`head`、`post`

**Cookie / 头**：`getCookie`、`getCookieHeader`、`setCookie`、`getHeaderMap`

**其它**：`getSource`、`getWebViewUA`、`getUserAgent`、`importScript`、`log` / `logType` / `toast`、`longToast`、`startBrowser`、`webView`、`clearTtsCache`

## `cookie.*`

`getCookie(url)`、`getKey(url, key)`、`setCookie(url, value)`、`replaceCookie`、`setWebCookie`、`removeCookie(url)`、`cookieToMap(header)`、`mapToCookie(map)`

## `source.*`

属性：`bookSourceName`、`bookSourceUrl`、`bookSourceGroup`、`bookSourceType`、`bookUrlPattern`、`customOrder`、`enabled`、`enabledExplore`、`header`、`loginUrl`、`searchUrl`、`exploreUrl`、`respondTime`、`weight`、`enabledCookieJar`、`concurrentRate`、`coverDecodeJs`、`bookSourceComment`、`variableComment`

方法：`get` / `put`、`getKey`、`getTag`、`getBookSourceUrl` / `getBookSourceName` / `getBookSourceGroup` / `getBookSourceType`、`getLoginHeader` / `putLoginHeader` / `removeLoginHeader`、`getLoginInfoMap` / `putLoginInfo`、`getHeaderMap(includeLogin)`、`login`

## `book.*` / `chapter.*`

- `book`：同 `Book` 模型字段 + `getName` / `getAuthor` / `getBookUrl` / `getCoverUrl` / `getTotalChapterNum` / `getIntro` / `getKind` / `getOrigin` / `getOriginName` / `getLatestChapterTitle` / `getDurChapterTitle` / `getDurChapterIndex` / `getVariable` / `getVariableMap`
- `chapter`：同 `BookChapter` 模型字段 + `getTitle` / `getIndex` / `getUrl` / `getBookUrl` / `getBaseUrl` / `getResourceUrl` / `getVariable` / `getTag` / `getWordCount`

## `org.jsoup` 元素对象

`select`、`selectFirst`、`remove`、`html`、`text`、`ownText`、`outerHtml`、`attr`、`absUrl`、`hasAttr`、`id`、`className`、`tagName`、`val`、`parent`、`children`、`next`、`prev`、`size`、`first`、`last`、`get`、`eq`、`hasClass`、`each`、`forEach`；`length` 走集合语义，`toString()` = `outerHtml()`。

文本方法（`indexOf` / `replace` / `split` / 正则等）落在 `outerHtml()` 上，兼容「把元素当 HTML 文本用」的历史写法。

## 刻意保留的语义

- `java.ajax` 失败返回错误描述**文本**，不抛异常（书源常把它直接喂 `java.getString`）。
- `java.get/head/post` 返回带 `urlText` / `bodyText` / `code` / `headers` 的对象。
- `java.connect` 返回带 `successful` / `message` / `callTime` 的对象。
- `java.get('bookName')` / `java.get('title')` 优先于同名规则变量。
- `java.getStringList` 走真正的列表模式求值，不按 `\n` 切分（正文/简介本身含换行）。
- `Java byte[]` 逐字节保留 `Int8(bitPattern:)` 有符号语义。
- 两套存储不合并：`source.get/put` → `BookSourceRuntimeStore`（跨执行持久化）；`java.get/put` → `JavaScriptVariableBox`（单次规则内共享、替换多轮复用）。
- 同步语义：不引入 Promise。

## `java.getString` / `java.getStringList` 支持的规则形态

两者都回到 Swift 侧走 `RuleExpressionParser`，因此支持：CSS（含 `@@` 前缀）、`@xpath:`、`@json:`、`:正则`、`@js:` / `<js></js>` 前缀，以及 `##正则##替换` 后处理。

差异只在收口方式：

- `java.getString` → `evaluateStringRuleValues(...).joined(separator: "\n")`；
- `java.getStringList` → 原样返回 `[String]`，逐命中一项；`@js` 返回**数组**时按元素展开，返回标量时仍是单元素（不会把含换行的内容拆开）。

**已知边界**：`a@href@js:...` 这种「CSS 中缀 + `@js` 后缀」写法由 `RuleEngine.splitJavaScriptPipeline` 在引擎层拆分（规则整体求值时生效）；`java.getStringList` 内部按 `RuleExpressionParser` 解析，不拆中缀 `@js`。写法上应把 `@js` 放在规则最前面（`@js:...`）或改用两个分支，别依赖中缀后缀。

## 资源限制

规则 1 MB / jsLib 4 MB / 返回值 2 MB（均按 UTF-8 字节数）、内存 = 载荷 + 32 MB、栈 = max(2 MB, 1 MB + jsLib/4)、时间 5 s（`JS_SetInterruptHandler` + 真实截止时间，编译期同样挂 deadline）。
