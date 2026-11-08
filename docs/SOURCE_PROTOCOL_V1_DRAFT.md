# 自有阅读书源协议 v1：候选设计

日期：2026-11-08。状态：设计草案；P2 已有实验性 App 接入和原生领域实现，但此处名称、API 与示例仍不是已发布接口。P0 已增加 [可执行候选合同与细则](../protocols/source-v1/README.md)、共享样本和 Node 静态导入原型；结果见 [首轮报告](reports/SOURCE_PROTOCOL_P0_REPORT.md)。

本草案将 Rex/Forward 的轻量数据插件、Swipt 的类型与生命周期管理、代理 App 的 Web 运行环境经验收敛为阅读器需要的小型协议。架构依据和来源见 [架构提案](ARCHITECTURE_SOURCE_PROTOCOL_PROPOSAL.md)，后续工作包、顺序和验收条件见 [实施流程](SOURCE_PROTOCOL_IMPLEMENTATION_PLAN.md)。

## 1. 核心决定

**一个源是一个可读的 JavaScript ES Module。应用调用少量固定操作，源返回结构化数据，原生宿主负责调度、状态和阅读。**

- 默认文件扩展名暂定 .source.js；支持文件、粘贴、原始文本 URL，导入后的语义相同。
- 使用标准 export const metadata 和命名函数导出，不引入专门的 JSON 注释语言，也不靠函数名字符串映射执行。
- 简单源无需构建工具；复杂项目可多文件/TypeScript 开发，构建为一个可读的、自包含的 JS 文件。
- **v1 不做安装时远程 JS 依赖图、任意远程 import、自动下载后 eval、npm 运行时或加密书源服务。** 第三方代码在开发/发布阶段固定并合并，保留许可证。更新单位是整个源文件。
- 阅读操作为 book / chapters / content；search 可选但推荐；explore / 认证等作为有明确版本的可选能力。
- 新协议以标准 JS / DOM 能力为目标，首选验证 WebKit。引擎名称不进入书源接口；Legado 有独立适配路径。
- ORSP 仅参考定义，不做适配器。v1 不扩展为任意界面、后台常驻服务或通用自动化平台。

取舍：v1 缺少可运行时更新的共享外部库，换取安装确定性、可回滚、完整源码可分享，以及较小的客户端维护面。若以后真实的规模数据证明有必要，再设计独立扩展；不现在预留一套未验收的包管理器。

## 2. 单文件合同

~~~javascript
export const metadata = {
  apiVersion: 1,
  id: "org.example.books",
  name: "示例书源",
  version: "1.0.0",
  origins: ["https://books.example.org"]
};

export async function search(ctx, { query, cursor = null }) {
  // 返回 Page<BookSummary>
}
export async function book(ctx, { ref }) {
  // 返回 BookDetails
}
export async function chapters(ctx, { book, cursor = null }) {
  // 返回 Page<Chapter>
}
export async function content(ctx, { book, chapter }) {
  // 返回 ChapterContent
}
~~~

完整说明性文件见 examples/example.source.js。它使用虚构站点，不代表真实书源。

### 2.1 元数据是数据，导入不执行代码

metadata 必须恰好有一个直接的命名 const 导出，其初始化值仅由静态对象/数组、字符串、有限数字、布尔与 null 构成；允许 JS 注释、普通标识符键和尾逗号。

静态解析器拒绝调用、变量引用、展开、计算属性、getter/setter、表达式模板和重复键。必须使用有资源限制的 ECMAScript parser 和 AST 校验，不用正则截取对象，也不通过 eval/new Function/加载整个未知模块取得元数据。

这是对标准 JS 的元数据位置施加限制，文件仍是正常 ES Module。App、CLI 共用元数据规则和测试样本；不存在注释头、导出对象、外部 manifest 三份真相。

| 字段 | v1 合同 |
| --- | --- |
| apiVersion | 协议主版本，首版为 1；破坏性变化才升主版本 |
| id | 稳定的发布源标识；不能把它当作已经验证的作者身份 |
| name | 面向用户的名字 |
| version | 源内容版本字符串，发布工具按语义化版本验证；安装同时计算内容摘要 |
| origins | 请求来源范围；精确 scheme/host/port，重定向与子资源也需检查 |
| requires | 可选的版本化扩展能力列表；无需每个源重复声明 apiVersion 已保证的基础能力 |
| author / homepage / description | 可选说明 |
| settings | 可选的小型配置 Schema，交给原生界面呈现 |

