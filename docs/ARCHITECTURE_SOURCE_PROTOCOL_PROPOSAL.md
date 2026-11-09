# iOS 26+ 阅读器与自有书源协议：架构提案

初始审阅：2026-11-08；验证策略更新：2026-11-09（Asia/Hong_Kong）

定位：记录初始架构分析与设计依据，不作为实时完成清单。P2/P3 已有实验实现与自动化证据，当前工作和剩余验收统一见 [实施流程](SOURCE_PROTOCOL_IMPLEMENTATION_PLAN.md)。作者接口的设计动机见 [v1 草案](SOURCE_PROTOCOL_V1_DRAFT.md)，具体候选合同见 [协议细则](../protocols/source-v1/README.md)，实际编写与调试见 [作者指南](SOURCE_AUTHOR_GUIDE.md)。

前提：允许从零设计，不以沿用现有类、模块或数据模型为约束。产品目标是 iOS/iPadOS 26+、本地执行书源、兼容 Android 阅读书源，并建立自己的长期协议。

## 1. 推荐决定

推荐采用 **原生 iOS 阅读器 + 单文件自有 JS 书源 + WebKit 优先的运行环境 + 独立 Legado 兼容适配器**。

- 产品核心用 Swift 6；SwiftUI 负责应用界面，小说阅读使用原生排版，EPUB 保留 publication 与独立渲染路径。
- 自有协议以一个可读的 .source.js ES Module 为分享、查看、修改和导入单元，使用静态 export const metadata 和命名函数；作者可多文件/TypeScript 开发，发布为自包含单文件。v1 不做远程 JS 依赖管理，也不要求 ZIP。
- 新协议优先验证 WKWebView 作为标准 JS + Web API 的主运行环境，以减少自行维护 DOM、编码等 Web 能力的工作。它加载 App 控制的运行页面，静态书源无需逐个导航到远程站点。最终发布决定以第 7 节的真机验证为依据。
- 阅读兼容有独立的同步宿主语义，可以使用专用 QuickJS 后端。当前实现只是一份可测试的基线，不约束新架构必须保留它。
- 自有协议验证以合同、实际 WebKit 和 iOS 设备为准；旧源兼容以固定样本与完整阅读链路验收。Android 原实现用于按需语义对照，SDK/模拟器不作为主线开发或功能验收的统一前置条件。
- 书源请求在用户设备上发出；源码/依赖的静态分发地址与抓取代理服务器是两类服务，核心阅读不需要中转服务器。
- **ORSP 仅作为数据定义与版本治理的参考；不实现、不规划 ORSP 适配器。** 不以项目活跃度或作者动向作为本设计需要证明的前提。
- 第一版优先完成文字小说闭环；稳定 ID、分页、错误、状态隔离、更新与回滚属于核心合同。

当前建议已综合 Rex/Forward、Swipt、代理 App 与阅读源的差异：协议保持小而确定，能力适配阅读业务，作者工具可选，运行引擎按实际验收选择。单文件、标准导出、原生宿主分工比增加更多通用插件能力优先。

## 2. 现有项目判断：基础方向成立，核心边界需要调整

这是静态架构审阅，覆盖部署配置、App 入口、核心数据模型、书源导入、搜索、详情/目录/正文、QuickJS 与宿主网络链路、持久化、阅读模型和测试组织；没有逐行审计全部功能。没有在本机执行 iOS 编译或运行性能测试，也没有据此宣称兼容率或性能达标。

### 2.1 已有的正确基础

| 观察 | 代码证据 | 判断 |
| --- | --- | --- |
| 已明确最低 iOS 26 | Package.swift 的 iOS("26.0")；Xcode 配置的 IPHONEOS_DEPLOYMENT_TARGET=26.0 | 满足目标，不存在需要先把最低版本升到 26 的问题 |
| App 与可测试核心已有分离 | App/、Sources/LegadoCore/、LegadoAppModels target | 分层意识是对的 |
| 已有原生 SwiftUI/UIKit 阅读实现和 EPUB 路径 | App/Features/Reader/；README 的 EPUB 说明 | 不必因为书源问题否定整个原生技术路线 |
| 已使用独立 QuickJS C runtime | JavaScriptRuleEvaluator.swift:189；QuickJSRuntime.swift:99 | MR 的“独立引擎”思想并非当前项目缺失的功能 |
| 已配置内存、栈和执行中断 | QuickJSRuntime.swift:106 | 有资源控制基础，但不等于整次书源操作都受同一预算约束 |
| 有 transport 注入、数据库 actor、流式搜索 | HTTPClient.swift:105；LegadoDatabase.swift:19；BookSearchService.swift:164 | 可以作为新方案的设计经验 |
| 有离线兼容样本及 CI | Tests/LegadoCoreTests/；.github/workflows/javascript-engine-ci.yml | 测试资产比保留旧类结构更有价值；本次未读取实际 CI 运行结果 |

### 2.2 最需要解决的五个问题

**A. Legado 的导入格式已经成为业务领域模型。**

BookSource 直接包含 ruleSearch、ruleBookInfo、ruleToc、ruleContent、jsLib 等 Legado 字段，并以 bookSourceUrl 作为 id（Domain/BookSource.swift:3）。NetworkBookService 直接依赖 LegadoURLBuilder、RuleEngine、BookSource，并在 loadDetail 中读取 ruleBookInfo（Book/NetworkBookService.swift:47）。甚至抽象出来的 ChapterContentLoading 仍要求调用方传 BookSource（Book/ChapterContentCache.swift:153）。ReaderViewModel 也保存 BookSource。

影响：增加自有 JS 或其他本地书源格式时，容易把多个格式的分支塞进同一个 BookSource 和阅读业务。新设计应让业务依赖 SourceRef/BookRef/ChapterRef 与 provider，规则字段停留在适配器内部。

**B. 主请求与脚本请求没有统一的请求调度入口。**

主请求经过 SourceNetworkPolicy.execute 和 acquire（Networking/HTTPClient.swift:646）。JS 内 loadDirectJavaScriptRequest 与 loadJavaScriptRequest 直接调用 networkLoader（JavaScriptRuleEvaluator.swift:503、550），该路径没有调用同一 SourceNetworkPolicy.acquire。

