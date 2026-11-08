# 文档索引

## 使用与协作

| 文档 | 内容 |
| --- | --- |
| [项目说明](../README.md) | 安装、主要功能和反馈入口 |
| [更新记录](../CHANGELOG.md) | 未发布改动与正式版本记录 |
| [贡献指南](../CONTRIBUTING.md) | 问题报告、代码贡献和验证要求 |
| [第三方声明](../THIRD_PARTY_NOTICES.md) | 第三方材料的版权与许可 |

## 架构与协议设计

以下文档描述后续设计和实施计划，不表示相应能力已经在 App 中实现。

| 文档 | 内容 |
| --- | --- |
| [架构与书源协议提案](ARCHITECTURE_SOURCE_PROTOCOL_PROPOSAL.md) | 现有架构分析、参考项目、运行环境与协议边界 |
| [自有书源协议 v1 草案](SOURCE_PROTOCOL_V1_DRAFT.md) | 可读单文件、元数据、操作、结果、上下文与生命周期 |
| [实施流程与验收计划](SOURCE_PROTOCOL_IMPLEMENTATION_PLAN.md) | P0–P6 工作包、阶段依赖、验收门槛、测试、迁移与发布流程 |
| [单文件书源示例](examples/example.source.js) | 使用虚构站点的协议说明示例 |
| [P0 首轮实施报告](reports/SOURCE_PROTOCOL_P0_REPORT.md) | 已交付合同/工具/样本、测试结果、环境缺口和 P1 接续 |
| [P1 WebKit 原型报告](reports/SOURCE_PROTOCOL_P1_REPORT.md) | 运行时、原生网络、CI/IPA 与真机反馈的实际证据 |
| [真机验证步骤与记录](SOURCE_RUNTIME_DEVICE_VALIDATION.md) | Windows/iPhone 可做的操作验证、资源测量缺口和进入 P2 的条件 |
| [可执行候选合同](../protocols/source-v1/README.md) | Schema、类型、profile、宿主语义与共享语料 |

## 开发与维护

| 文档 | 内容 |
| --- | --- |
| [开发与验证](DEVELOPMENT.md) | 环境、测试命令、CI、IPA 构建、应用源维护和 EPUB 回归 |
| [仿真翻页维护说明](READER_PAGINATION.md) | 当前页序与进度模型、排版约束、诊断方法和验证记录 |
| [JavaScript 宿主 API](javascript-host-api.md) | 书源脚本可使用的宿主接口 |
| [QuickJS 迁移订正](quickjs-migration-corrections.md) | 迁移期间的实现订正和接口补充记录 |
| [核心测试夹具](../Tests/LegadoCoreTests/Fixtures/README.md) | 测试数据的组织与使用 |

当前行为以代码和测试为准。历史迁移报告、调试交接与设备日志用于追溯问题，不替代当前实现说明，也不表示其中的旧待办仍未解决。新增说明应在此建立入口；替换或归档历史资料时保留其来源和适用范围。

构建产物、签名文件和原始设备日志不作为开发文档提交。诊断示例使用脱敏数据。
