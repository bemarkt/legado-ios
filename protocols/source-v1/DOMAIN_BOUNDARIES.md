# P0 原生领域接口草图

状态：职责草图，已有实验性 Swift 实现；映射和限制见文末。作者数据类型见 schema.json；这里定义宿主内部边界，不扩大书源 API。

## 身份和值类型

| 类型 | 必要字段与语义 |
| --- | --- |
| InstalledSource | installationID、publisherID、format(native/legado)、upstream、activeSnapshot、授权范围、本地修改标记 |
| SourceSnapshot | 源码摘要、源版本、协议版本/兼容 profile、不可变源码位置、配置 schema |
| AccountScope | installationID、accountID；访客也是显式范围，不泄露凭据 |
| OperationSnapshot | operationID、installationID、源码摘要、accountID、configRevision、deadline、取消与诊断上下文 |
| ScopedBookRef | installationID、accountID、SourceRef；源只看 SourceRef 部分 |
| ScopedChapterRef | ScopedBookRef、章节 SourceRef；章节 id 在一本书内唯一 |
| CursorEnvelope | 操作类型、query/config/account 指纹、源码摘要、可选目录 revision、源游标 JSON |
| ChapterDocument | 规范化版本、内容修订、顺序 block、有限 mark、纯文本索引 |
| ReadingAnchor | 书籍/章节稳定身份、规范化版本、UTF-16 offset、上下文文本；页码只是布局缓存 |
| PublicationLocator | EPUB 的独立 publication/locator，不伪造为网络章节游标 |

源的 ref 不携带宿主 installationID/账号凭据。宿主不能单凭作者的 publisherID 判断两次安装来自同一人。跨源书籍相似性由换源服务判断，不能进入 equality/hash。

## 服务签名示意

```text
SourceProvider
  descriptor -> installed source and supported operations
  search(operation, SearchInput) -> SearchPage
  book(operation, BookInput) -> BookDetails
  chapters(operation, ChaptersInput) -> ChapterPage
  content(operation, ContentInput) -> ChapterContent

SourceExecutor
  invoke(immutable source snapshot, operation context, operation, JSON input)
    -> validated JSON result or structured error
  invalidate(session identity, reason)

HostNetwork
  request(operation context, scoped request) -> bounded response
  cancel(operation identity)

SourceStateStore
  get(scope, key) -> StorageEntry?
  set/remove(scope, key, precondition) -> atomic result

LibraryService
  aggregateSearch / addBook / refreshCatalog / switchSource / download
  接收 SourceProvider，不接收 BookSource 旧 DSL 或引擎对象

ContentRepository
  load/save(scoped chapter, extraction version, content revision, document)

ReaderDocumentLoader
  load(scoped chapter or local publication) -> reader input
```

作者方法使用 ctx；宿主接口另外携带不可伪造的操作范围。`SourceProvider` 是 native/Legado 的统一边界，两个适配器可以拥有不同执行引擎。执行器不持有书架，网络服务不依赖 JavaScript 类型，阅读器不解释 source DSL。

依赖方向：App 装配 → Library/Reader → SourceContracts；适配器和运行时实现 SourceContracts 并调用 HostNetwork/StateStore。TXT/EPUB 使用独立本地加载路径，复用通用书架和阅读位置存储，不强制实现搜索操作。

当前实验实现位于 `Sources/LegadoCore/SourceDomain`：`SourceProvider`、`SourceWire`、`SourceArchive`、`SourceLibraryService`、`ChapterDocument` 与 `SourceWorkScheduler`。Swift wire 类型从 Schema 生成，保留 null 与缺失值的区别。下方接口草图是职责说明，Swift 实际签名以这些文件为准。

`App/SourceRuntime/WebKitSourceProvider`（定义于 `SourceRuntime.swift`）把原生域接到 WebKit。原生阅读预览不依赖旧 `BookSource`，独立 SQLite 不改动旧数据库。当前 Xcode App target 直接编译核心文件，SwiftPM 使用 `LegadoCore`；尚未拆成上述同名独立 Package。G1 仍缺真机资源证据，实验实现不等于正式迁移获准；参见 [P2 报告](../../docs/reports/SOURCE_PROTOCOL_P2_REPORT.md)。

## 章节缓存与目录刷新（2026-11-09）

- 正文保存完整请求的 book/chapter ref、执行身份，以及宿主目录缓存代次。宿主字段不进入 `.source.js`，也不增加作者 API。
- 只有显式非空 revision、执行身份、book ref 和整个章节列表均未改变，目录刷新才保留缓存代次。缺失 revision、修订变化、标题/ref/state/顺序/成员变化会产生新代次；修订值随后恢复成旧字符串也不会复活旧缓存。
- `current` 只复用身份、引用和代次均匹配的正文；`reload` 明确绕过缓存重新获取；`offline` 在同一安装/账号内读取已下载副本，不声称是网站最新内容。下载失败不会删除旧正文。
- 目录 revision 与正文 revision 是独立的不透明值，不能互相比较。未抓取正文前无法知道它是否被网站静默修改；缺少修订信息时需要刷新目录或显式刷新本章。
- 在线缓存命中检查在单个数据库事务内完成。未命中的请求保存目录快照与旧缓存摘要，返回时在同一个 SQLite 事务中比较并写入；目录已改变或另一连接已写入新缓存则拒绝迟到结果。操作提交门禁仍负责终态/取消，目录检查负责快照一致性。
- 旧数据库缺少缓存来源信息时仍可离线打开，在线重新获取后补齐。规范化版本变化只从保存的原始结果重新生成文档，不需要访问网络。