这是可从代码确认的结构差异，不能据此推断每个真实站点都已出错。它意味着限流、Cookie、重试、追踪及后续域名授权需要在多处保持一致。新设计应只有一个请求代理服务；旧协议的同步调用也通过它预约/执行请求。

**C. JS 执行超时不等于用户操作的端到端超时。**

RuleExecutionWorker 在进入和退出 GCD operation 时检查 Task cancellation（JavaScriptRuleEvaluator.swift:53），没有在这段代码中把取消信号传入运行中的 runtime 和宿主网络请求。同步网络桥通过 DispatchSemaphore 等待，使用独立 request timeout（同文件:74、132）；QuickJS interrupt 在 JS 执行时被调用，无法单靠它中断正阻塞在 Swift/native 宿主函数中的网络等待。[R6]

所以默认 5 秒的 JS timeout 不能当作“点取消后最多 5 秒释放所有资源”的保证。新设计需要 operation cancellation token、总 deadline、JS 执行预算、网络任务句柄和 native parser 限制贯通。

**D. 高频重建 runtime/context 带来明确的成本项，但尚不能直接量化性能。**

evaluateRaw 每次创建 QuickJSRuntime，安装宿主与兼容脚本，再加载 jsLib（JavaScriptRuleEvaluator.swift:298）。按字段、多命中、正文替换反复求值时，这些步骤可能重复。应采样区分网络、解析、脚本初始化、运行、桥接和排版的耗时后再优化。跨 context 复用“活的 JSValue/编译结果”需要遵守 realm 与所有权规则；仓库的迁移订正文档已经记录过这一类问题。

新协议可以一次操作调用一个导出的函数、一次解析文档、一次返回结构化结果，从结构上减少逐字段初始化。旧协议独立保留它所需的状态语义。

**E. URL、源身份和书籍身份绑得过紧。**

BookSource.id 为 bookSourceUrl，Book.id 为 bookUrl（Domain/LibraryModels.swift:48），缓存文件名主要由 bookURL/chapterURL 生成。新协议应把稳定 ID、当前请求地址、账号作用域、源版本分别建模。域名迁移、带时效签名的 URL、换源、内容修订都不应自动造成书架条目身份变化。

### 2.3 次要但值得处理的问题

ReaderView、ReaderTextView 和 RootTabView 都较大，说明视图、协调逻辑和阅读状态有进一步拆分空间。但“文件大”本身不能证明有功能错误，优先级低于协议边界和执行生命周期。大量 shared 也应逐步收敛到应用组合根注入，尤其是源状态、账号状态和 Cookie。

无需因为目标是 iOS 26，就把所有持久化迁成 SwiftData，或为了使用 Observation 而先重写全部 ViewModel。技术选择应服务于数据迁移、并发和排版正确性。

## 3. 阅读书源的困难主要在哪里

“很多 Java 语法”需要拆开理解：书源一般混合声明式选择器/模板、JavaScript、应用提供的宿主对象；在 Rhino 环境中，JavaScript 还可以访问 Java 类或对象。[R7]

- java.ajax(...) 中的 java 往往是宿主对象名称，这一段仍是 JavaScript 调用语法。
- Packages、JavaImporter、org.jsoup 或 io.legado.app.* 依赖的是 Java/Android 提供的环境或桥接语义。
- 把 JavaScript 引擎换成 QuickJS，不会自动生成 JVM、Android 类库、Jsoup、Cookie、同步网络或应用对象。
- JSON 中不同字段的 result、变量、列表、替换、分页、相对 URL、编码和请求选项也有上下文语义；问题不限于 JS 能否解析。

因此旧协议的成本来自“格式 + DSL + 运行环境 + 历史行为”的组合。它支持过大量现实需求，不能只用“安卓实现不好”概括。对新协议最有价值的改进是明确边界和语义，而不是把 java.* 简单改名成 app.*。

## 4. 对用户列出方案的比较

| 方案 | 本次可确认的定位 | 值得借鉴 | 本项目的选择 |
| --- | --- | --- | --- |
| 用心读书 / MRS | 文档描述 XPath/JSONPath/CSS、场景规则、请求/响应处理、publicJavascript、App.* 原生 API；原生 HTTP API 示例使用 async/await [R1] | 面向写源者的规则、调试工具、显式请求信息、登录流程 | 借鉴作者体验；不把多种内嵌表达式和 App 可变配置直接作为新规范 |
| 香色闺阁 / XBS | 用户给的资料由社区根据 demo 和 App 内配置整理，描述 XPath、请求模板、JSParser、WebView 等 [R2] | 简单站点写源方便，允许复杂站点用完整 JS | 作为未来导入适配候选；资料不是完整第一方规范，不能据此承诺全兼容 |
| Legado Tauri | 文档属于 Legado Tauri，描述 JS 文件与 search/bookInfo/chapterList/chapterContent 等入口，宿主 I/O 返回 Promise；桌面另有 Sync 变体 [R3] | “书源就是内容适配器”、明确业务入口、异步 API | 最接近新协议方向；不继承桌面专用同步 API，也不把多媒体内容塞成含义不定的字符串 |
| DandanLLab/mr | Flutter 应用；规则解析在 Dart，QuickJS 通过 native FFI 接入，仍面向阅读兼容；README 明示不支持部分 Legado Java 包类 [R4] | 引擎、规则层、宿主桥接分离；有执行追踪 | 不需要为借鉴它改用 Flutter；其兼容细节不能直接当作新协议语义 |
| Origo / ORSP | HTTP(S) 客户端与独立内容源之间的数据协议，不下发可执行抓取规则；当前查阅规范为 1.6 候选草案 [R5] | 稳定 ID、能力声明、Schema、版本治理、一致性测试 | 仅参考数据合同；不增加适配器 |
| Rex / ForwardWidgets | 官方示例为单个 JS 文件，WidgetMetadata 定义模块/参数，异步函数返回统一 VideoItem；rex-widget-libs 提供类型、构建、测试工具 [R15] | 小型数据插件、原生参数表单、作者工具闭环 | 借模式，不继承媒体字段、全局字符串函数映射或加密分发 |
| Swipt / 官方 Swiplets | 自动化 App，分界面、操作、服务；源码有输入/输出 Schema、取消上下文、宿主隔离及项目打包 [R16] | 显式上下文、类型验证、调用生命周期、开发与产物分离 | 不引入任意插件界面、持续服务、设备自动化能力或多文件软件包要求 |

