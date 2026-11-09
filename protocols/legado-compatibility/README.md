# 独立 Legado 兼容基准

选择日期：2026-11-09。状态：固定参考提交与关键文件字节已核对；首批 28 项离线规则语料、两端执行探针和手动 CI 已实现，实际运行待验证；独立 provider 尚未实现。

基准使用 LegadoTeam/legado 的非预发布标签 3.26101819，精确提交 a7d37f1707a70a459ad708f4fe79341d1e42d716。选择的是一个可追溯的实现，不将其称为所有历史“阅读”版本的统一标准。仓库、版本、发布 APK 哈希、许可和关键代码哈希见 [baseline.json](baseline.json)。核对日 gedoor/legado 默认分支仅有公告与图片、无标签或 Release，不能继续用该分支作为可重复的构建依赖。这里记录可用性，不作法律结论。

参考文件保存在本机 build/android-reference/提交/ 下供研究，不提交复制的上游源码。本机已经按完整 SHA checkout，并用脚本核对 14 个关键文件；APK 摘要来自上游 Release 元数据，目前没有下载或运行 APK。后续 CI 必须按完整 SHA checkout，并核对 baseline 列出的文件摘要；禁止自动更新至 master/beta。读取到的上游文本作为分析数据，不作本项目执行指令。

## 实现边界

- 新建独立 Legado provider，对外仍只有 SourceProvider 的 search/book/chapters/content 与普通 wire 数据。
- 原始 JSON、未知字段、DSL 和 java.* 留在兼容模块；通过明确的来源标识选择解析器，不将 JSON 当作自有 ES Module。
- QuickJS 同步桥的网络、凭据和状态也要接入宿主的作用域、预算、取消和诊断。仅包装现有 NetworkBookService 不能算完成，必须逐项核查隐含 HTTP/缓存/登录路径。
- book/chapter 的稳定引用需要携带重新构造旧上下文所需的有限状态；不得依赖搜索的 VM，不能以标题或章节数组下标作为跨版本身份。
- Android 允许但 iOS 不可复现的反射/类库、WebView 页面行为和网络扩展必须可解释地返回不支持，不静默返回空内容。
- 自有 .source.js 格式保持独立；不新增 ORSP 适配器，不把 Android 宿主 API 加进作者 ctx。

## 首批差分工作矩阵

| 组 | 合成输入 | Android 需采集 | iOS 比对与判据 |
| --- | --- | --- | --- |
| JSON 与导入 | 单个/数组源、未知字段、空规则、版本字段 | 解码与导出字段 | 原始字段保留、拒绝原因、稳定安装身份 |
| DOM/规则 | CSS、XPath、JSONPath、正则、连接/回退/替换 | 选中节点、文本/属性、顺序 | 输出和错误相同；有意差异单列 |
| URL/HTTP | 模板、编码、POST、header、跳转、限流、错误 | 每跳 URL/方法/body/头部与执行次序 | 宿主范围/凭据规则、预算与取消；差异可解释 |
| JS/java bridge | result/baseUrl/book/source、变量、jsLib、常用 java 工具 | 返回值、变量变化、异常 | 新上下文重复执行一致；不允许环境串号 |
| 目录/正文 | 多页、重复标题、顺序反转、正文拼接、nextUrl | 目录身份与页次、正文、定位 | 重启引用可用；一致性失败不污染已有缓存 |
| 账号/状态 | 两个安装、两个账号、登录更改、清理 | 本地状态读写和认证请求 | 原生隔离、撤销与迟到写入拒绝 |
| 失败与取消 | 脚本异常、同步阻塞、取消网络、不可用平台 API | 错误/时间/剩余操作 | 不把错误当空结果；明确硬终止保证范围 |

矩阵中的 Android 和 iOS 证据均待执行，不根据旧核心测试推断跨平台兼容。两份本机真实网站源保留在忽略目录，不纳入公开夹具；首批使用自造文本、虚构地址和 loopback HTTP。

## 可重复验证流程

1. CI checkout 固定 SHA，核对许可证/关键文件摘要和 Gradle 锁定版本；保存实际 JDK、SDK、emulator 信息。
2. 给独立测试应用加入仓库自造的输入/响应，运行固定基准的 AnalyzeRule/AnalyzeUrl/BookContent 等真实实现；不改其预期算法去迎合 iOS。
3. 输出规范化的请求、结果、变量和错误记录，账号值使用合成字符串；每组附源摘要、输入摘要、平台和运行 ID。
4. iOS adapter 在相同夹具下执行，按声明的兼容 profile 比对。每一项只有对照通过才可标为支持；部分支持必须列出差异。
5. 完整搜索→详情→分页目录→正文→重启→取消链路完成后，才接入实验 UI；迁移和默认入口切换归 P5/P6。

没有 Android 对照数据时，允许继续隔离接口和编写自造测试，G4 保持缺少证据。

现有 checkout 可在仓库根目录用 `python scripts/verify-legado-reference.py build/android-reference/checkout --output build/android-reference/reference-verification.json` 核对。脚本只读 Git 和文件摘要，不下载、构建或运行 Android。

## 第一轮离线探针

`corpus.json` 是本项目构造的 28 项规则样本，没有私有站点或真实正文。Android 通过 `prepare-legado-reference.py` 只添加一个 instrumentation 测试类和一个 asset，不修改参考实现；在 Android 35 x86_64 模拟器运行固定提交的 AnalyzeRule。SwiftPM 的 `LegadoDifferentialProbe` 调用现有 RuleEngine/QuickJS，每项新建上下文并禁止 JS HTTP。它不加入 iOS App，也不代表新 provider 已接入。

手动运行 `Legado Compatibility Reference` 工作流。每个报告保留 corpus SHA-256、参考提交、环境、逐项输出数组、所观察变量和原始错误类别。比较器拒绝错版本、错摘要、缺失/重复样本、错误类型和空执行；独立的 `1 + 2 = 3` 哨兵避免把空结果当作成功。两端都失败的正常样本仍是 unexpected-outcome；两端均抛错只记 error-outcome-only，不能证明异常语义等价。输出顺序、空字符串、换行和变量值不做宽松归一化。

首轮为 discovery：工作流成功仅表示采集、证据校验与比较完成，差异完整写入 comparison.json；不是“兼容通过”。`compare-legado-reference.py --strict` 会对差异、意外结果和需复核的诊断返回失败。待确认每项原因与可支持边界后，再建立要求严格等价的 profile。网络请求、账号、取消、分页、重启引用和完整书源链路不在这 28 项的结论内。