函数导出确定 search/explore 等业务能力。v1 不再要求 metadata 中重复填写 provides/functions/functionName；导入时静态检查入口，执行前再验证实际 namespace 中的值可调用。

初版 ES Module 只要求顶层声明与正常导出，不提供外部模块解析；不接受动态 import。常规网络必须经宿主 HTTP 或显式浏览器能力；不能借下载数据名义加载新的可执行代码。后者不能仅靠静态扫描保证，需要由运行环境的加载、CSP 和宿主能力策略共同落实并验证。

模块初始化有独立预算；宿主 I/O 只在操作上下文中提供。JS 顶层纯计算、静态表和 helper 允许，但模块全局变量不承担必须跨操作保留的业务状态。

### 2.2 更新、编辑与来源

安装模型分开保存：安装实例 ID、发布源 id、上游地址、上游摘要、当前源码摘要、用户修改标记、所授权范围。网络重定向或书源域名变化不改变书架条目身份。

更新先下载和验证新文件，形成新快照，再原子切换；运行中的操作固定使用开始时的源码与配置快照。不存在读目录使用旧脚本、同一个操作取正文时突然换新脚本的问题。

用户修改后默认保留本地版本，显示上游差异，允许接受上游、保留修改或另存派生源。导出本身就是完整可执行源码，凭据、Cookie、私有配置和阅读内容不进入源文件。

源集合只是可选的纯数据索引，索引内容由下载到的源元数据复核。没有中心目录也能分享和安装；相同 id 的不同发布者不自动取得替换已有源的权利。

## 3. 四项操作与恢复能力

~~~typescript
type Page<T> = {
  items: T[];
  nextCursor: Json | null;
  revision?: string;
};

type SourceRef = {
  id: string;
  url?: string;
  state?: Json;
};

type BookSummary = {
  ref: SourceRef;
  title: string;
  author?: string;
  cover?: { url: string };
};
type BookDetails = BookSummary & {
  description?: string;
  status?: "ongoing" | "completed" | "unknown";
};
type Chapter = {
  ref: SourceRef;
  title: string;
  volume?: { id: string; title: string };
};
type ChapterContent = {
  title?: string;
  revision?: string;
  body:
    | { kind: "text"; text: string }
    | { kind: "html"; html: string; baseURL: string };
};
~~~

以上为说明性类型。Json 指有深度、大小限制的 JSON 值；P0 已提供候选 Schema、纯文本规范化和一致性样本，正式发布仍需 App/设备验证。示例变量名 book/chapter 指相应 ref，而不是可被脚本修改的书架实体。

| 操作 | 输入 | 结果 | 应用负责 |
| --- | --- | --- | --- |
| search | query、cursor | Page<BookSummary> | 多源并发、渐进显示、取消、结果聚合 |
| book | ref | BookDetails | 详情合并、书架与来源身份 |
| chapters | book ref、cursor | Page<Chapter> | 拉取与去重、目录版本、更新对比 |
| content | book ref、chapter ref | ChapterContent | 缓存、预读、正文规范化、阅读位置 |

来源引用必须可持久化。id 是身份，url 是位置，state 是有上限且非敏感的站点定位信息。应用可在重启后只凭保存的引用和授权会话调用 book/chapters/content，不能要求之前的 search VM 仍存活，也不能从一个源读取另一个源的引用状态。

同名书籍、同标题章节不意味着同一个实体；跨源换源是应用的候选匹配操作，不把自动相等写入协议。旧格式缺少稳定 ID 时由适配器维护映射；不能强行去掉所有 URL 查询参数。

### 3.1 分页与目录更新

nextCursor=null 表示结束；其它 JSON 值由源解释，应用只负责保存和传回。游标绑定源版本、操作类型、查询、配置/账号作用域，不能被另一个查询复用。空 items 可能仍有下一页，应用要有重复游标和总页数限制。

