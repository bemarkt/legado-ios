# 自有书源协议：P0 首轮实施报告

日期：2026-11-08。代码基线：`e65f4dff85f4e30be0c90510734ae298edb6d320`。

**结论：G0 的合同与可重复样本准备已通过，可以开展有边界的 P1 原型。P0 的原生基线、真实数据样本和设备环境在本报告初次生成时仍缺证据；P1-01 只交付了 Node 静态导入原型，G1 尚未通过。** 本轮没有修改 App 运行路径，没有宣称新协议已可在 App 导入。

## 1. 本轮交付

| 产物 | 内容 |
| --- | --- |
| [功能与数据清单](SOURCE_PROTOCOL_P0_INVENTORY.md) | 20 项功能去向、21 张业务表、数据库外状态、现有测试映射 |
| [候选合同](../../protocols/source-v1/README.md) | 模块、数据、身份/分页、错误、HTTP、storage、配置、生命周期和规范化的明确语义 |
| [Schema](../../protocols/source-v1/schema.json) / [profile](../../protocols/source-v1/profile.json) | 26 个数据定义、资源保护边界、候选语法和实验预算 |
| [领域接口草图](../../protocols/source-v1/DOMAIN_BOUNDARIES.md) | 不含 Legado DSL/WebKit 类型的身份、上下文和服务职责 |
| [原型工具](../../tools/source-protocol/README.md) | bounded worker 静态 AST 检查、类型生成、语义校验、fixture 服务、自动测试 |
| [共享样本](../../protocols/source-v1/fixtures/README.md) | HTML/JSON 源、静态正反例、状态/变化/故障、规范化和旧库合成 seed |
| [机器可读基线](source-protocol-p0-baseline.json) | Git 提交、环境、依赖和关键文件 SHA-256、合成 SQL 检查结果 |
| [决策登记](SOURCE_PROTOCOL_DECISIONS.md) | D01–D10 候选、证据、剩余工作与关闭阶段 |
| [CI](../../.github/workflows/source-protocol-ci.yml) | 后续 push/PR 的协议与合成 SQL 检查；本轮未触发远程运行 |

依赖仅位于 tools/source-protocol，未加入 App 或 Swift Package。Acorn 8.19.0、Ajv 8.20.0 与传递依赖精确锁定；安装未执行包 lifecycle scripts。此选择是原型实现，App parser 的移植/资源方案待 D01 验证。

## 2. 工作包状态

| 工作包 | 状态 | 说明 |
| --- | --- | --- |
| P0-01 功能/数据盘点 | 通过（静态盘点） | 已覆盖现有功能和迁移边界；运行基线另记 |
| P0-02 可复现基线 | 进行中 | 提交、锁文件、Node/SQLite 和合成 seed 已记录；Swift 测试、真实脱敏数据库尚缺 |
| P0-03 候选合同 | 通过（原型候选） | 可实现的字段/方法/错误/限制已记录；设备依赖能力仍需 P1/P2 验证，不是对外定版 |
| P0-04 领域接口 | 通过（草图） | 已列职责/值类型/依赖；尚未生成或编译 Swift 类型 |
| P0-05 fixture 站点 | 通过（本机） | A/B 响应、C/D/E 故障入口和 F/G 输入已准备；HTML 的 DOM 执行与 App 状态未验收 |
| P0-06 环境 | 已明确 CI 路径；设备证据待补 | Windows 11 本机运行 Node/Python；Swift/Xcode 测试与编译使用 GitHub Actions macos-26；真机/Android 对照另验收 |
| P0-07 决策与报告 | 通过 | 决策登记和本报告可用于后续接续 |
| G0 | 通过（进入原型） | A/B 的请求与预期、恢复要求、未决项和功能去向可明确复现/说明；允许开 P1，不意味着 P0 所有环境依赖已解决 |
| P1-01 静态导入器 | 进行中 | Node worker 原型与共享语料完成；App 侧解析/资源/一致性仍缺 |
| P1-02～P1-07 | 未开始 | iOS 运行页、桥、原生服务、故障恢复和设备测量没有实施记录 |
| G1 | 缺少证据 | 不能用 Node 或生成数据库的结果替代 |

## 3. 实际验证

运行环境：Windows、Node v26.12.1、npm 11.11.0、Python 3.14.10；SQLite 版本与详细摘要见机器报告。工具链版本来自本机实际执行。

### 3.1 协议测试

`npm run check`：**51 项通过，0 失败**；同时检查生成类型与 Schema 一致。

覆盖：