### 4.1 关于 MRS 和 XBS 的证据边界

这次主要核对的是公开规则文档，没有反编译用心读书或香色的运行时，也没有获取代表性 .mrs/.xbs 包做真机互操作。不能据此判断它们的真实速度、内存、完整兼容性或内部引擎选型。

香色资料称 .xbs 是固定密钥处理的 JSON，并公开描述其数据来源。这只能证明该资料作者的观察范围；包扩展名、加密包装和书源执行协议应分开讨论。新协议无需靠不透明包装实现兼容或安全。

### 4.2 关于 MR：独立引擎值得学，具体同步技巧需要谨慎

MR 的 js_engine.dart 中存在 _evalLock、_evalBusy，以及通过 __NEED_NETWORK__ 标记触发网络、写入缓存后重新执行 JS 的路径。[R4] 这是静态实现观察，不是已经复现出的 MR 用户问题。

从语义上推断，重新执行整段脚本会让网络之前的时间、随机数、变量修改、持久化写入等副作用再次发生，除非另有完整的重放控制。新协议直接使用 Promise/await 更容易定义正确行为。兼容同步书源时，不能把任意脚本重跑视为无副作用的通用优化。

### 4.3 关于 ORSP：用户观察成立，但需要限定对象

它确实要求有实现协议的 HTTP 服务。服务器可以由原内容方、用户自己、社区或本地环境提供，并非必须是某个第三方平台。对于希望“导入源后在手机直接访问普通网站”的产品，它增加了服务部署、可用性与运维环节，因此不适合作为唯一核心方案。

本项目只参考其数据契约思想。不增加导入、发现、网络 provider 或兼容测试入口，也不将它列入后续路线图。

### 4.4 Rex / Forward：更接近数据提供者，SDK 值得优先学

核对了 ForwardWidgets 的 README、demo.js、集合索引，以及 rex-widget-libs 的类型、构建插件和测试适配器。官方示例的 WidgetMetadata 同时定义模块、functionName、参数类型、缓存提示和 requiresWebView；函数通过宿主请求/DOM 接口返回统一数据。工具链可以从参数生成类型，去除 Rex 不支持的 export，并提供测试适配器。[R15]

对阅读器有价值的是：作者定义数据获取和有限配置，App 呈现统一原生界面；类型和测试与协议一起提供。没有必要复制全部播放器/媒体模型，也无需继承“函数名称字符串 + 全局赋值”的约定，新协议可以直接使用 ES Module 的可检查导出。

rex-widget-libs 是用户指定的开发工具链仓库，不是 Rex App 引擎源码。README 的 requiresWebView 也不能证明所有操作都运行在 WKWebView。其 Node 测试适配器与真实 iOS 环境不能自动视为完全等价。

工具链支持的可选加密产物与服务不符合本项目强调可读、可改、可离线分享的目标。本项目发布源码，作者身份、内容摘要和许可另行管理；不加入模块加密服务。

### 4.5 Swipt：学习有边界的能力，不复制整个自动化平台

Swipt 公开文档将 Swiplet 定义为带界面、操作和持续服务的自动化 App，支持 .swiplet 包和仓库安装。官方示例有 package.json 中的 swiplet 元数据、App.tsx、extension.ts，CLI 把代码构建成应用/扩展产物并打包。archive.go 使用 ZIP 读取 manifest、源文件与资源。[R16]

值得借鉴的是 defineAction 的输入/输出 Schema、RunContext.signal、caller、service 状态，以及将宿主异步操作绑定到 execution 的设计。对阅读器，取消、deadline、日志、状态都应该属于明确的操作，而不是散落的全局对象。

本次检查的自动化扩展 engine.go 明确使用 internal/jsc；后者直接链接 JavaScriptCore。scope.ts 自行安装 fetch、URL、编码、WebCrypto、Streams 等对象。因此“提供 Web API”不能反推“全部使用 WKWebView”。这也说明另一条路径有完整的 API 实现和维护成本。[R16]

该仓库的 JSC C bridge 自身标注了 private API，并通过 dlsym 使用执行时限等接口；README 当次标称 iOS 27。这里只借鉴契约与管理方式，不把这些实现当作本项目 iOS 26 公开 SDK 的现成方案，也不据此声称其全部实现可直接移植。

### 4.6 阅读器的专属边界与“优雅”的判断标准

| 参考产品的插件任务 | 可借鉴部分 | 阅读器需要另行解决 |
| --- | --- | --- |
| 代理请求处理 | 单入口、脚本生命周期、原生网络与 Web API | 书/章稳定身份、目录变化、离线内容和阅读位置 |
| 影音数据模块 | 列表/详情数据、配置表单、宿主统一呈现 | 长文本规范化、连续翻章、预读、目录分页与修订 |
| 自动化小应用 | 明确操作、输入输出类型、取消、宿主能力 | 限制源的职责，避免自定义 UI/服务接管阅读业务 |

这些是本项目的设计取舍，不是对参考应用所有功能的穷举。

本提案把“优雅”落实为五个可检查的目标：简单源无需构建即可写；复杂源不需要另一种协议；用户看到的文件就是完整代码；宿主统一管理所有源的阅读状态；正确性由类型与一致性样本定义，不依赖某个运行时的偶然行为。

## 5. 从零设计的目标架构