目录按源返回顺序拼接；不把数组下标当 chapter ID。若提供 revision，整个目录分页应来自同一版本；变化时应用重试或标记需刷新，不能静默混合。未提供 revision 时只提供去重和刷新后的尽力一致性，不声称快照保证。

目录更新比较稳定 ID、顺序和可用的修订信息；不能只把章节数增加当更新。新增、删除、重排和正文修订分别处理。差量更新 API 可以作为以后扩展，v1 不要求每个作者实现复杂事件流。

### 3.2 正文、排版与资源

源作者可以返回普通文本或提取到的 HTML 片段，避免每个作者自行构造完整排版 AST。宿主统一转换成 ChapterDocument，然后交给原生阅读器。

text 的换行/段落规则、html 支持的元素及降级规则必须由协议一致性样本固定。初版以段落、换行、标题和少量行内强调为范围；不执行 HTML 内脚本，不导航内嵌框架，不加载页面自带 CSS。图片等媒体应通过明确扩展和资源接口接入，不隐式允许任意网页能力。

源端删除广告只是提取逻辑，不能替代宿主净化。保存抽取结果与显示净化版本，阅读位置使用规范化文本锚点，页号仅是某个布局下的缓存。EPUB 保持独立 publication/locator，不经过该简化 HTML 合同。

cover 和后续媒体资源的请求由宿主继承正确的源/账号作用域；访问凭据不写入可分享的 ref/state。资源解析、过期刷新等能力可以单独扩展，而不把签名 URL 升格为书籍身份。

content 默认返回一章的完整内容；网站内部的分页由源在同一个预算内聚合。超大正文、渐进正文将来需要独立合同，不暗中以半章成功结束。

## 4. 受控上下文

~~~typescript
interface SourceContext {
  readonly signal: AbortSignal;
  readonly config: Readonly<Record<string, Json>>;
  readonly http: SourceHTTP;
  readonly storage: SourceStorage;
  readonly log: SourceLog;
  readonly errors: SourceErrors;
  // 其它能力仅在扩展已声明并被宿主提供时出现。
}
~~~

### 4.1 HTTP 与 Web API

基础 profile 包括经过最低 iOS 26 环境验证的 Promise、URL、DOMParser/选择器、编码与必要标准对象；不对所有 Web API 作空泛承诺。WebCrypto、XPath 等复杂能力按明确支持范围/扩展定义，CLI 和设备需要使用相同样本验证。

ctx.http.fetch 是接近 Fetch 用法的原生网络桥，不宣称所有浏览器 fetch 语义都相同。v1 明确请求方法/headers/body/redirect，Response 的 status/ok/url/headers/text/json/bytes；body 消费、编码、失败与重试都要有明确规则。

浏览器全局 fetch 仍有自己的 CORS、credentials 和 header 规则；源的站点请求默认经 ctx.http.fetch。宿主默认继承 operation 的取消和 deadline，即使作者忘记传 signal 也不能泄漏请求；作者传入的额外 signal 只会进一步限制该操作。

所有站点请求、封面和浏览器派生请求必须保持来源与账号隔离，并经过原生策略或经过验证的浏览器策略。桥接只对 ctx.http 做检查而允许任意页面外连，不等于实现 origins 约束。

### 4.2 状态、认证与配置

- 临时结果放在函数/操作内；可重建的缓存允许 VM 内保存，但不能成为恢复正确性的条件。
- ctx.storage 默认按安装源与账号隔离，只承载必要源状态，有配额与原子更新；书架、目录、正文和进度由原生核心管理。
- 登录凭据由宿主凭据存储管理。源需要登录时返回 AUTH_REQUIRED 类诊断；后台任务暂停，原生交互界面在合适时机处理，随后重新发起读取。
- settings 支持少量确定类型：文本、枚举、布尔、范围受限数字；原生应用生成表单，源只读 ctx.config。密码/令牌等敏感项进入独立凭据流程。
- 发现分类/筛选可以作为数据扩展，不能通过插件任意注入 SwiftUI/React/HTML 页面。

### 4.3 错误与生命周期

正常空搜索返回空 items。NETWORK / RATE_LIMITED / AUTH_REQUIRED / PARSE / UNSUPPORTED / TIMEOUT / CANCELLED 要可区分；允许内部具体诊断码，但不把错误文本当唯一合同。

