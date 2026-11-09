# P4 独立兼容层实施与验证报告

日期：2026-11-09。阶段仍在实施；当前任务与剩余范围统一见 [实施流程第 13 节](../SOURCE_PROTOCOL_IMPLEMENTATION_PLAN.md#13-当前执行清单与历史起点)。

## 已验证的实现

提交 `01d58e64c09f53d8537a876c4ae8916d5e6cd2af` 新增独立 `LegadoSourceProvider`，实现原生 `SourceProvider` 的 search/book/chapters/content。DSL、BookSource、QuickJS 和 java.* 均留在适配层；返回持久引用、分页结果和纯文本正文。

- 每个操作创建独立宿主环境和控制器。顶层、URL/header/body JS 与嵌套网络使用同一环境。
- 引用按安装与账号绑定；身份基于请求内容摘要，不依赖标题、章节序号或搜索 VM。仅保留有大小限制的规则变量与恢复上下文，不自动复制 source/login/Cookie 宿主状态。作者主动放入规则变量的数据仍按源提供的数据处理。
- 搜索与目录游标绑定完整执行身份和查询/书籍；重复页、跨作用域游标及无限分页失败，不能返回成功的残缺正文。
- 同步 JS 运行在专用 dispatch 工作线程；异步请求由受控桥接等待。取消、截止时间或父作用域失效会取消异步任务并拒绝迟到结果。每次操作最多 64 次脚本请求；实际 HTTP 跳转/重试仍需接入共享网络预算。
- 修复 java.ajax/java.connect 两条网络异常返回文本/伪响应的分支。显式新宿主抛出错误；旧入口历史行为暂保留。

`6931932` 进一步新增 `LegadoScopedSourceState`：普通 source.get/put 进入按安装/账号隔离的 SourceArchive；事务内检查安装摘要、配置摘要和当前账号，操作 gate 限制取消后的提交。loginInfo/loginHeader 进入现有凭据库，支持重开和撤销；访客不能保存登录字段。新的可选凭据字段保持旧记录可解码。该提交已通过常规 CI；凭据持久化测试使用 MemorySourceCredentials 验证现有 vault 路径，不能当作新代码的真机 Keychain 验收。

## 自动化证据

| 提交 / GitHub Actions | 结果 | 范围 |
| --- | --- | --- |
| 043caad / 42556353161 | 失败已保留 | 468 核心测试中出现 2 个预期失败：ajax/connect 吞掉网络异常；App 编译成功不能替代此失败 |
| 01d58e6 / 42557488421 | 成功 | 475 核心测试、57 套件，12.537 秒；74 页面模型测试，0.992 秒；iOS 模拟器 App 编译成功 |
| 同上：LegadoSourceProviderTests | 7 项通过，0.254 秒 | 合成 JSON 响应完整链路、引用序列化/新 provider、两页目录、分页正文、下载/重开/离线/进度、跨账号引用/游标拒绝、标题变化身份、失败/循环正文、网络取消、撤销及请求预算 |
| 同上：JavaScriptHostEnvironmentTests | 6 项通过，0.166 秒 | 两环境状态、Cookie、身份、日志隔离；嵌套请求环境、异常、活动循环取消、迟到响应与过期操作 |
| 同上：固定规则回归 | 29/29，0 差异 | CSS/XPath/JSONPath/正则/JS 的经审查预期；不宣称完整 Android 等价 |
| 同上：进程恢复 | before/during/after 通过 | 实际 SourceArchive 子进程中断，旧/新活动快照、完整性与重试恢复 |
| 6931932 / 42558198743 | 成功 | 480 核心测试、58 套件，12.798 秒；74 页面模型测试，1.067 秒；29 项固定规则、进程恢复与 iOS App 编译通过 |
| 同上：LegadoScopedStateTests | 5 项通过，0.025 秒 | 普通状态重开、登录字段不写普通库、凭据重开/隔离/撤销、配置/源码/账号切换拒绝旧写入、取消及精确凭据 gate |

29 项语料 SHA-256 为 `3dd523f9e0771ffb158a0c18054a20b3bdf9a0a4fa6e7c3c72ba275980bfad59`。预期文件 SHA-256 为 `1b0c325eab78951e46f793044576b18f1390864cc50c43da1ea7738561762e84`。本地证据位于 `build/github-actions/01d58e6/core/` 与 `build/github-actions/6931932/core/`；可由上述 workflow artifact 重新取得。另有 13 项 Python 证据完整性测试通过。

## 当前支持矩阵

| 能力 | 当前状态 | 证据与限制 |
| --- | --- | --- |
| 离线基础规则 | 限定样本通过 | 29 项固定预期；Android 数值字符串差异保留 |
| 独立四步阅读与原生归档 | 核心合成链路通过 | 7 项 provider 测试；尚未接入 App 的 JSON 安装入口 |
| 引用/游标作用域、取消、预算 | 核心样本通过 | 账号/查询/标题/循环/撤销/异步取消测试；真实 HTTP 集成待补 |
| source.get/put 与登录字段 | 核心持久化样本通过 | 6931932 的 5 项 scoped state 测试；SQLite 快照校验、账号隔离、凭据库和 operation gate；生产环境工厂接线待完成 |
| 原始 JSON 安装/更新与未知字段 | 待产品接入 | 需要格式标识、静态导入、编辑与 provider 选择；不能把 JSON 当 ESM |
| Cookie、HTTP 重定向、真实网络取消 | 待宿主装配 | 共享原生 HTTP 已有自身测试；本 provider 尚未接入，不能移用结果宣称通过 |
| HTML 书源完整链路与作者脚本 | 部分 | 底层规则测试已存在，独立 provider 当前完整链路样本为 JSON；需扩展实际 HTTP HTML 样本 |
| 倒序多页目录、preUpdateJs、付费/补充正文、内容 WebView/回调 | 当前明确拒绝 | 返回 unsupported，不回传原页面假装完成；后续扩展按样本验证，不删减阶段任务 |
| 安卓任意 Java 类、独有平台 UI | 不承诺 | 旧源适配按限定宿主集合，不是 Android/Java 运行环境 |

## 剩余实施与交付边界

继续完成 Cookie/凭据/共享 HTTP 的生产装配与实际请求测试，安装格式、JSON 导入/编辑和 App provider 选择；再做实际 iOS 阅读集成。按计划继续 P5 副本迁移与恢复、产品功能核对和对应 IPA 交付。此次核心代码尚未作为新 IPA 交付，不能把用户对既有版本“真机安装测试功能预览都正常使用”的反馈归到这些新增代码。

P4/G4、迁移门槛和发布门槛未关闭；Android 对照没有新增运行，既有失败和原始报告继续保留。