~~~mermaid
flowchart TD
    UI[SwiftUI 原生界面] --> UseCases[搜索 / 书库 / 更新 / 下载]
    UI --> Reader[原生阅读器 / EPUB 渲染器]
    UseCases --> Contract[SourceProvider 与统一领域类型]
    Contract --> Native[自有单文件书源]
    Contract --> Legacy[Legado 兼容适配器]
    Native --> WK[WebKit 脚本运行环境]
    WK --> WebAPI[标准 DOM 与 Web API]
    Legacy --> Compat[旧规则与同步宿主 / 专用 JS 后端]
    WK --> Host[Swift 宿主服务]
    Compat --> Host
    Host --> Network[统一请求与调度]
    Host --> Browser[独立网站浏览器会话]
    Host --> State[源状态 / 账号 / 凭据]
    UseCases --> Store[SQLite 与文件缓存]
    Contract --> Documents[规范化正文与资源]
    Documents --> Reader
    Local[本地 TXT / EPUB] --> Reader
~~~

WebKit 脚本运行环境与网站浏览器会话具有不同生命周期：前者运行作者代码并解析已获取的数据，后者才执行真实站点的页面脚本、登录和导航。原生阅读器只消费规范化结果。

逻辑模块仍保持精简：

| 模块 | 职责 | 对外边界 |
| --- | --- | --- |
| App | 界面、导航、系统生命周期、依赖装配 | 不解析具体书源规则 |
| LibraryKit | 搜索聚合、书架、更新、阅读记录与缓存 | 只依赖领域接口 |
| SourceContracts | 身份、能力、请求、结果、错误 | 不暴露引擎对象 |
| SourceRuntime | WebKit 调度、宿主服务、网络、会话、取消 | 不持有书架 UI 状态 |
| SourceAdapters | 自有格式与 Legado | 旧规则语义留在适配器内 |
| ReaderKit | 正文、排版、定位、翻页、EPUB | 不访问网站规则或 Java 宿主 |

本地 TXT/EPUB 无需伪造远程搜索接口。逻辑边界不意味着每项必须成为独立 Swift Package。

### 5.1 一个协议主版本，加一个源内容版本

v1 的格式与基础 API 统一由 apiVersion=1 标识；破坏性变化升级主版本。可选能力以 requires 声明，兼容性变化须配合一致性测试。

源作者用 version 标识自己的发布版本，App 同时保存源码摘要和上游信息。引擎/iOS 版本进入诊断，不写成作者必须选择的 implementation。当前没有独立包容器，因此不额外引入一个 package format version。

## 6. 单文件与作者接口的最终候选

### 6.1 标准 ES Module，静态 metadata

~~~javascript
export const metadata = {
  apiVersion: 1,
  id: "org.example.books",
  name: "示例书源",
  version: "1.0.0",
  origins: ["https://books.example.org"]
};

export async function search(ctx, { query, cursor = null }) { /* 搜索页 */ }
export async function book(ctx, { ref }) { /* 详情 */ }
export async function chapters(ctx, { book, cursor = null }) { /* 目录页 */ }
export async function content(ctx, { book, chapter }) { /* 正文 */ }
~~~

metadata 仅允许静态字面量，由 AST parser 读取，导入时不执行未知代码。普通 JS 编辑器能提供语法检查/JSDoc；TypeScript 工程可以在发布时转成同样文件。

这一版替换之前的 JSON 注释头：避免另定义边界标记、再写一份 manifest，代码只有一个元数据来源。它也不同于直接运行脚本取对象，静态限制和导入预算需要验证。不要用正则或 eval 提取 metadata。

不再重复列 provides 和 functionName；已导出的标准入口决定业务能力，配置项和标准错误由公共协议固定。不是用类型断言掩盖运行期输入/输出校验。

### 6.2 第一版发布完整单文件，依赖在开发时解决

| 使用方式 | v1 行为 |
| --- | --- |
| 手写 JS | 一个文件即可发布/导入，不要求 npm |
| 多文件/TypeScript | 可选 builder 合并为可读自包含 JS |
| 第三方 JS 库 | 开发阶段锁定版本、打包并保留许可；不在手机执行时拉新代码 |
| 集合/订阅 | 可选纯数据索引引用多个完整源，源本身仍可单独分享 |
| App 内部存储 | 保存源码快照、来源、授权与用户修改；不影响外部分发格式 |

上一版允许 App 下载和锁定完整远程依赖图，分析 Rex/Swipt 后决定暂不纳入 v1：它引入模块解析、递归版本、更新事务与离线导出复杂度，阅读源通常可以通过标准 API + 小型 helper + 构建时合并满足需要。

若以后实际数据证明大型公共库重复严重，再评估有版本的共享库能力。不能一边宣称完整单文件，一边让用户不知情地依赖多个可变远程脚本。

### 6.3 原生表单和工具链，而非插件 UI 框架

metadata.settings 可以描述少量枚举、布尔、文本和数字配置，App 生成原生表单，ctx.config 提供只读配置。认证、发现筛选按明确扩展处理，不允许每个源注入任意 SwiftUI/React/HTML 页面。

工具链优先提供类型/JSDoc、静态 validator、离线 fixtures、设备 runner 和可选 builder。复杂作者不必为每个固定接口手写完整 Schema；协议类型与宿主验证共享规范。Node 测试只是快速反馈，iOS WebKit 一致性需要真实设备/目标环境验证。

### 6.4 阅读数据合同与状态恢复

book/chapter 引用必须可保存并在重启后使用；不能依赖上次 search 留在 VM 全局的对象。搜索/目录返回 items + nextCursor，目录可声明 revision；完整目录更新不能只比较总章数。

正文允许文本或受限 HTML 输入，统一规范化成阅读器文档。源只定义如何获取/提取，原生核心负责缓存、预读、净化、布局、书签和位置恢复。登录状态与源码/游标分开，源无权调度全局后台常驻服务。

接口、Schema 草案、更新/编辑合同和生命周期详见 [SOURCE_PROTOCOL_V1_DRAFT.md](SOURCE_PROTOCOL_V1_DRAFT.md)。[example.source.js](examples/example.source.js) 提供四个入口的完整说明性实现，使用虚构站点；尚未在当前 App 接入。

## 7. WebKit 优先的执行方案与待验证边界

### 7.1 代理 App 的第一方证据

