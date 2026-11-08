# P0 功能与数据基线清单

日期：2026-11-08。静态基线：`e65f4dff85f4e30be0c90510734ae298edb6d320`。本清单根据仓库实现和测试入口整理，不代表所有功能已经在本机运行过。所有新边界都是实施决定，不描述为当前 App 已完成的架构。

## 1. 功能去向

| 当前能力 | 当前证据入口 | 决定与目标边界 | 后续验收 |
| --- | --- | --- | --- |
| Legado 导入、编辑、分组与启用 | Sources/LegadoCore/Import、App/Features/Sources | 保留体验，执行逻辑进入独立适配器；保留原文和未知字段 | P3/P4/P5，ImportedSourcePipelineTests、BookSourceImporterTests |
| 规则订阅与更新 | App/Features/Rules/RuleSubscriptionModel.swift | 保留旧规则订阅；自有源采用独立安装快照/冲突策略 | P3/P5，RuleSubscriptionRegressionTests |
| 搜索聚合与历史 | Sources/LegadoCore/Search、App/Features/Search | 保留，依赖统一 SourceProvider；宿主负责取消和渐进结果 | P2/P4，BookSearchServiceTests、SearchRegressionTests |
| 详情与 URL 加书 | Sources/LegadoCore/Book/NetworkBookService.swift、AddBookURLService.swift | 重做接口边界，稳定 ref 与来源实例分开 | P2/P4，NetworkBookServiceTests、AddBookURLServiceTests |
| 发现与分类 | Sources/LegadoCore/Explore、App/Features/Explore | 保留旧源路径；新协议 explore 扩展延期，不占核心 API | P4/P5，BookExploreServiceTests |
| 登录与 Cookie | App/Features/Sources/SourceLoginView.swift、HTTPClient.swift | 保留功能，原生账号范围/凭据/网站会话独立 | P1/P4/P5，SourceCookiePersistenceTests |
| 源调试与日志 | Sources/LegadoCore/Debugging、App/Features/Settings/DiagnosticLogView.swift | 保留并按操作/源码摘要记录，限制敏感数据 | P3/P4，BookSourceDebuggerTests、DiagnosticLogTests |
| 书架、分组、排序与用户元数据 | BookRepository、LibraryModels、BookLibraryModel | 保留，源实体与用户书架实体分离 | P2/P5，BookRepositoryTests、BookLibraryRegressionTests |
| 目录更新与换源 | BookUpdateCoordinator、BookSourceSwitchService | 重做身份/分页/差异比较；换源需明确匹配结果 | P2/P4，BookUpdateCoordinatorTests、BookSourceSwitchServiceTests |
| 正文、下载、缓存与预读 | ChapterContentCache、ReaderViewModel | 保留，按账号/来源/提取版本隔离，统一调度 | P2/P5，ChapterContentCacheTests、ReaderRegressionTests |
| 原生排版、翻页、滚动与位置 | App/Features/Reader、Sources/LegadoCore/Reader | 保留成熟行为并重接领域接口，不因源协议重写回退阅读体验 | P2/P5，PageDeckTests、ReaderCurlProgressTests 等 |
| 书签、笔记、历史与统计 | ReadingActivityRepository、Bookmark、ReadRecord | 保留；位置迁移单独验证，重复标题不能自动合并 | P5，ReadingActivityRepositoryTests、ReadingActivityRegressionTests |
| TXT 导入、目录规则与文件管理 | LocalBookService、LocalFileService、txtTocRules | 保留独立本地路径，不伪造远程源 | P2/P5，LocalBookServiceTests、LocalFileManagementTests |
| EPUB/插图/目录/locator | EPUBBook、EPUBReaderView、Readium 依赖 | 保留 publication/locator 与独立渲染，不压成纯文本 | P2/P5，EPUBBookTests、EPUBReaderIntegrationTests |
| RSS 源、文章、收藏与恢复 | Sources/LegadoCore/RSS、RSSRepository、App/Features/RSS | 保留独立领域；暂不扩进书源 v1 | P5，RSSRegressionTests、RSSLibraryRegressionTests |
| TTS 与朗读设置 | HttpTTSService、ReaderSpeechController、httpTTS | 保留；依赖规范化文本/现有配置，暂不引入源侧音频能力 | P5，现有配置与朗读设备回归 |
| 替换/净化规则 | ReplaceRuleRepository、ContentSanitizer、ReplaceRuleTester | 保留用户规则；源净化与宿主安全规范化分层 | P2/P5，ReplaceRuleExecutionTests、ContentSanitizerTests |
| 阅读外观、交互和全局设置 | App/Features/Settings、ApplicationSettingsStore | 保留已支持设置；版本化转换，去掉无效旧值需有记录 | P5，ApplicationSettingsTests、AppearanceContrastTests |
| 深链接与文件选择 | App/LegadoApp.swift、RuleEditorUITests | 保留旧导入入口，增加自有单文件语义；取消/重开仍可用 | P3/P5，现有文件导入 UI 回归 |
| 服务配置、字典、键盘辅助 | ConfigurationRepositories、v5 数据表 | 保留原始配置；未完成/无界面部分不在重写时静默丢弃，产品支持范围在 P5 复核 | P5 配置迁移检查 |

