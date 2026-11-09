# 自有书源协议 v1：候选合同

初版：2026-11-08；状态核对：2026-11-09。用于实验实现与一致性验证，尚未冻结为 App 的已发布 API；当前工作与验收范围见 [实施流程](../../docs/SOURCE_PROTOCOL_IMPLEMENTATION_PLAN.md)。

本目录将[协议草案](../../docs/SOURCE_PROTOCOL_V1_DRAFT.md)细化为可运行的检查与共享语料。数据结构以 `schema.json` 为准；以下文字约束补充 JSON Schema 无法表达的语义。两者冲突时是规范缺陷，必须修改并增加样本，不能任意选择一端。

## 1. 文件与使用

| 文件 | 作用 |
| --- | --- |
| `schema.json` | Draft 2020-12 数据合同；输入、结果、元数据、配置、错误 |
| `profile.json` | ECMAScript 语法版本、数据/解析上限和原型实验预算 |
| `types.generated.d.ts` | 从 Schema 生成的数据类型，不手工修改 |
| `context.d.ts` | 手写宿主方法与操作签名；引用生成的数据类型，不重复定义实体 |
| `fixtures/` | 自造 HTML/JSON 响应、源文件、静态正反例、故障和迁移样本 |
| [协议工具](../../tools/source-protocol/README.md) | validator、类型生成、本地服务和测试命令 |

所有数值上限都是候选保护边界。它们让样本可测试，不代表已取得 iOS 性能证据；修改需同步 profile、说明、两端测试和后续设备报告。当前没有已开放的可选扩展，`requires` 中未知的版本化能力会阻止安装。

## 2. 模块和静态导入

- UTF-8，自包含 ES Module；语法暂定 ECMAScript 2022。语法可解析不等于所有对应 Web API 已在 iOS profile 放行。
- 恰好一个直接的 `export const metadata = {...}`。允许注释、尾逗号、普通字符串键；值为 JSON 字面量，负数可用一元 `-` 表示。
- 拒绝函数调用、变量引用、展开、计算属性、getter/setter、简写属性、模板字面量、重复键和数组空位。对象键 `__proto__`、`prototype`、`constructor` 也拒绝，以避免不同端的对象语义歧义。
- 固定入口是 `book`、`chapters`、`content` 和可选 `search`，必须静态绑定到 async 非生成器函数。支持直接函数/const 函数导出和本地函数别名导出；不接受通过函数调用生成入口。
- 当前候选拒绝 default 导出、未知导出、外部静态导入、转导出、动态 import 和顶层 await。helper 保留在模块内部。后续扩展入口要先有版本化定义。
- 未知 metadata/业务结果字段拒绝；普通 `Json` 状态允许自定义键。可选字段省略，不用 null 代替可选字符串；cursor/state 的 null 是合法 JSON。破坏性变更要升级协议主版本。
- parser 有文件字节、AST 节点/深度、worker 内存与 deadline 边界。Node worker 的实现不代表 iOS parser 已实现相同资源限制，也不是运行任意源代码的沙箱。
- 静态检查只判定形状和声明；导入通过不执行顶层，不证明模块初始化安全、网站可用或运行期入口未被重新赋值。执行时还需检查 namespace、CSP、网络入口和能力策略。

静态导入器使用 Acorn 8.19.0，Schema 校验使用 Ajv 8.20.0，版本和摘要锁在工具目录的 package-lock 中。选择针对本轮原型，不宣称是所有平台的最终实现；App/CLI 的同语料对照是 D01 的剩余工作。

## 3. 身份、分页和版本

发布源 ID 是作者命名，安装实例 ID 是宿主生成。相同发布 ID 的不同来源不会自动互相替换。安装记录另外保存上游地址、摘要、用户修改和授权范围。`version` 使用 SemVer 字符串；摘要以实际 UTF-8 字节计算，BOM 和换行改变会改变摘要。