每次调用绑定 operation ID、源快照、配置、账号、deadline、日志和取消信号。返回结果后取消未等待的请求、计时器与待回调工作，不能靠游离 Promise 继续写状态。取消只结束一次；迟到结果不得覆盖新的搜索/换源结果。

Swift 任务取消、HTTP 取消、JS 停止计算和 WebContent 资源回收是不同层次。WebKit 原型必须单独验证后两者，不能把 Promise 超时当同步死循环的硬中断。协议定义用户可观察的 TIMEOUT/CANCELLED，runtime 实现同时负责会话隔离和恢复。

源不自己启动持续服务来检查更新或预读。应用统一调度目录刷新、相邻章节预读和下载，给前台阅读更高优先级；所有源使用一致的总并发、目标站点限流和资源预算。

## 5. 引擎实现与领域隔离

首选原型：WebKit 脚本工作会话 + Swift 原生网络/状态服务。书源在受控运行页内执行，使用标准 DOM 解析已获取的 HTML；需要真实网页执行的登录/动态站点使用独立浏览器会话。

WebKit 引擎不能从“别人也用”直接推导为已满足本产品性能。必须验证本地 origin/secure context、ESM、脚本与 Web API、跨源隔离、总内存、取消后恢复和多源首批结果。运行时如被更换，须实现相同 profile 及通过样本，不能静默把 DOMParser 换成语义不同的 helper。

LegadoAdapter 内部可使用自己的 DSL 与 QuickJS 同步桥。它输出同一套领域数据，并通过同一个原生请求调度服务；不把 java.* 注入新源，不尝试把所有旧脚本自动改写为 async。

## 6. 作者工具的最小闭环

不要求每个简单源使用脚手架。工具链的增益应是可选且可验证的：

| 能力 | 作用 |
| --- | --- |
| 类型定义 / JSDoc | 编辑器补全四项操作、结果和 ctx；JS 作者无需 TypeScript 编译 |
| validator | 静态元数据、导出、所需能力、固定输出 Schema；报具体字段和源码位置 |
| fixtures | 固定 HTML/JSON 响应、请求日志、目录修订和预期输出；不用真实站点稳定性冒充协议正确性 |
| builder | 多文件/TS/开发依赖合并为格式化单文件；元数据保持可静态提取，附保留的作者与许可证信息 |
| device runner | 在目标 iOS WebKit 环境跑同一源、同一 fixture；比较请求、输出、取消和状态 |
| debugger | 操作阶段、网络/解析耗时、缺失节点、能力错误与源码行；不默认记录凭据或全书正文 |

可以给常见 DOM 读取、URL 处理提供普通 helper，但避免产生第二套多分隔符的规则语言。协议 Schema 作为输出验证的单一规范，SDK/Swift 类型尽可能生成；每个源无需复制整个 Book/Chapter Schema。

CLI 的 Node/mock DOM 运行只给快速反馈，不能证明 WKWebView 行为完全一致。Rex 的测试适配器展示了工具价值；真正的设备一致性测试仍是本项目自己的职责。

## 7. 发布门槛与阶段范围

先做三个相互独立的验收：

1. **作者体验**：手写一个文件即可导入，运行路径可调试；多文件构建后仍可读；本地修改与订阅更新不互相覆盖。
2. **阅读正确性**：搜索→详情→目录分页→正文→翻章→重启→离线恢复；目录重排/删除、账号变化、源更新有明确结果。
3. **运行时稳定性**：标准 API、并发、响应大小、无限循环/Promise、取消、WebContent 回收与重建、前后台切换；用最低支持系统的真机给出结果。

首版完成自有源、兼容边界、原生阅读和上述工具闭环。远程依赖管理、插件自定义页面、常驻服务、跨源调用、任意原生模块、多种 JS 后端等价执行均不作为前置需求。

说明性示例已通过 Node AST/Schema 检查，没有执行其网站/DOM 操作；另有自造 JSON fixture 在 Node 跑通四项操作。当前 App 不具备本协议加载器，App 侧 AST 导入器和真机行为尚未实现或验证。