目录解析、规范化摘要与章节引用索引按记录版本复用。数据库从 v2 起通过同事务触发器维护记录版本；每次读取在事务内核对对应目录版本，其他书籍/章节/位置的提交不触发整本重解码，外部连接的目录修改则立即使旧索引失效。回滚后也必须重新核对持久记录，不能信任未提交索引。

索引采用 LRU，默认最多 4 本、合计 100,000 条章节引用和 32 MiB 编码字节；编码字节仅用于计量，不代表 Swift 堆内存占用。超限目录仍可读取但不驻留，内存告警清空索引。此处只控制目录索引。正文存储采用下述独立配额；后台重试不能绕过一致性检查，也不能自动删除用户保留的离线副本。

## 搜索分页会话

`SourceSearchPager` 为一次查询绑定一个不可变 provider 和游标 envelope；游标不从 UI 传回作者，UI 只请求下一页。成功的有效页才消费游标，空页和跨页重复项仍可向后推进；重复游标、revision 不一致和预算超限结束会话。没有 revision 时保留首次稳定 ID 结果，不能宣称网站分页是原子快照。

App 以有限并发协调各安装的 pager，网络错误可手动重试；取消或查询/配置变更丢弃会话。取消后不恢复可能已经消费但尚未显示的游标。书架添加检查搜索时的执行身份，避免把旧查询的 ref 交给更新后的书源。

## 原生 HTTP 策略（2026-11-09）

`SourceHostHTTPClient` 位于原生核心；App 的 `SourceHTTP` 只共享客户端实例并将错误转换为运行时封套，源码导入和书源站点请求复用它。JS 不参与许可计数、重试或截止时间管理。

每跳响应在释放网络许可前关闭，目标经过 origins 校验后重新排队；不持有 A 的许可等待 B。`SourceWorkScheduler` 内部采用 `ContinuousClock`，保留 Date 入参的单次转换兼容入口。客户端把队列、每跳传输及重试等待纳入同一截止时间，慢速持续响应也不能续期；到期主动取消 URLSession。

操作级 `SourceHTTPRequestBudget` 覆盖 fetch、重定向和重试；每次取得许可后消耗一次，JS 的桥接调用数限制仍保留。GET/HEAD 有限重试、Retry-After、跨 origin 头部处理和字节限制见 [HTTP 候选语义](README.md#5-http-候选语义)。账号 Cookie/令牌已接入每跳原生请求，账号界面与临时登录浏览器由本轮集成单独验证；封面请求接入仍是后续工作。

## 正文存储容量与保留

数据库 v3 为正文维护独立元数据和事务内总量，统计无需解码所有正文。阅读产生的缓存默认 128 MiB，按最近使用淘汰；主动下载默认 1 GiB，始终保留，超限时请求失败并保留原内容。上限、访问顺序和总量跨连接共享；正文、计量、淘汰和提交门禁处于同一事务。限制指编码内容量，不包括 SQLite 页、索引和 WAL 的实际磁盘开销。

升级前正文全部按保留下载处理。下载有效缓存只改变保留状态，不必重新请求；后续普通读取或刷新不会降级其保留状态。旧数据高于默认上限时仍可阅读和缩小，只拒绝继续增长。规范化升级需要更多空间时可临时生成文档，保留原始副本以供后续持久化。

手动清理区分临时缓存与保留下载，界面明确范围并确认。清理更新存储代次；准备阶段已开始的正文请求不能在清理后写回。来源、书架、目录和位置保持独立。当前不自动压缩数据库文件；释放的页可由后续写入复用。

## 账号、原生凭据与临时登录窗口

本地账号 ID 由宿主生成，scope 为安装 ID + 账号 ID；名称只作界面别名。书架/缓存/进度/config/storage 以 scope 隔离，当前选择保存在实验库。切换账号保留其本地数据，但撤销旧 provider；返回原账号可继续读取。清除登录仅清空凭据并改变登录代次，不删除该账号的离线数据。

Cookie 与 Bearer 由独立 Keychain 适配器保存，浏览器与 JS 作者均不取得钥匙串接口。HTTP 按精确 origin（包括端口）逐跳选取账号凭据，Set-Cookie 留在宿主；配置、SourceRef、源码导出没有自动附加凭据。显式改登录会产生新 credentialRevision 并撤销旧提交门禁；日常 Cookie 轮换保留代次。门禁拒绝迟到结果/写入，不撤销已经发送的 HTTP 副作用。

网站登录使用独立非持久 WKWebView，不注册作者 bridge；一次仅打开一个选定 HTTPS origin，Cookie 也只预载和替换这个网站，避免 WebKit 的域 Cookie 把不同端口的原生凭据混合。原生导航和内容规则限制网站范围；页面加载的 Cookie 只在用户点保存后提交。当前不支持跨站 OAuth/SSO、依赖其他网站资源的登录，以及从 localStorage 提取凭据。规则通过不等同于所有 Web API 的网络隔离证明，WebSocket、嵌套资源重定向等仍需专项证据。

凭据编辑保留安装摘要、选中账号和可撤销编辑门禁；账号/源码变更后旧表单不能落盘。更新源码前捕获所有账号配置，在同一数据库事务内检查是否有新增账号或配置变化；重置范围明确为所有账号。源码回滚不恢复账号或网站状态。