| 项目 | 官方说明 | 可得结论 |
| --- | --- | --- |
| Surge | 同时提供 jsc/webview；auto 在支持时使用 WebView；文档说明初始化、跨进程传输与超时方式的差异 [R9] | WebView 已是正式主路径之一，JSC 仍保留 |
| Stash | 同时提供 webkit/jsc；auto 在 iOS/macOS 优先 WebKit，并说明 fetch、crypto 等适用性 [R10] | WebKit + 标准 Web API 是有实际产品依据的设计方向 |

以上足以支持重新评估本项目的主 runtime；Swipt 的直接 JSC + 自建 Web API 又说明并不存在所有产品共用的唯一实现路线。[R16] 没有逐一拿到所有代理 App 的第一方资料，不能把结论扩大成“所有产品都已经彻底放弃 JSC”。Surge 的 Network Extension 进程限制也是其选型背景之一，本 App 的设备内存与后台条件应独立测量，不能复制代理产品的资源数字。[R9]

### 7.2 引擎与完整运行环境

WebKit 内部仍使用 JavaScriptCore 执行 JS，DOM 和大量 Web API 来自 WebCore 等部分。[R11] 因此真正的比较是：

| 方案 | 主要提供什么 | 本项目取舍 |
| --- | --- | --- |
| 直接嵌入 QuickJS/JSC | JS 语言运行能力 + 自己实现的宿主 | 阅读同步兼容可用；新协议如要完整 DOM/Web API，补齐成本需计入 |
| WKWebView/WebKit runtime | JS + DOM/浏览器 Web API + WebContent 执行环境 | **新协议优先验证的主路径** |
| 网站 WebKit 会话 | 加载远程页面、真实导航、页面脚本和用户登录 | 独立的按需能力，避免污染书源自身运行环境 |

选择 WebKit 不意味着把阅读器改成网页 UI，也不意味着每次解析都加载完整网站。新源可以在受控运行页面内用 DOMParser 处理通过 Swift 网络层得到的 HTML。

### 7.3 尽量采用标准 API，宿主补足产品能力

目标能力配置包括 URL/URLSearchParams、Promise、DOMParser/querySelector、必要的 XPath、TextDecoder、Uint8Array 与经过验证的 WebCrypto 子集；实际支持范围按 iOS 26 最低版本的测试固定，不宣称所有浏览器 API 都可用。

需要测试运行页面的 secure context、origin、模块加载与 crypto.subtle 可用性。不能因普通 Safari 页面支持某 API，就假定任意 loadHTMLString/custom scheme 环境都具备它。

Swift 宿主重点提供：

- ctx.http.fetch：带源身份的原生网络桥，统一 Cookie、headers、编码、限流、重试和取消，返回文档化的 Response 风格对象。
- ctx.storage / 凭据服务：明确作用域、配额和原子更新；登录信息不进入可分享源码。
- ctx.browser：请求网站会话/用户交互；返回 typed challenge，后台脚本不任意弹窗。
- ctx.log / 错误：结构化追踪和脱敏。
- 少量缺少标准实现的站点辅助能力：按需扩展，不再次建立庞大 Java 类模拟层。

网络桥是客户端本地能力，不需要第三方代理服务器。原生 fetch 继续具有浏览器标准的跨域、credentials 与禁止设置部分 headers 的规则；仅拥有 fetch 函数不能保证能读取任意站点响应。[R12] 初版站点请求统一使用 ctx.http.fetch，不覆盖全局 fetch 后却宣称完全标准兼容。若开放浏览器原生网络，需要单独定义能力、会话与权限边界。

运行页的导航、子资源、脚本导入和其他网络入口也要受控；仅包装 fetch 并不能保证所有访问都经过原生桥。具体 CSP/资源策略与宿主权限检查需一起验证，权限不得只依赖脚本自报的 source ID。

### 7.4 会话、隔离和资源调度

- 使用有上限的工作会话池；一个操作对应完整 search/content 调用，不按字段创建 WKWebView，也不让每个已安装源常驻一个实例。
- 进入不同来源的代码时创建新的运行文档/会话，不能只删除几个全局变量就复用。同源的可复用状态、账号作用域和释放时机明确化。
- WKContentWorld 用于全局变量命名空间隔离，Apple 明确指出同一页面 DOM 仍共享，因此不能把“每源一个 world”当作完整跨源隔离。[R13]
- DOM 查询在 JS 侧一次完成，尽量只把最终列表/正文返回 Swift，控制大响应和二进制跨进程拷贝。
- 原生请求可以独立排队并发；等待、解析和结果返回都归同一个 operation ID，失效操作的回调被丢弃且只结束一次。
- 后台处理按系统允许的生命周期设计，保存检查点后恢复；不能因代理软件可在 VPN 扩展运行定时任务，就承诺普通阅读 App 能持续在后台执行任意 JS。[R10]

### 7.5 超时不是自动拥有的硬中断

Surge 自身文档区分 JSC 的同步代码终止与 WebView 的 wall-clock 超时，说明这是实际产品也需要处理的边界。[R9] 本项目必须分别定义：用户看到操作取消、原生网络取消、JS 停止计算、WebContent 资源回收。

Apple 的 stopLoading 合同是停止当前页资源加载，不能作为任意同步 JS 死循环必定立即终止的保证。[R14] Swift Task.cancel、Promise 超时竞速或给 JS 发 abort 消息，也不能单独证明繁忙 JS 能及时处理该消息。不能在实现未验证前承诺每源硬内存上限或立即杀死其独占进程。

超时后先结束业务操作、取消原生网络、拒收结果、隔离并淘汰问题会话，随后验证重新建会话和资源恢复。若纯 WebKit 在代表设备上无法满足恶意/异常脚本的稳定性要求，应明确缩小可执行范围或重新选择执行模型，而不是用未公开 API 伪造保证。

### 7.6 与 Legado 同步语义的关系

新协议明确使用异步入口与 await。旧源的 java.ajax 等同步语义不能通过简单 await 替换自动等价；不使用阻塞主线程等待 WKWebView 回调的做法。

