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

该策略先解决正确性；大目录的重复解码成本、缓存容量淘汰和下载进度另行验收。后台重试不能绕过这些检查，也不能自动删除用户的离线副本。
