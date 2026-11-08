# QuickJS 迁移报告订正（2026-11-01）

本文保留迁移期间对 `quickjs-migration.md` 的实现订正，以及书源宿主 API 扩充记录。原始调试报告未纳入仓库；当前接口入口见 [JavaScript 宿主 API](javascript-host-api.md)，验证方式见 [开发指南](DEVELOPMENT.md)。以下历史结论应结合当前代码与测试阅读。

## 一、第五节订正：replacementEvaluator 不再复用字节码

原文：「共享 Runtime + 字节码只编译一次、每轮匹配只新建 Context」。

实际实现已废弃该做法：quickjs-ng 的 `JS_TAG_FUNCTION_BYTECODE` 绑定**编译时所在的 realm**（该 Context 的全局对象）。跨 Context 执行 `JS_EvalFunction` 时，脚本读到的仍是编译期 realm 的全局名，表现为逐条 `ReferenceError: java is not defined` / `result is not defined`，严重时因跨 realm 持有字节码在释放阶段崩溃（signal 11）。

现状：

- 仍共享 Runtime、每轮匹配新建 Context（保住「全局环境全新」）。
- jsLib 与替换脚本都在**同一个 Context 内**求值，不再跨 Context 复用字节码。
- 代价如实记录：jsLib 每轮重新解析一次。这与 JSC 版一致（那边同样每轮求值 jsLib），不是回归。
- 串行化不变：`NSLock` 覆盖「新建 Context → 注入宿主 → 求值 jsLib → 求值替换脚本」全过程。

## 二、第四节订正：宿主 API 清单补全

以下名字原文缺失，书源高频使用，缺一个在书源侧就是 `xxx is not a function`：

**`java`**：`getStringList`、`getElement`、`getElements`、`setContent`、`setBaseUrl`、`setRedirectUrl`、`getRedirectUrl`、`htmlFormat`、`md5Encode16`、`getUserAgent`、`importScript`、`aesEncodeToBase64`、`aesDecodeToString`

**`source`**：`getBookSourceUrl` / `getBookSourceName` / `getBookSourceGroup` / `getBookSourceType`、`enabledCookieJar`、`concurrentRate`、`coverDecodeJs`、`bookSourceComment`、`variableComment`、`removeLoginHeader`

**`book`**：`getIntro`、`getKind`、`getOrigin`、`getOriginName`、`getLatestChapterTitle`、`getDurChapterTitle`、`getDurChapterIndex`、`getVariable`、`getVariableMap`

**`chapter`**：`getBookUrl`、`getBaseUrl`、`getResourceUrl`、`getVariable`、`getTag`、`getWordCount`

**`org.jsoup` 元素对象**：`selectFirst`、`absUrl`、`hasAttr`、`ownText`、`val`、`parent`、`children`、`next`、`prev`、`tagName`、`id`、`className`、`eq`

注入顺序约束：`java.getElement` / `java.getElements` / `java.htmlFormat` 必须落在 `jsoupBridge`，因为 `javaBridge` 早于 `org.jsoup` 注入，在 `javaBridge` 里定义时拿不到解析器。

## 三、`getStringList` 的求值语义

不能对 `getString` 的结果按换行切分：正文与简介本身含换行，切分会把一条内容拆成多条，也会丢掉多命中之间的元素边界。

现行链路：`java.getStringList` → `java.__getStringList` → Swift `evaluateStringRuleValues`（真正的列表模式求值，逐命中一项）。`evaluateStringRule` 退化为 `evaluateStringRuleValues(...).joined(separator: "\n")` 的外壳，保持既有调用方契约不变。

## 四、SwiftSoup 2.13.5 签名取证

按 tag `2.13.5` 源码逐条核对结论：

| 方法 | 签名 | 处理 |
| --- | --- | --- |
| `Element.tagName()` | `-> String`，非 throws | 直接调用 |
| `Element.parent()` | `-> Element?`，非 throws | 直接调用 |
| `Node.parent()` | `-> Node?`，非 throws | 直接调用 |
| `Element.children()` | `-> Elements`（RandomAccessCollection） | for-in |
| `Element.ownText()` | `-> String`，非 throws | 直接调用 |
| `Element.val()` | `throws -> String` | `try?` |
| `Element.nextElementSibling()` | `throws -> Element?` | `try?`（原写法漏 try，编译期硬错误） |
| `Element.previousElementSibling()` | `throws -> Element?` | `try?`（同上） |
| `Node.hasAttr(_:)` | `-> Bool`，**非 throws** | 直接调用（原写法多加了 try，产生多余告警） |
| `Node.absUrl(_:)` | `throws -> String` | `try?`，失败回落 `attr` |
| `selectFirst` | 1.13.5 / 2.13.5 均无此 API | 宿主层用 `select` 取首元素自行实现 |

`Elements` 同时是 `RandomAccessCollection` 与 `Sequence`，因此 `select` 结果可直接 for-in；`first()` / `size()` / `last()` / `get(_:)` 均非 throws。

## 五、仍未验证

- 本机为 Windows，无 clang / swift / xcodebuild，编译与单测结论由 CI 的 `swiftpm` job（`swift build --build-tests` + `swift test`）与 `xcode-app` job 给出。**本文件不声称编译通过。**
- 嵌入 JS 胶水的语法检查已覆盖「原始字符串 + 普通多行字符串」两类（脚本 `Temps/check-glue-syntax.mjs`，`Temps/` 已加入 `.gitignore`）：`checked=8 failed=0`。该检查只验证语法，不验证运行时语义。

## 六、列表模式 `@js` 的数组语义

证据链：`RuleExpressionParser.parseBranch` 把 `@js:` 前缀识别为 `.javaScript`（`Sources/LegadoCore/RuleEngine/RuleExpression.swift:79`）；`evaluateStringRuleValues` 的 `.javaScript` 分支早期只取 `value.stringValue`。

问题：列表模式下 `@js` 常写成 `result.map(x => ...)`，返回的是**数组**。只取 `stringValue` 会把整组结果压成一条，`java.getStringList` 刚接上的真列表求值在 `@js` 入口又退化回单值，表现为「多命中只回第一条」。

现行处理：`.javaScript` 分支对 `.array` 按元素 `stringValue` 展开，其余类型仍产出单元素。标量含换行时不会被拆开（`java.getStringList` 不按 `\n` 切分）。

已知边界：中缀写法 `a@href@js:...` 由 `RuleEngine.splitJavaScriptPipeline` 在引擎层拆分，`java.getStringList` 内部按 `RuleExpressionParser` 解析、不拆中缀 `@js`；写规则时把 `@js` 放在最前或拆成分支。

## 七、`replacementEvaluator` 与 jsLib 的已知代价

jsLib 每轮匹配重新解析一次（见第一节）。这是语义要求，不是可优化项：`JS_TAG_FUNCTION_BYTECODE` 绑定编译期 realm，跨 Context 复用字节码会读到错的全局并在释放阶段崩溃。若要拿到加速，唯一安全路径是在同一 Context 内缓存「编译产物 + 该 realm 的全局」并在需要全新全局时重建——这属于后续独立设计，不在本轮范围。