阅读适配器可以拥有专用 QuickJS 后端，共享原生请求调度，但不共享可变 JS 全局状态。这是两类协议需求的边界，不是同时为每个新源维护 WebKit/QuickJS 两套等价实现。若后续证明一个后端可以满足全部已声明兼容语义，再简化实现。

### 7.7 在冻结 runtime 前完成的原型验证

1. 在最低 iOS 26 真机验证受控本地页面、ES Module、标准 DOM、编码、WebCrypto 和异步桥。
2. 用同一组 HTML/JSON/编码/分页样本跑完整书源操作，验证正文和请求语义。
3. 比较冷启动/复用、首批有效搜索结果、p95、App 与 WebContent 的总内存/能耗及跨进程传输量。
4. 验证同步死循环、长 Promise、网络超时、取消、迟到回调、进程终止后的恢复，以及多源串状态。
5. 验证原生 HTTP 与网站登录会话的 Cookie/认证衔接；不能保证复制 Cookie 即覆盖所有浏览器绑定的站点。
6. 验证前后台切换、系统回收、离线源码、源更新失败回滚和本地修改保留。

这些是发布前需获得的证据，不是本次在 Windows 环境已经完成的测试。本轮已确定 WebKit 优先的设计方向，保留的是可验证的技术决策门槛。

## 8. 数据模型与阅读器：重写时应一起定好

### 8.1 身份和状态分离

| 类型 | 示例职责 |
| --- | --- |
| InstalledSource | 本地安装实例 ID、协议类型、发布者/source ID、源码快照哈希、权限、上游与本地修改状态 |
| SourceRef | 应用内部稳定引用，不使用当前站点 URL 作为唯一身份 |
| BookRef | sourceRef + sourceLocalBookId；书架条目另外有本地 UUID |
| ChapterRef | bookRef + stableChapterId；顺序不属于 identity |
| Locator | 当前请求地址和可序列化定位信息，可更新 |
| ReadingPosition | 章节/内容修订 + 逻辑文本锚点 + 必要的上下文校验 |
| SourceSession | 账号、Cookie、凭据引用、持久状态，与书源源码分离 |

既不要以书名/作者直接合并实体，也不要把带签名参数的 URL 直接当永久身份。旧源缺乏稳定 ID 时，适配器生成稳定的本地映射并保留别名，不强行发明“所有网站通用”的 URL 去参算法。

### 8.2 正文合同

v1 用小型 ChapterDocument：标题、文本段落和必要的段落类型；兼容适配器把旧源字符串规范化到这个模型。富文本/图片能力以后通过明确的可选结构扩展，而不是用一个 String 同时代表正文、JSON、视频地址和整本 EPUB。

保留原始响应的可选开发记录、抽取后的正文、用户净化后的显示内容之间的区别。缓存最好存抽取结果，显示清理和替换版本独立，以免修改净化规则必须重新抓取全书。

缓存 key 至少考虑来源身份、书/章 ID、账号作用域与内容修订/提取版本；更新策略需要允许旧缓存继续供离线阅读，同时标记需要刷新。目录分页记录 revision 和去重标识。

### 8.3 阅读排版

排版器只消费规范化文档、主题和 viewport，输出布局与可映射的文本范围。分页结果是派生缓存；位置持久化使用稳定逻辑锚点，页码仅作布局匹配时的快速提示。字号、行距、设备旋转、文本净化或内容修订变化后，要有锚点校验与恢复策略。

EPUB 继续保留 publication 的资源和自身 locator，不为统一网络小说的正文模型而打平成纯文本。原生小说排版与 EPUB 渲染共享阅读进度/书库服务即可。

SQLite + 文件缓存适合上述数据形态；使用成熟封装或自行封装是工程选择。旧库导入需要保留书架、阅读位置、笔记、源登录状态和原始源 JSON，并有明确迁移/回退过程。

## 9. 兼容策略：边界、分级、验证

### 9.1 Legado 为独立兼容配置

保留可追溯的阅读参考版本、源码和行为样本，记录具体提交、预期来源与已知差异。当前已选参考见 [独立兼容基准](../protocols/legado-compatibility/README.md)。支持状态与证据级别分别记录：静态分析、固定样本、iOS 完整链路、指定 Android 版本对照。已有实现用于借鉴和复用测试，不能凭数量或选定版本就声明完全兼容。

仅在规则语义有歧义、两端出现具体回归、参考版本升级或明确承诺指定行为一致时运行 Android。经确认的结果可以持久保存供日常 Swift 回归使用；缺少 Android 运行环境不单独阻塞限定范围的兼容功能验收。未执行的对照保持待验证，影响承诺范围的未决语义仍须解决或缩小范围。

按能力分级描述：

| 级别 | 能力 | 处理方式 |
| --- | --- | --- |
| 基础规则 | 常用 HTML/CSS、JSONPath、XPath、正则、模板、分页 | 作为优先支持范围，冻结测试用例 |
| 常用宿主 JS | java.ajax/get/post、变量、Cookie、编码、常用加密和有限 Jsoup 行为 | 逐项实现并公布兼容矩阵 |
| 依赖浏览器/登录 | WebView、用户交互、复杂会话 | 通过可选浏览器服务提供，报告平台差异 |
| 任意 Java/Android 类 | 反射、应用内部类、任意外部 jar 等 | 不承诺通用兼容；明确标识需要移植 |

静态扫描只能给出潜在能力需求，动态拼接/混淆脚本不能靠扫描证明兼容。导入阶段的通过不等于搜索、目录和正文全部通过。

### 9.2 不自动转换所有旧源

简单声明式规则可以生成新协议草稿，并附损失/不支持报告；复杂 JS 源默认由兼容适配器执行。源作者可有意识地迁移到新的异步宿主 API。不要用给 java.ajax 加 await 的机械替换承诺语义等价。

MRS/XBS 后续根据用户实际需要和可靠样本决定投入。可增加适配器，并不意味着第一版必须承担多套格式的全部行为。

### 9.3 一致性测试与诊断

