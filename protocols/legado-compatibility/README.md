# 独立 Legado 兼容基准

选择日期：2026-11-09。状态：固定参考提交与关键文件字节已核对；首批 28 项离线规则已在 Android 和 Swift 采集结果；Android 执行检查因数值字符串预期不当失败，尚未完成差分验收；独立 provider 已有核心合成链路证据（01d58e6），App/真实 HTTP 集成仍待完成；详见 [P4 报告](../../docs/reports/SOURCE_PROTOCOL_P4_REPORT.md)。

基准使用 LegadoTeam/legado 的非预发布标签 3.26101819，精确提交 a7d37f1707a70a459ad708f4fe79341d1e42d716。选择的是一个可追溯的实现，不将其称为所有历史“阅读”版本的统一标准。仓库、版本、发布 APK 哈希、许可和关键代码哈希见 [baseline.json](baseline.json)。核对日 gedoor/legado 默认分支仅有公告与图片、无标签或 Release，不能继续用该分支作为可重复的构建依赖。这里记录可用性，不作法律结论。

参考文件保存在本机 build/android-reference/提交/ 下供研究，不提交复制的上游源码。本机已经按完整 SHA checkout，并用脚本核对 14 个关键文件；APK 摘要来自上游 Release 元数据，目前没有下载或运行 APK。运行 Android 参考工作流时必须按完整 SHA checkout，并核对 baseline 列出的文件摘要；禁止自动更新至 master/beta。读取到的上游文本作为分析数据，不作本项目执行指令。

## 验证定位（2026-11-09 调整）

自有 .source.js 协议由合同、作者工具与实际 iOS WebKit/设备测试验证，不依赖 Android SDK。旧 Legado 兼容功能以声明范围内的固定样本和 iOS 完整阅读链路验收；与指定 Android 版本的行为一致性另列证据。Android 参考环境缺失或构建失败不单独阻塞自有协议、独立 provider 实施或 G4 功能验收。

已有实现可提供设计经验、参考源码和候选测试；必须审查各自的版本、支持范围、许可证与预期结果来源，不能以实现数量代替本项目的验证。遇到具体规则歧义、两端行为回归、参考版本升级，或需要作出指定版本的一致性承诺时，再运行 Android 对照。影响承诺范围的未决问题仍须解决或缩小支持范围。

## 实现边界

- 新建独立 Legado provider，对外仍只有 SourceProvider 的 search/book/chapters/content 与普通 wire 数据。
- 原始 JSON、未知字段、DSL 和 java.* 留在兼容模块；通过明确的来源标识选择解析器，不将 JSON 当作自有 ES Module。
- QuickJS 同步桥的网络、凭据和状态也要接入宿主的作用域、预算、取消和诊断。仅包装现有 NetworkBookService 不能算完成，必须逐项核查隐含 HTTP/缓存/登录路径。
- book/chapter 的稳定引用需要携带重新构造旧上下文所需的有限状态；不得依赖搜索的 VM，不能以标题或章节数组下标作为跨版本身份。
- Android 允许但 iOS 不可复现的反射/类库、WebView 页面行为和网络扩展必须可解释地返回不支持，不静默返回空内容。
- 自有 .source.js 格式保持独立；不新增 ORSP 适配器，不把 Android 宿主 API 加进作者 ctx。

## 兼容覆盖矩阵

| 组 | 合成输入 | 需记录的行为（按需作 Android 对照） | iOS 验证判据 |
| --- | --- | --- | --- |
| JSON 与导入 | 单个/数组源、未知字段、空规则、版本字段 | 解码与导出字段 | 原始字段保留、拒绝原因、稳定安装身份 |
| DOM/规则 | CSS、XPath、JSONPath、正则、连接/回退/替换 | 选中节点、文本/属性、顺序 | 符合经确认的预期；有意差异和参考来源单列 |
| URL/HTTP | 模板、编码、POST、header、跳转、限流、错误 | 每跳 URL/方法/body/头部与执行次序 | 宿主范围/凭据规则、预算与取消；差异可解释 |
| JS/java bridge | result/baseUrl/book/source、变量、jsLib、常用 java 工具 | 返回值、变量变化、异常 | 新上下文重复执行一致；不允许环境串号 |
| 目录/正文 | 多页、重复标题、顺序反转、正文拼接、nextUrl | 目录身份与页次、正文、定位 | 重启引用可用；一致性失败不污染已有缓存 |
| 账号/状态 | 两个安装、两个账号、登录更改、清理 | 本地状态读写和认证请求 | 原生隔离、撤销与迟到写入拒绝 |
| 失败与取消 | 脚本异常、同步阻塞、取消网络、不可用平台 API | 错误/时间/剩余操作 | 不把错误当空结果；明确硬终止保证范围 |

