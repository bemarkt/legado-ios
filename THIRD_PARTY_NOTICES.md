# 第三方许可

小浣熊阅读（项目仓库：<https://github.com/Aminark/legado-ios>）由 Aminark 维护。本项目的新增与修改部分以 GNU GPL v3 提供；第三方材料保留其原版权与适用许可。根目录 [LICENSE](LICENSE) 是完整 GPL v3 文本。

## 阅读 Legado

- 项目：<https://github.com/LegadoTeam/legado>。
- 许可：GNU General Public License v3，完整文本见 [Legado-LICENSE.txt](App/Resources/Legado-LICENSE.txt)。
- 材料：部分业务模块、默认 TXT 目录规则 [txtTocRule.json](App/Resources/txtTocRule.json) 和 HTTP TTS 配置 [httpTTS.json](App/Resources/httpTTS.json)。两份配置对应 `app/src/main/assets/defaultData/` 下的同名文件，原作者署名保留在配置中。
- 版权归 Legado 原作者及其贡献者。Aminark 于 2026-10-13 起修改应用品牌、界面与公开文档；后续修改日期和内容见 [CHANGELOG](CHANGELOG.md) 与 Git 历史。

## SwiftSoup

- 项目：<https://github.com/scinfu/SwiftSoup>。
- 用途：HTML 与 CSS 解析。
- 许可：MIT，完整版权及许可见 [SwiftSoup-LICENSE.txt](App/Resources/SwiftSoup-LICENSE.txt)。

## Kanna

- 项目：<https://github.com/tid-kijyun/Kanna>。
- 用途：XPath 解析。
- 许可：MIT，完整版权及许可见 [Kanna-LICENSE.txt](App/Resources/Kanna-LICENSE.txt)。

## ZIPFoundation

- 项目：<https://github.com/weichsel/ZIPFoundation>，固定版本 `0.9.20`；iOS 工程使用 [Vendor/LegadoZIPFoundation](Vendor/LegadoZIPFoundation/README.md) 中的原版源码，避免与 Readium 的异步 ZIP 分支产生 SwiftPM 包标识冲突。
- 用途：按需读取 EPUB ZIP 容器与校验资源 CRC。
- 许可：MIT，完整版权及许可见 [ZIPFoundation-LICENSE.txt](App/Resources/ZIPFoundation-LICENSE.txt)。

## Readium EPUB 阅读组件

- 项目：<https://github.com/readium/swift-toolkit>，固定版本 `3.8.0`，兼容 iOS 15。
- 用途：渲染 EPUB 的 XHTML/CSS、SVG、内嵌插图、表格、目录与阅读位置。
- 许可：BSD-3-Clause。随 App 使用的 Zip、Readium Fuzi、Readium ZIPFoundation、CryptoSwift、DifferenceKit 的完整版权及许可一并收录在 [Readium-LICENSE.txt](App/Resources/Readium-LICENSE.txt)，可在 App「关于 → 开源许可」中查看。
- 随阅读组件分发的 OpenDyslexic、iA Writer Duospace、AccessibleDfA 字体保留原始资源，版权及许可说明一并收录在上述许可文件中。
- iOS 依赖版本和来源由 Xcode 工程内的 `Package.resolved` 锁定；未使用 Readium LCP 或云端解密服务。

## 测试数据与演示内容

测试中的规则样本仅用于兼容验证，不打包为 App 默认书源。具体说明见 [测试样本说明](Tests/LegadoCoreTests/Fixtures/README.md)。演示模式使用虚构书籍元数据和项目内演示文本；发布截图不使用个人书架、登录信息或付费章节。

第三方材料继续遵循其各自许可。GPL 覆盖软件的使用和分发，不提供第三方网站、书籍、封面或服务的内容授权。

## 自有书源协议开发工具

`tools/source-protocol` 的 Node 原型使用 Acorn 8.19.0（MIT）解析 ECMAScript AST，使用 Ajv 8.20.0（MIT）校验 JSON Schema。精确版本、下载来源和 integrity 记录在该目录的 `package-lock.json`，各依赖的版权/许可随 npm 包保留。传递依赖 fast-deep-equal、json-schema-traverse、require-from-string 使用 MIT 许可；fast-uri 使用 BSD-3-Clause 许可，完整声明随各 npm 包保留。

这些依赖当前只用于开发工具，没有加入 App 或复制到 App 资源；将来嵌入 App 时必须同步收录实际分发版本的完整版权与许可。协议 fixture 与合成旧库 seed 由本项目构造，不含真实站点正文或个人数据。