宿主实体键是安装实例/账号范围内的书籍 ID、章节 ID；URL 只作位置。正文和阅读记录不以章节下标、标题或签名 URL 为身份。ref/state 不得含 Cookie/口令/令牌；静态校验不能可靠识别所有秘密，宿主凭据路径必须独立。

一次操作固定安装实例、账号、配置版本、源码摘要和 deadline。目录多页是一个一致性流程，固定源快照。游标的宿主封套含操作类型、查询指纹、账号/配置和源码摘要；源只收到封套内的 JSON 值。不同流程的封套不能互用。

- 输入缺省 cursor 等于 null；返回必须显式带 `nextCursor`，null 表示终止。
- 空 items 可以有下一页。重复游标、循环游标、页数上限是宿主错误，不能无限抓取。
- 页内重复 ID 拒绝。跨页同 ID 且内容相同可去重并保留最先顺序；同 ID 内容冲突需要整体刷新或明确不一致错误。
- 分页 revision 必须一致；开始提供 revision 后续不能缺失。变化时丢弃本轮合并结果并有限重试；无 revision 只能尽力一致。
- 源更新使旧游标失效；持久化 ref 则要尽量保持可读取。无法解释旧 ref 时明确返回错误，不用同名结果静默替代。

## 4. 数据和错误

JSON 只包含 null、布尔、字符串、有限数值、数组、普通对象；整数必须在 JS 安全整数范围内。拒绝循环、空位、访问器、特殊对象和特殊键。跨桥必须先限制消息体积，再解码和校验；当前 Node `assertJSON` 面向已取得的数据，不是任意 Proxy 对象的安全隔离器。

Schema 限制单页 1000 项，profile 另外限制总输出、JSON 深度/节点、ref state 和游标字节。source id、实体 id 和显示标题不得为空白；字段大小的字符串限制按 Unicode 码点，桥和文件限额按 UTF-8 字节。

错误是 `{code,message,details?,retryAfterMs?}`。空搜索是成功的空页；空白正文在运行期应成为 PARSE，而非自动判为正常章节。INVALID_INPUT/INVALID_RESULT 用于边界合同错误；静态导入器另外有 SYNTAX_ERROR、METADATA_NOT_STATIC 等诊断码，这些不是业务错误码。

`ctx.errors.http({status,...})`：401 → AUTH_REQUIRED；429 → RATE_LIMITED；其余非成功状态 → HTTP。403 不自动推断为登录问题；源若能确认登录失效，可显式 `authRequired`。传输层失败 → NETWORK；解析/必要节点缺失 → PARSE；限额 → RESOURCE_LIMIT；来源越界 → PERMISSION_DENIED。原生宿主翻译错误，但不靠错误文案判断类别。

P1 运行时已按此区分 403 与 401。`retryAfterMs` 只接受 0–86,400,000 的整数，跨 JS/原生边界保留，不因此自动重试；非法 helper 参数返回 INVALID_INPUT。传输超时为 TIMEOUT，其他传输失败为 NETWORK，取消为 CANCELLED。未知作者错误码统一为 SCRIPT_ERROR；异常消息最多 2,048 个 UTF-16 单元，异常对象的 getter/toString 不能阻止生成备用诊断。P1 保留内部 INVALID_DATA 诊断码，`details` 尚不跨原生错误封套传输，不宣称完整业务错误服务已完成。

## 5. HTTP 候选语义

`ctx.http.fetch` 是有范围限制的原生 HTTP API，不承诺全部浏览器 Fetch 行为。