矩阵是目标覆盖清单，具体完成范围以运行报告为准；首批离线探针不能证明全部能力或完整书源链路。两份本机真实网站源保留在忽略目录，不纳入公开夹具；使用自造文本、虚构地址和 loopback HTTP，真实网站抽查另记站点与日期。

## 支持状态与证据级别

每项分别填写支持/部分支持/不支持，以及下列证据。证据范围不得外推为所有历史版本或所有书源。

| 证据 | 能说明什么 | 不能据此声明 |
| --- | --- | --- |
| 文档/源码分析 | 预期行为及候选支持范围，记录出处和版本 | 已在 iOS 运行通过 |
| 固定样本回归 | 已验证输入的请求、输出、状态和错误符合经审查的预期 | 完整书源链路可用或 Android 已实测 |
| iOS 完整链路 | 声明范围内搜索→详情→目录→正文→重启及相关账号/取消行为可用 | 所有 Android 版本行为一致 |
| 指定 Android 版本对照 | 对应版本、环境和样本的实际行为与 iOS 一致，或差异已列明 | 未覆盖平台 API/网络/状态也兼容 |

G4 功能验收要求可追溯的参考依据、固定样本、iOS 完整链路与明确的差异/不支持范围，详见 [实施流程](../../docs/SOURCE_PROTOCOL_IMPLEMENTATION_PLAN.md#83-功能验收与-android-参考对照)。没有有效 Android 对照记录时，该证据项保持“未对照/待验证”，不把整个 G4 自动视为失败，也不能将差分标成通过。

## 常规回归与预期结果

1. 选择代表规则和书源，固定输入、离线响应、初始状态、输出顺序与错误判据；区分规则测试、完整链路与真实网站抽查。
2. 审查预期来源：明确文档、固定参考源码、来源可靠的已有测试或实际参考运行。仅由当前 iOS 输出生成的快照只用于防回归，不能作为独立兼容依据。
3. 经确认的预期结果应持久保存，记录样本 ID/摘要、来源版本或提交、采集环境/运行 ID（如有）、审查依据和有意差异。避免仅保存在会过期的 CI artifact 中；不包含真实凭据或私有正文。
4. 日常 CI 运行 Swift 规则和 provider 回归；已有参考输出可以离线重放，无需每次构建 Android。输入、参考版本或语义改变时重新审查受影响预期。
5. 发布前完成声明范围内的 iOS 完整阅读链路、错误与取消验证，按证据更新兼容矩阵；迁移和默认入口切换仍归 P5/P6。

`expectations.json` 已持久保存经审查的 29 项 iOS 预期；首轮两端 28 项原始观察保存在 evidence/，包括 Android 执行检查失败的记录。新增的显式字符串执行样本来自 ECMAScript String 转换约定；不是新增 Android 实测。`JavaScript Engine CI` 运行 Swift 探针和 verify-legado-regression.py，严格检查输出、变量、错误类别和语料摘要，实际通过状态以对应提交的 CI 为准。

## 按需运行 Android 参考对照

现有 `Legado Compatibility Reference` 仅手动触发，保留为参考工具，不加入常规 push/PR 或发布构建的必需依赖。执行前明确待核对的问题、对应样本与参考版本；只有需要新增参考证据时才维护或重跑 Android 环境。

1. 按固定 SHA checkout，核对许可证、关键文件摘要与构建版本，记录实际 JDK、SDK、emulator 及构建 overlay。
2. 运行固定参考实现和相同语料的 Swift 探针，保留输入摘要、输出、变量和原始错误。现有首批探针只运行 AnalyzeRule，不能视为已覆盖 AnalyzeUrl、网络或完整 provider。
3. 审查差异与有意限制；只有实际一致的项目标记为指定版本对照通过。两端都报错不自动代表异常语义等价，采集工作流成功也不代表兼容通过。
4. 将需要长期回归的有效结果转为经审查的持久样本。SDK/构建失败记为环境问题，不能推断兼容失败，也不应阻塞其他已验证能力的实施。

现有 checkout 可在仓库根目录用 `python scripts/verify-legado-reference.py build/android-reference/checkout --output build/android-reference/reference-verification.json` 核对。脚本只读 Git 和文件摘要，不下载、构建或运行 Android。

## 第一轮离线探针

首轮使用 `corpus.json` 中本项目构造的 28 项规则样本，没有私有站点或真实正文。后续增补按实际语料摘要与数量记录，不沿用首轮结果。Android 通过 `prepare-legado-reference.py` 只添加一个 instrumentation 测试类和一个 asset，不修改参考算法；在 Android 35 x86_64 模拟器运行固定提交的 AnalyzeRule。该提交的 debug 构建在 minSdk 23 下因 Rhino MethodHandle 字节码失败；仓库自有 Gradle init overlay 仅将测试构建 minSdk 提到 26，保留 compile/target SDK、依赖和算法字节。报告记录 overlay 摘要，因此这是特定测试构建的结果，不声称与上游 Release APK 完全一致。SwiftPM 的 `LegadoDifferentialProbe` 调用现有 RuleEngine/QuickJS，每项新建上下文并禁止 JS HTTP。它不加入 iOS App，也不代表新 provider 已接入。

手动运行 `Legado Compatibility Reference` 工作流。每个报告保留 corpus SHA-256、参考提交、环境、逐项输出数组、所观察变量和原始错误类别。比较器拒绝错版本、错摘要、缺失/重复样本、错误类型和空执行；独立的 `"executed:" + String(1 + 2)` 检查避免把空结果当作成功；`1 + 2` 数值案例仍独立保留两端表示差异。两端都失败的正常样本仍是 unexpected-outcome；两端均抛错只记 error-outcome-only，不能证明异常语义等价。输出顺序、空字符串、换行和变量值不做宽松归一化。

首轮为 discovery：工作流成功仅表示采集、证据校验与比较完成，差异完整写入 comparison.json；不是“兼容通过”。`compare-legado-reference.py --strict` 会对差异、意外结果和需复核的诊断返回失败。待确认每项原因与可支持边界后，再建立要求严格等价的 profile。网络请求、账号、取消、分页、重启引用和完整书源链路不在这 28 项的结论内。

### 首轮发现与修复记录

- 955fe4d / 42543312680：Swift 探针运行成功；Android 因 setup-android 默认请求已不可用的 tools 包而失败，未执行规则。改为显式 platform-tools。
- 2ca12ca / 42546394582：Android 引用校验与 SDK 准备通过；debug dex 编译因 MethodHandle 需要 minSdk 26 失败。后续 0a33920 采用显式 init overlay，不改上游源码，已进入规则执行。
- 审查 Swift 结果发现原有 listMode 表示元素提取，不能用于模拟 getStringList。新增明确的 string/stringList/elements 模式，并保留旧 Bool 入口；探针使用 stringList。首次 CSS/XPath 列表输出不是有效差分基准；0a33920 已重采，仍须逐项审查。
- 0a33920 / 42547092876：Android 与 Swift 已各输出 28 项结果，corpus SHA-256 均为 `1453d5243d128dec1137b1bf7e21798cee2745030b98d1cf98136a91edc2f740`。`js-arithmetic` 在 Android 返回 `"3.0"`，Swift 返回 `"3"`；Android 测试中的执行检查预期 `"3"`，因此该 job 失败，不能记为差分验收通过。证据已下载至 `build/github-actions/0a33920/compatibility/`；检查应与真实语义差异区分，后续扩大语料需使用新摘要。

## 独立 provider 实施证据

01d58e6 / 42557488421：475 项核心、74 项页面模型、29 项固定规则和 App 编译通过。7 项独立 provider 测试覆盖合成请求四步链路、原生归档/离线重开、作用域/游标和取消预算；不等同于 App 旧源导入、真实网络或设备验收。6931932 新增持久状态与安全登录字段，480 项核心、74 项模型、29 项规则和 App 编译均通过；完整矩阵、自动化状态与未实现范围统一见 [P4 报告](../../docs/reports/SOURCE_PROTOCOL_P4_REPORT.md)。