- 新协议：Schema、模块入口、版本与能力、网络/编码、错误、空列表与分页、目录修订、取消、资源上限、源码快照更新回滚。
- 兼容协议：固定输入、离线响应、预期结果与请求/状态记录，先验证声明范围内的 iOS 行为和完整链路；按需补指定 Android 版本对照，真实网站抽查单列。预期来源须审查，本实现生成的快照不能单独证明兼容正确。
- 执行器：死循环、内存压力、超大 HTML、native 解析、迟到回调、Promise rejection、同时取消与完成、跨源状态隔离。
- 业务链路：搜索→详情→完整目录→正文→翻章→离线恢复，不能只用“导入成功”定义可用。
- 升级：老源/老书架/老进度迁移，书源升级后所需能力变化，以及有缓存无网络时阅读。

实时源的失效可能来自站点变化、登录失效、网络或反爬，不能直接归因为引擎回归。应把这些原因与离线语义测试结果分开呈现。

## 10. 可落地的重写顺序

1. **冻结小型合同与样本。** 完成标准元数据、四项操作、引用、分页、正文、错误和上下文，手写一个源即可解释全流程。
2. **验证 WebKit 原型。** 证明本地 ESM、Web API、原生网络、操作取消、会话恢复和多源隔离满足 iOS 26 目标，测量首批结果与总资源。
3. **打通完整阅读闭环。** 搜索→详情→目录→正文→翻章→重启→离线恢复；用目录重排/删除、源更新、登录变化等样本验证正确性。
4. **交付作者工具与编辑更新体验。** 类型、validator、fixtures、设备 runner、可选 builder；一个安装更新单位、一处元数据、一套输出合同。
5. **接入独立 LegadoAdapter。** 记录参考来源，以固定样本和 iOS 完整链路验证支持范围，按需补 Android 对照；复用或重写内部实现不影响新的领域模型。
6. **依据使用数据扩展。** 先证明需要，再加入复杂协议能力。ORSP 适配、远程代码依赖管理、任意插件页面和常驻服务均不在首版计划。

## 11. 当前建议与验证边界

本项目最合适的候选是：**小型阅读数据协议、标准 ES Module 单文件、原生宿主统一管理、可选的完整作者工具链。** Rex 提供小型数据插件与工具的参考，Swipt 提供类型和生命周期的参考，代理 App 提供 Web 运行环境与资源权衡的参考；阅读模型决定最终边界。

WebKit 仍是新协议首选验证路径，Legado 兼容可以拥有专用后端。优先选择的依据是减少作者和宿主自建 Web 能力的成本；最终的性能、隔离和取消保证必须用本项目的 iOS 26 原型给出证据。

本轮移除了 JSON 注释头、重复能力声明和远程代码依赖图，补充了配置表单、可恢复引用、正文规范化和操作生命周期。新增协议草案及可读单文件示例；未改动 App 实现，也未完成 iOS 构建/真机验证。

## 12. 查阅来源和证据范围

以下资料于 2026-11-08 直接读取。GitHub SHA 记录查询时的分支状态；文档站部署内容未与源码构建逐字比对。源站页面可能随后更新。

**[R1] Read With Heart 文档（第一方文档）**

- 首页：`https://freenovel123.github.io/read-with-heart-docs/`
- 规则说明：`https://freenovel123.github.io/read-with-heart-docs/制作源/rules-Introduction/`
- Native JS API：`https://freenovel123.github.io/read-with-heart-docs/native-to-js/`
- 请求信息：`https://freenovel123.github.io/read-with-heart-docs/制作源/request/`
- 对照仓库：freenovel123/read-with-heart-docs，main，2550ef7b5f5cb1d1e7c7ebcc04801d59c79dc25f。
- 证据范围：文档描述的规则与 API。没有反向推定其 JS 引擎、MRS 包容器或实际性能。

**[R2] urzeye/shuyuan-lab（社区采样分析，非完整第一方规范）**

- 仓库：`https://github.com/urzeye/shuyuan-lab`
- 用户指定文档：仓库根目录“香色闺阁书源规则.md”。
- main：0b628903cdcf3a6e3625eb187485a096b4acdcdf。
- 文档自述依据 demo.json 和 v2.56.1 IPA 的 plist_localConfig.plist；本报告仅引用其观察范围，未独立验证 App 全部行为。

**[R3] Legado Tauri 文档（第一方文档）**

- API：`https://docs.legadoteam.org/api/`
- 项目简介：`https://docs.legadoteam.org/guide/introduction.html`
- 对照仓库：LegadoTeam/Legado-docs，main，ea65937a84a54287578d0e032957377539ac2ce5。
- 依据：首页/API 明确标为 Legado Tauri；简介描述 Boa、JS 文件与核心函数；API 列出 async 和桌面 Sync 变体。

**[R4] DandanLLab/mr（README 与源码）**

- 仓库：`https://github.com/DandanLLab/mr`
- master：033e3537d8b458cd2be4a3732c74a194f6076dbf。
- 核对 README.md、lib/services/native/js_engine.dart、lib/services/native/quickjs_runtime.dart 和仓库树中的 quickjs/。
- 同步网络重跑路径：js_engine.dart 中 __NEED_NETWORK__、_javaCache、_evalLock，约 1499 行起。相关副作用风险是基于源码的推断，没有运行复现。

**[R5] Origo Source Protocol（规范与 README）**

- 仓库：`https://github.com/miloquinn/origo-source-protocol`
- main：34d7bd0d39085af37fb8979ff7beedcd729dfca6。
- 核对 SPECIFICATION.md（英文规范）、SPECIFICATION.zh-CN.md、README.zh-CN.md。
- 本次读取为 1.6 候选草案，定义 HTTP 数据边界、能力和稳定 ID；不是手机端可执行抓取脚本格式。

**[R6] QuickJS-NG 官方 C API 文档**

- `https://quickjs-ng.github.io/quickjs/developer-guide/intro/`
- 核对 runtime/context、多线程限制、JSValue 所有权、字节码限制、内存/栈/中断 API。
- 另对照 QuickJS 官方文档：`https://bellard.org/quickjs/quickjs.html`。没有把两个项目的版本等同。

**[R7] Rhino 官方 Java 互操作教程**