- 绝对 http/https URL，不含 userinfo；每一跳重定向检查 `origins`。生产默认 HTTPS；HTTP 是否允许及本机地址策略由宿主配置，fixture 仅使用开发环境的 loopback。
- 方法为 GET/HEAD/POST/PUT/PATCH/DELETE；GET/HEAD 不允许 body。body 是字符串或字节；JSON、表单由作者明确编码并声明 Content-Type，不进行猜测转换。
- 请求 headers 名称不区分大小写；拒绝 CR/LF、Host、Content-Length、Cookie、Connection、Transfer-Encoding 等由宿主管理的字段。Cookie/认证由账号范围的凭据服务注入；源不能导出或写入其他账号凭据。
- `redirect` 为 follow/error，默认 follow；没有伪造的 opaque/manual Response。候选上限为 5 跳；301/302 的 POST 与 303 转 GET 并去除 body，307/308 保持方法/body。跨 origin 去掉敏感请求头，再重新检查授权。
- 非 2xx 经下述有限传输重试后仍返回 Response，不默认抛出。Response 有 status/ok/url/小写 headers/bodyUsed，以及 text/json/bytes；不向脚本暴露 Set-Cookie。
- 响应体只消费一次，text/json/bytes 互斥；已消费再读返回 INVALID_INPUT。首次消费后即标记 bodyUsed，即使解析失败也不恢复。
- bytes 是原始响应体字节；text 使用显式 charset（首版候选 UTF-8/UTF-16LE/UTF-16BE/GB18030，必须通过设备编码语料后放行），无声明默认 UTF-8；不静默把未知 charset 当 UTF-8。json 固定 UTF-8 JSON；错误字节/非法 JSON 返回 PARSE。字节数组桥接格式待 P1 验证。
- body、解压后体积、跨桥消息与操作总请求数都有上限；收到响应头后与读流期间都检查，避免只信 Content-Length。
- 操作结束/取消/deadline 到达后禁止新请求，取消已有请求，丢弃迟到响应。作者提供 signal 只会增加取消条件。
- 2026-11-09 原生候选策略：GET/HEAD 遇到 429/503 或连接中断可额外尝试 1 次；同次 fetch 的所有跳转共享这一个重试额度。POST/PUT/PATCH/DELETE 不自动重放，包括先被 303 改成 GET 的原写请求。
- Retry-After 支持秒数和 HTTP 日期。等待超过宿主上限 2 秒或剩余 deadline 时返回原 HTTP 响应，不能缩短服务端要求后提前重试；没有该头时等待 250 ms。错误格式不重试，等待期间不占网络并发名额。
- 每次实际原生尝试（含重定向和重试）消耗同一操作的 64 次预算。每跳按实际目标 origin 取得许可，释放前一跳后再排队。排队/传输/重试使用同一单调时钟截止时间，桥接沿用从 operation ready 开始的总截止时间。

这些规则由原生 `SourceHostHTTPClient` 执行，完成范围以 P2 报告中的测试证据为准。fixture 的 Node fetch 仅模拟网络往返，不代表全部原生语义已实现；真实设备资源与完整 WebKit 集成仍需分别验证。

## 6. storage、配置和生命周期

`ctx.storage` 按安装实例与账号隔离。键为 1–128 个 Unicode 码点的非空文本，不允许 NUL；值为有限 JSON，有单项和总量配额。

- `get(key)` 返回 `{value,revision}` 或 null。即使值本身为 null 也有记录和 revision，可与不存在区分。
- `set(key,value,{ifRevision}?)` 原子写入并返回新记录。省略条件表示覆盖；`ifRevision:null` 表示仅不存在时写入；字符串表示仅匹配该 revision 时写入。
- `remove(key,{ifRevision}?)` 同样支持条件删除，省略条件下删除不存在键成功；条件不匹配是 STORAGE_CONFLICT。
- revision 是宿主生成的不透明标记；删除后重新创建不能重用旧标记，避免 ABA。读写返回副本。
- 同一键更新线性化；多键和整个 JS 操作没有隐含事务。操作结束前已提交写入保留，结束后的写入拒绝。取消不能撤销已发送的远端副作用。
- 源更新保持状态，但源作者需维持旧状态兼容；v1 没有自动执行的状态迁移 hook。源码回滚不等于状态回滚。需要不兼容迁移的更新暂缓或另存安装实例，待明确状态迁移方案。