“保留”指产品行为和数据的目标，不要求沿用原类。未列为延期的现有功能不能因核心演示成功自动从发布范围消失。新扩展（explore、浏览器、认证、媒体）须有独立合同；ORSP 不设适配任务。

## 2. SQLite v7：21 张业务表

来自 `Sources/LegadoCore/Persistence/LegadoDatabase.swift` 的静态迁移块。实际 SQLite 另建内部表 sqlite_sequence，不计入业务表数。所有 payload 均需在 P5 通过 Swift 解码/编码对照；本轮只验证 SQL 与合成字节保留。

| 表 | 当前身份/数据 | 迁移去向与注意事项 |
| --- | --- | --- |
| book_sources | book_source_url 主键，payload、position/group/order/enabled | 安装源+原始 Legado 文档；URL 不再充当唯一安装身份 |
| books | book_url 主键，name/author 唯一索引，payload | 书架实体+来源引用；新域不能继承跨源同名同作者必然相同的假设 |
| chapters | url+book_url 主键，book_url+chapter_index 唯一 | 稳定章节映射+目录顺序；保留 URL 参数，重复标题不合并 |
| book_groups | group_id、payload、position | 用户分组，保留排序 |
| bookmarks | time 主键、payload | 笔记/书签实体，保留文本和旧定位；身份转换需防时间冲突 |
| read_records | device_id+book_name 主键、payload | 读取历史与统计；同名书聚合的旧歧义不能猜测修正 |
| search_keywords | word、usage、last_use_time | 搜索历史，保留排序/频次语义 |
| caches | key、value、deadline | 逐命名空间分类：源状态/登录头/配置与可丢弃缓存分开 |
| cookies | url、cookie | 旧账号会话映射，禁止导出进源文件 |
| searchBooks | book_url、origin、payload 等 | 可重建搜索缓存；若引用已入书架先保留关系 |
| txtTocRules | 规则及 payload | TXT 目录规则保留 |
| dictRules | 规则配置 | 保留原始内容，产品入口范围待复核 |
| httpTTS | TTS 配置及 payload | 朗读服务配置保留，敏感字段不能进公共样本 |
| ruleSubs | 订阅配置及 payload | 旧订阅原样保留；新源索引不假装同一协议 |
| keyboardAssists | 辅助配置 | 保留，不强行解释为源能力 |
| servers | 服务配置 | 保留并单独处理可能含凭据的字段 |
| rssSources | source_url 主键、payload | RSS 独立源身份映射 |
| rssArticles | origin/link/sort 联合主键、payload | RSS 文章缓存/已读关系保留 |
| rssReadRecords | record 主键、origin、payload | RSS 阅读位置/历史保留 |
| rssStars | origin+link、payload | RSS 收藏分组和正文关系保留 |
| legacy_imports | key | 迁移检查点；不能丢失后重复导入旧文件 |

## 3. 数据库外的状态

| 位置/机制 | 内容 | 工作要求 |
| --- | --- | --- |
| Application Support/Legado/legado.sqlite3 | 主库；见 LegadoDatabase.live | 备份包含必要 WAL 一致性，不能复制一个正在写的文件冒充快照 |
| Caches/Legado/Chapters | CachedChapterContent JSON，键取决于 bookURL/chapterURL | 章节和账号映射确认前不批量清空；可恢复离线正文要区别于临时布局缓存 |
| `loginHeader_<sourceID>` | caches 中的登录请求头 | 本机凭据迁移，范围与来源映射一致 |
| `v_<sourceID>_<key>` | caches 中的持久化源变量 | 保留原始键和值，迁移不能只扫描 `cookies` 表 |
| `sourceCookies_<sourceID>` | caches 中的序列化 Cookie | 与 cookies 表/内存 CookieStore 同时核对，不把其中之一误认唯一来源 |
| `legado.applicationSettings.v1` | UserDefaults 中的应用设置 JSON | 转换已知键，未知键留恢复材料 |
| 阅读外观/历史界面等 UserDefaults 状态 | 页面/阅读偏好、部分快照 | P5 前逐键导出与对照；本轮没有读取个人 defaults |
| FileReplaceRuleRepository 等 JSON repository | 替换规则、旧书架/活动等历史文件 | 确认 App 装配使用路径与旧导入标记，原始文件先保留 |
| 导入 TXT/EPUB 与资源目录 | 文件、publication 关系、可访问性 | 与已有本地夹具共同验证；路径变更不能丢失书架引用 |
| 导出/临时/回收目录 | 临时导出与待恢复文件 | 分类后清理，不能当全部为可丢弃用户内容 |

## 4. 本轮合成样本和不足

`protocols/source-v1/fixtures/migration/legacy-v7-seed.json` 包含一源、一书、两个同标题不同 URL 章节、一条书签/笔记、阅读记录、三个源状态键和一个合成 Cookie。未知源字段、URL 查询参数和阅读到第二章的位置均有断言。

`scripts/source-protocol-baseline.py` 读取锁定代码中的静态 SQL，分别构造 v1–v7 数据库并检查 integrity/foreign_key；v7 写入合成 payload 再读回。它不执行 Swift 中 SQL 之外的迁移逻辑，也没有验证新架构迁移。

真实用户备份、多个历史版本真实 payload、大库、局部损坏库、实际 TXT/EPUB 关系、Swift Codable 对照仍缺证据。它们记录为 P0-02/P5 的后续输入，不能由这一个合成库替代。