- 25 个静态正反例，包括普通模块、本地函数别名、重复键、getter/spread/计算键、外部模块、动态 import、顶层 await、缺失/非法入口和未知能力。
- 顶层 `throw` 与死循环源码只按 AST 处理，检查成功不运行模块。
- UTF-8、文件大小、AST 深度和 parser deadline；超时后 worker 终止，后续正常检查可继续。
- Schema 与语义：空页下一游标、页内重复 ID、重复标题不同 ID、URL、JSON 非有限/循环/访问器/特殊对象、设置默认值与资源上限。
- JSON 源四项操作、两页目录、正文/下一章；序列化 ref 后用全新模块读取。请求轨迹固定且可对照。
- HTML fixture 响应可达；状态/账号/目录修订/429/503/POST 和取消响应可重复。
- 纯文本规范化四个共享样本。
- 四个设备故障文件只做静态检查，不执行同步死循环、永久 Promise 或游离任务。

另用 CLI 检查原说明示例、HTML fixture 和 JSON fixture：均为 `static-valid`，输出 metadata、操作集合和源码 SHA-256。

### 3.2 合成旧库

`python scripts/source-protocol-baseline.py --report docs/reports/source-protocol-p0-baseline.json`：v1–v7 静态 SQL 构造、integrity_check 和 foreign_key_check 全部通过；v7 共 21 张业务表。

合成 v7 包含 1 个源、1 本书、2 个同标题不同身份章节、1 条书签/笔记、1 条阅读记录、3 条源状态和 1 条 Cookie。验证未知源字段、完整 URL 和第二章进度仍保留。没有读取或改写任何个人数据库。

这不是 Swift 迁移测试：脚本没有执行 Swift 控制流/解码，也没有执行未来新架构迁移。表结构完整不等于旧用户数据已经迁移成功。

### 3.3 当前提交的 CI 基线

本报告初次生成时未取得基线 SHA 对应的 Swift/Xcode 成功证据。后续核对显式使用 `--repo bemarkt/legado-ios`，确认 fork 是实际 CI/构建目标。用户已明确 Windows 11 本地开发、原生编译通过 GitHub Actions；本轮提交后执行协议 CI、JavaScript Engine CI 和 IPA 构建，最终结论以对应提交的 run 记录为准。

## 4. 明确未验证的范围

- Swift 编译、LegadoCore/AppModels 现有测试、Xcode 模拟器构建/UI 测试。
- iOS 26 本地 ESM 加载、origin/secure context、CSP、DOM/Web API 与 native bridge。
- 原生网络的 Cookie/凭据、编码、重定向、总预算和取消；当前 JSON 流程使用 Node fetch。
- Swift source storage/CAS、调度、目录一致性协调器、缓存/数据库、App 重启与离线恢复。
- HTML 提取和净化、规范化 block/mark 与阅读锚点；当前 HTML 预期文件未执行。
- WKWebView 同步无限循环隔离、其他源影响、旧 WebContent 回收、前后台和总内存/能耗。
- Android 基准版本选择、设备执行与差分；真实用户库、大库/损坏库及原生文件授权。
- 正式源安装、用户编辑、上游更新、权限扩大、订阅与状态回滚；F/G 不是整个 P3 的替代品。

## 5. 下一步接续

1. 在 `bemarkt/legado-ios` 的 GitHub Actions macos-26 runner 记录工具链，运行当前仓库的核心/模型测试和模拟器构建，补齐 P0-02 的原生基线。若失败先归档失败日志，区分已有问题与新原型影响。
2. P1-01：评估将同一 Acorn 解析核心/等价规则置入 App 的方式，用 static-cases.json 对照；验证 App 端输入预算、超时与错误位置。不要直接把 Node worker 当 iOS 实现。
3. P1-02/P1-03：建立开发入口与受控本地 ESM 执行页，固定 source snapshot，桥消息携带 operation/session；验证 origin/CSP 和不需要的 Web 入口。
4. P1-04/P1-05：接入一次原生 HTTP，使用 A/B fixtures 完成四项操作。真机需要明确可达测试服务地址和授权 origin；本机 127.0.0.1 不能直接当设备的开发电脑地址。
5. P1-06/P1-07：逐个执行 runtime-faults，记录业务终态、原生请求、JS 计算与资源恢复；正常源恢复后再测并发和总资源，形成 G1 决策。

原生编译与测试使用已经确定的 GitHub CI，无需等待本机安装 Xcode。GitHub 编译、模拟器检查与 IPA 打包仍不能替代 G1 所要求的最低 iOS 26 真机行为和资源证据。