settings 提供 text/boolean/enum/number，默认值必须有效。text 限长，enum 值唯一且包含默认值，number 有有限上下界。源读取不可变 config；敏感输入走原生账号凭据界面，不把 text 字段当密码。

宿主操作状态：queued → initializing/running → succeeded/failed/cancelled/timedOut，终态只到达一次。session 状态单独管理。回调凭 operation/session 与快照身份验证，不能用源自行声称的 ID 绕过作用域。终态取消未等待工作，拒绝后续宿主写入；JS 停算与 WebContent 资源回收仍需 D03 的设备证据。

## 7. 正文规范化候选

纯文本：去掉开头 BOM，CRLF/CR 转 LF，去 NUL，每行删除尾部空格/tab/全角空格，删除首尾空行，保留行首缩进、内部空行和 Unicode 序列；不擅自 NFC 化。`fixtures/text-normalization.json` 是共同预期。纯文本和 HTML 的共享样本均已在 Swift 核心测试执行，详见 [P2 报告](../../docs/reports/SOURCE_PROTOCOL_P2_REPORT.md)。

HTML：使用 DOM 解析片段，不执行其中代码。初版候选保留 p/div 的段落边界、br 换行、h1–h6 标题、strong/b、em/i；普通未知行内容器保留文本，script/style/iframe/object/embed/template 的子树丢弃，img/media 不加载。属性仅提取到有限内部 mark，不保留事件、CSS 或导航。pre 暂按保留换行文本降级；a 只留文本。SwiftSoup 已将 HTML 转换为有限内部文档，阅读界面不渲染网站 HTML；标题、强调和空白保留规则仍是候选，真实设备显示需要另外验收。这不是输出可执行 HTML 的通用 sanitizer。

内部文档由顺序 block 和 UTF-16 范围的强调 mark 组成；此结构不要求源作者手工构造。保存抽取结果、规范化版本与文本锚点。EPUB 的 publication/locator 不进入该简化合同。`html-normalization.expected.json` 已被 Swift 共享样本测试读取并比对，不表示所有 HTML 或设备渲染场景已验收。

## 8. 基础能力与尚未验收内容

候选基础：Promise、URL/URLSearchParams、DOMParser 与基础 CSS 选择器、TextEncoder/TextDecoder、AbortSignal、Uint8Array、JSON、有限计时器。编码列表、计时器的结束清理和受控页面的 secure context 要在 iOS 26 验证；WebCrypto、XPath、真实浏览器导航、媒体、认证、explore 目前没有已开放扩展。

静态允许 JS 语法并不授权动态代码、worker、脚本标签、全局网络或跨源 UI。运行时必须验证这些入口的策略。P1 已实现实验性的受控执行页和无账号原生 HTTP；不承诺完整沙箱隔离。实验版已接入安装实例隔离的 SQLite storage、有限配置、HTML 文档转换、文件/粘贴/HTTPS 安装、源码编辑导出与历史恢复和原生阅读预览。实验室单次执行没有安装作用域，storage 仍返回 UNSUPPORTED。原生账号、Cookie/令牌与单网站临时网页登录已接入实验入口，集成与设备状态见 [P2 报告](../../docs/reports/SOURCE_PROTOCOL_P2_REPORT.md)；作者可编程认证扩展和旧库迁移仍待实现。P3 已通过构建源 WebKit、源码定位与真实进程中断恢复，见 [P3 报告](../../docs/reports/SOURCE_PROTOCOL_P3_REPORT.md)；设备更新交互和完整作者分享仍待验收。当前放行的编码和资源边界见 [P1 报告](../../docs/reports/SOURCE_PROTOCOL_P1_REPORT.md)，D01–D10 尚未最终关闭。
