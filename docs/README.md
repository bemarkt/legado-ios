# 文档索引

## 使用与协作

| 文档 | 内容 |
| --- | --- |
| [项目说明](../README.md) | 安装、主要功能和反馈入口 |
| [更新记录](../CHANGELOG.md) | 未发布改动与正式版本记录 |
| [贡献指南](../CONTRIBUTING.md) | 问题报告、代码贡献和验证要求 |
| [第三方声明](../THIRD_PARTY_NOTICES.md) | 第三方材料的版权与许可 |

## 架构与协议设计

P2/P3 已有实验实现与自动化证据，稳定接口和完整设备验收仍待完成。当前工作顺序与门槛以实施流程为准，设计依据、合同与历史报告分工如下。

| 文档 | 内容 |
| --- | --- |
| [架构与书源协议提案](ARCHITECTURE_SOURCE_PROTOCOL_PROPOSAL.md) | 现有架构分析、参考项目、运行环境与协议边界 |
| [自有书源协议 v1 草案](SOURCE_PROTOCOL_V1_DRAFT.md) | 可读单文件、元数据、操作、结果、上下文与生命周期 |
| [实施流程与验收计划](SOURCE_PROTOCOL_IMPLEMENTATION_PLAN.md) | P0–P6 工作包、阶段依赖、验收门槛、测试、迁移与发布流程 |
| [单文件书源示例](examples/example.source.js) | 使用虚构站点的协议说明示例 |
| [P0 首轮实施报告](reports/SOURCE_PROTOCOL_P0_REPORT.md) | 已交付合同/工具/样本、测试结果、环境缺口和 P1 接续 |
| [P1 WebKit 原型报告](reports/SOURCE_PROTOCOL_P1_REPORT.md) | 运行时、原生网络、CI/IPA 与真机反馈的实际证据 |
| [P2 原生阅读集成报告](reports/SOURCE_PROTOCOL_P2_REPORT.md) | 阅读、账号、封面、诊断、模拟器与对应 IPA 证据 |
| [P3 调试与更新恢复报告](reports/SOURCE_PROTOCOL_P3_REPORT.md) | 构建源 WebKit、源码定位、真实进程恢复及剩余设备工作 |
| [决策登记](reports/SOURCE_PROTOCOL_DECISIONS.md) | D01–D10 的选择、证据与重新评估条件 |
| [真机验证步骤与记录](SOURCE_RUNTIME_DEVICE_VALIDATION.md) | G1 资源/恢复、P2/P3 交互和真实 iPad 的补证剧本 |
| [可执行候选合同](../protocols/source-v1/README.md) | Schema、类型、profile、宿主语义与共享语料 |
| [领域边界](../protocols/source-v1/DOMAIN_BOUNDARIES.md) | 原生宿主、身份、存储、调度、账号与凭据的职责 |
| [作者指南](SOURCE_AUTHOR_GUIDE.md) | 单文件编写、可选构建、导入、调试与分享 |
| [协议工具](../tools/source-protocol/README.md) | 校验、生成、构建、源码定位与受控 fixture 命令 |
| [Legado 兼容基准与证据](../protocols/legado-compatibility/README.md) | 支持范围、固定样本、iOS 验收与按需 Android 参考对照 |

## 开发与维护

| 文档 | 内容 |
| --- | --- |
| [开发与验证](DEVELOPMENT.md) | 环境、测试命令、CI、IPA 构建、应用源维护和 EPUB 回归 |
| [仿真翻页维护说明](READER_PAGINATION.md) | 当前页序与进度模型、排版约束、诊断方法和验证记录 |
| [JavaScript 宿主 API](javascript-host-api.md) | 书源脚本可使用的宿主接口 |
| [QuickJS 迁移订正](quickjs-migration-corrections.md) | 迁移期间的实现订正和接口补充记录 |
| [核心测试夹具](../Tests/LegadoCoreTests/Fixtures/README.md) | 测试数据的组织与使用 |

实现行为以对应提交的代码与实际测试为证据，预期行为由候选合同定义；两者冲突需修复并记录差异。当前优先级与门槛集中维护在实施流程，决定在决策登记，阶段报告按提交保留结果和限制。历史迁移报告、调试交接和设备日志不作为新的任务队列。新增说明应在此建立入口；替换或归档历史资料时保留其来源和适用范围。

构建产物、签名文件和原始设备日志不作为开发文档提交。诊断示例使用脱敏数据。