- `https://rhino.github.io/tutorials/scripting_java/`
- 用于说明 JavaScript 调用 Java 对象/类的语义，与“书源以 Java 源码编写”是不同概念。当前项目的 RhinoCompatibilityScripts.swift 也直接体现所兼容的宿主面。

**[R8] Apple 第一方 API 文档**

- JSContext：`https://developer.apple.com/documentation/javascriptcore/jscontext`
- WKWebView：`https://developer.apple.com/documentation/webkit/wkwebview`
- 通过对应 developer.apple.com/tutorials/data/documentation/...json 文档读取。这里只用于 API 定位，不据此作速度、审核或完整安全性的结论。

**[R9] Surge 官方文档：脚本环境与模块分发**

- Scripting Overview：支持 jsc/webview，auto 优先可用 WebView；说明初始化、跨进程传输、NE 背景和超时差异。
- JavaScript API Reference：Web API 与原生 HTTP 宿主 API 并存。
- Module：本地文本模块、URL 安装、元数据和脚本引用。

**[R10] Stash 官方文档：引擎、脚本管理与定时任务**

- Rewrite HTTP：auto 在 iOS/macOS 优先 WebKit，保留 jsc。
- Manage Scripts：远程脚本下载/缓存/更新检查、本地路径及编辑流程。
- Scheduled Tasks：后台定时脚本要求 VPN Network Extension 已连接；此条件不能套用于普通阅读 App。

**[R11] WebKit 项目官方架构文档**

- JavaScriptCore 是其 JS 引擎；WebCore 提供 DOM 和大量 Web API；WebKit 层实现多进程。

**[R12] WHATWG Fetch 标准**

- CORS、credentials、header 限制及不同资源入口的 fetch 语义。ctx.http.fetch 是建议的原生宿主接口，不假称其等同于所有标准浏览器 fetch 行为。

**[R13] Apple：WKContentWorld**

- 分离 JS 全局变量，当前页面 DOM 仍共享。只依据稳定 API 说明，不采纳页面列出的未来 Beta API。

**[R14] Apple：stopLoading 与 WKWebView 增强介绍**

- stopLoading 的文档语义是停止当前页资源加载。
- WWDC20 说明内容进程隔离、JS content worlds 及网页 DOM 的关系。

新增来源地址（同于 2026-11-08 查阅）：

- [R9] `https://manual.nssurge.com/scripting/overview.html`；`https://manual.nssurge.com/scripting/api.html`；`https://manual.nssurge.com/profile/module.html`
- [R10] `https://stash.wiki/script/rewrite-requests`；`https://stash.wiki/script/manage-script`；`https://stash.wiki/script/scheduled-tasks`
- [R11] `https://docs.webkit.org/Getting%20Started/Introduction.html`；`https://docs.webkit.org/Deep%20Dive/JSC/JavaScriptCore.html`
- [R12] `https://fetch.spec.whatwg.org/`
- [R13] `https://developer.apple.com/documentation/webkit/wkcontentworld`
- [R14] `https://developer.apple.com/documentation/webkit/wkwebview/stoploading()`；`https://developer.apple.com/videos/play/wwdc2020/10188/`


**[R15] ForwardWidgets 与 Rex Widget Libs**

- InchStudio/ForwardWidgets：master，d7a78c88a8b1a0be431a1d6bacfa5072f8d535db（查询时提交日期 2026-06-29）。读取 README.md、widgets/demo.js、forward-widgets.fwd。
- baranwang/rex-widget-libs：main，2b7430712e294a173c7f29bef9730ba4ca03ce46（2026-09-15）。读取根 README、packages/libs/README.md、packages/rslib-plugin/README.md、构建插件及 WidgetAdaptor 源码。
- 官方示例支持单文件、元数据/参数、统一数据返回；工具链支持类型、测试、构建去除 export、可选加密。后者是工具链仓库，不能由它推断 Rex App 的全部运行时。
- 工具链中元数据解析/测试的实现不代表本项目可以直接对未知来源代码采用相同执行方式，也不代表 Node/mock DOM 与 WebKit 已证明等价。

**[R16] Swipt 文档、SDK、运行时与官方示例**

- swipt-automation/swipt：main，0003c0b277daf90b977d54976a00c79955e0945e（2026-11-07）。
- swipt-automation/official-swiplets：main，c15eefc38bced2c3414cb584903328bd2bac5b19（2026-11-06）。
- 文档定义 interface/actions/services 与 .swiplet/仓库安装；源码 archive.go 使用 ZIP。cli/project.mjs 构建应用/扩展；官方 skip-chinese-ads 的 package.json、App.tsx/extension.ts 体现多文件作者形态。
- api/swiplet.d.ts：defineAction 的 Schema、输入输出类型、RunContext.signal 与 ServiceStatus。
- internal/automation/engine.go：直接使用 internal/jsc 管理 execution、异步 completion 与取消；internal/jsc/jsc.go 链接 JavaScriptCore。
- internal/automation/runtime/src/extension/scope.ts：自行安装 Fetch/URL/编码/Streams 等接口；不能因有 Web API 就推断全为 WKWebView。
- internal/jsc/jsc_thread.c：标注 private API，并动态查找执行时限等符号；不将它当 iOS 26 公开 SDK 中可直接移植的保证。
- README 的平台要求当次写为 iOS 27；本项目仍以 iOS 26+ 为目标，不因参考源码改变最低系统版本。

来源地址：

- [R15] `https://github.com/InchStudio/ForwardWidgets`；`https://github.com/baranwang/rex-widget-libs`；`https://raw.githubusercontent.com/baranwang/rex-widget-libs/main/packages/rslib-plugin/README.md`
- [R16] `https://swipt.io/zh-Hans/docs/swiplets/`；`https://github.com/swipt-automation/swipt`；`https://github.com/swipt-automation/official-swiplets`；`https://raw.githubusercontent.com/swipt-automation/swipt/main/internal/automation/engine.go`；`https://raw.githubusercontent.com/swipt-automation/swipt/main/internal/jsc/jsc_thread.c`；`https://raw.githubusercontent.com/swipt-automation/swipt/main/api/swiplet.d.ts`
