# P0 原生领域接口草图

状态：设计草图，没有加入 Swift target。作者数据类型见 schema.json；这里定义宿主内部边界，不扩大书源 API。

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

P2 再把这些职责落实为 Swift 类型与协议，避免在 G1 之前创建未验证的全套 Package。数据 shape 从 Schema 生成的 Swift 映射也在该阶段交付。
