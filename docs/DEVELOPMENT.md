# 开发与验证

## 环境

- 日常开发主机为 Windows 11。本地运行 Git、Node、Python 和静态检查；Swift 测试、Xcode 模拟器/设备编译与 IPA 打包通过 GitHub Actions 的 macOS runner 执行。
- 当前工作流使用 `macos-26`；每次运行记录实际 Xcode/Swift/SDK 版本，不依赖开发主机安装 Xcode。
- App 最低 iOS 26.0（`glassEffect` 一类 Liquid Glass API 属于 iOS 26 SDK，不设回落分支）；核心包也可在 macOS 14+ 测试。
- Swift Package Manager 依赖由 `Package.resolved` 锁定，初次解析需要网络。
- 运行脚本需 Python 3 和 `rg`（ripgrep）。

可选的 macOS 调试环境可在仓库根目录打开 `Legado.xcodeproj`，选择 `Legado` Scheme。日常编译使用下方 GitHub Actions；真机运行需要自行配置签名，证书或描述文件不提交到仓库。

## 代码结构

| 路径 | 用途 |
| --- | --- |
| `App/` | SwiftUI 页面、UIKit 阅读器、应用入口与资源 |
| `Sources/LegadoCore/` | 书源、规则引擎、网络、持久化、搜索、阅读及 RSS 等核心逻辑 |
| `Tests/LegadoCoreTests/` | 核心行为与书源兼容测试 |
| `Tests/LegadoAppModelsTests/` | 页面模型回归 |
| `Tests/LegadoReaderTests/` | iOS 阅读器与网页桥接测试 |
| `Tests/LegadoReaderUITests/` | 模拟器 UI 与阅读链路测试 |
| `App/Resources/` | 默认 TXT 目录规则、HTTP TTS 配置和第三方许可证 |
| `scripts/` | 自检与源码导出 |

## 验证命令

```sh
swift test --disable-sandbox --filter LegadoCoreTests --no-parallel
swift test --disable-sandbox --filter LegadoAppModelsTests --no-parallel
xcodebuild -project Legado.xcodeproj -scheme Legado \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
```

上述命令按测试 target 串行执行，与当前 CI 一致；仅完成模拟器 `build` 不代表已执行 UIKit 或 UI 测试。

完整本地自检：

```sh
sh scripts/self-check.sh
```

首次运行可先在 Xcode 解析包；自检的 App 构建阶段固定使用已解析依赖。可用 `LEGADO_DERIVED_DATA_PATH` 和 `LEGADO_SOURCE_PACKAGES_PATH` 指定已有缓存。

阅读器测试在 Xcode 选择 `LegadoReaderTests` / `LegadoReaderUITests` Scheme 和具体模拟器运行。联网书源测试需要显式配置对应环境变量，默认核心回归主要采用自造响应，不能将其通过解读为所有线上书源均可用。

书源和本地 TXT / EPUB 文件选择回归需要先在已启动的测试模拟器中准备文件共享应用（将下方 UUID 换成实际值）：

```sh
LEGADO_TEST_DEVICE="模拟器 UUID"
sh scripts/prepare-source-import-fixture.sh "$LEGADO_TEST_DEVICE"
xcodebuild -project Legado.xcodeproj -scheme LegadoReaderUITests \
  -destination "platform=iOS Simulator,id=$LEGADO_TEST_DEVICE" \
  -only-testing:LegadoReaderUITests/RuleEditorUITests/testJSONFilePickerOffersOpenAndImportsSelectedFiles \
  -only-testing:LegadoReaderUITests/RuleEditorUITests/testBookshelfFilePickerImportsTXTAndEPUBAndDisablesJSON \
  -only-testing:LegadoReaderUITests/RuleEditorUITests/testFileManagementFilePickerImportsTXTAndEPUBAndDisablesJSON \
  -collect-test-diagnostics never CODE_SIGNING_ALLOWED=NO test
```

独立测试应用提供 JSON 书源和 `.txt`、`.TXT`、`.epub` 小说样本，不会被打包进正式 App。此回归检查取消后重新打开、书源 JSON 多选、本地 TXT / EPUB 可选且 JSON 不可选、导入确认、最终保存、EPUB 正文、插图与目录跳转。

测试夹具仅在内容变化时原位写入文件，保持文件标识稳定。iOS 26 模拟器的 Files 提供器可能在样本被原子替换后返回「文件不存在」，导致已勾选文件未回传；遇到旧夹具残留时，卸载模拟器中的「书源导入测试」后重新运行准备脚本。

RSS 的导入、源内搜索、分页、正文、收藏以及重启恢复可通过本地自造响应回归，避免依赖第三方网站。先在一个终端运行 `python3 scripts/fixtures/rss-flow-server.py`，再在 Xcode 选择 `LegadoRSSFlowUITests` Scheme 和模拟器运行；也可用 `xcodebuild -project Legado.xcodeproj -scheme LegadoRSSFlowUITests -destination 'platform=iOS Simulator,id=模拟器UUID' CODE_SIGNING_ALLOWED=NO test`。该服务仅监听本机 `127.0.0.1:18763`，测试结束后按 Ctrl-C 停止。普通 UI Scheme 默认跳过此用例。

RSS 界面回归还验证正文的手动刷新确实重新请求网络。核心与页面模型回归覆盖查询隔离、刷新失败后的分页重试、重定向链接、文章变量、并发开关、书签与阅读记录保存顺序，以及自动更新过程中删除规则订阅；这些用例均使用临时数据库和自造响应，不访问个人书架。

## 仿真翻页维护

[仿真翻页维护说明](READER_PAGINATION.md) 记录页序、稳定视口、UTF-16 字符位置与落地进度的约束，并列出自动测试、真机检查和已完成验证的范围。修改分页、章节切换、进度保存或标题排版前，先核对这些约束。

重点测试入口为 `PageDeckTests`、`ReaderCurlPositionRegressionTests` 和 iOS 的 `ReaderCurlProgressTests`。后者需要使用 `LegadoReaderTests` Scheme 执行测试，普通 App 构建不会运行它。

## GitHub Actions 与 IPA

| 工作流 | 触发方式 | 验证或产物 |
| --- | --- | --- |
| [JavaScript Engine CI](../.github/workflows/javascript-engine-ci.yml) | 匹配路径的 push、非草稿 PR 或手动触发 | 两个独立 job：SwiftPM 核心与页面模型测试，以及 Xcode 模拟器 App 构建 |
| [Build Unsigned IPA](../.github/workflows/build-ipa.yml) | 仅手动 `workflow_dispatch` | iOS 设备构建、未签名 IPA、可选 dSYM 与构建日志 |

自动工作流的路径过滤和 PR 事件以 YAML 为准。当前过滤包含 `App/`、核心代码和核心测试等路径；只修改 `Tests/LegadoAppModelsTests/` 或 `Tests/LegadoReaderTests/` 不会单独触发该工作流，必要时手动执行。UIKit 和 UI 测试仍需另外运行。

手动构建时，在 Actions 选择 **Build Unsigned IPA → Run workflow**：

1. 选择包含所需工作流定义的分支。`ref` 输入可指定要编译的分支、tag 或完整 commit SHA，留空则使用触发分支。
2. 选择 `Release` 或 `Debug`，runner 使用 `macos-26`。
3. 完成后下载 `Legado-Unsigned-IPA-<version>-<short_sha>` artifact。IPA 文件名包含版本、构建号和源码短 SHA，安装前自行签名。

使用 GitHub CLI 时始终显式传入目标仓库，例如 `--repo bemarkt/legado-ios`，避免 fork 的默认仓库解析指向 upstream。对已推送的同一提交，运行协议 CI、JavaScript Engine CI 与 IPA 工作流，并记录 run ID/源码 SHA；IPA 的 `ref` 输入使用完整 SHA。

工作流定义来自触发分支，`ref` 决定 checkout 的源码；调整 CI 后应使用包含新定义的分支发起新运行。重新运行旧 run 不会采用后来修改的工作流定义。

编译、打包和 IPA 上传是必需步骤。dSYM 与构建日志用于排查问题，各设置三分钟超时并允许失败；摘要中的 `outcome` 保留实际结果。若 dSYM 上传失败，IPA 仍可能已经可下载，但该次构建的符号文件不保证可用。若 IPA 上传失败，整个 job 仍失败。

打包使用实际 `Info.plist` 的版本信息，不自动提升版本号，也不会发布 Release 或更新应用源。同一触发分支的新 IPA 运行会取消该分支上尚未完成的旧运行。

下载实验性原生书源 IPA 后，可在 Windows/macOS/Linux 的仓库根目录使用 Python 核验：

```sh
python scripts/verify-source-ipa.py path/to/Legado-unsigned.ipa 完整提交SHA --output path/to/ipa-verification.json
```

脚本检查 ZIP、重复成员、arm64 主程序、iPhoneOS/最低 iOS 26.0、包标识、未签名状态，以及 `SourceRuntime` 文件集合和每个文件与预期 Git 提交的字节一致性。JSON 包含版本、大小和 SHA-256，不解压或执行 IPA。资源一致性不能单独证明 Swift 编译来源，仍需核对工作流实际 checkout 日志；使用 `inputs.ref` 时，Actions 列出的触发分支 SHA 可能与实际 checkout 不同。脚本可重复用于每个集成节点，不必触发新的构建。

## 兼容性验证

最低部署版本为 iOS 26.0。项目已放弃 iOS 15–25 的兼容分支：`glassEffect` 这类 API 直接在编译期解析，部署目标低于 26 会报「找不到符号」，`#available` 挡不住。因此仓库里既有的 `#available(iOS 16.0/*)`、`#available(iOS 17.0/*)` 守卫现在是恒真分支，Swift 会给出 unnecessary-availability 警告——这属于已知待清理项，清理时连同其后的旧系统回落分支一起删，作为独立提交而非混在界面改动里。`App/Compatibility.swift` 仍保留导航、分享、照片选择与弹窗的兼容实现，供 `-uiLegacyCompatibility` 调试分支使用，对应回归位于 `Tests/LegadoReaderUITests/`。这些测试不能替代 iOS 26 真机或模拟器实测。

搜索调度与缓存回归见 `Tests/LegadoCoreTests/SearchPerformanceTests.swift`，包括复杂书源限流和普通书源的及时执行；这些测试验证行为，不提供真实网络速度排名。

## 演示与公开截图

模拟器启动参数 `-uiDemo` 使用演示书架；`-uiDemoReader` 打开演示阅读页，`-uiDemoTab settings` 打开「我的」，`-uiDemoAbout` 打开关于页。部分演示入口仍保留 `settings` 参数名以兼容测试脚本。

提交截图前确认没有真实账号、个人书架或第三方付费正文。公开截图放在 `docs/images/`；`artifacts/`、构建缓存和原始测试日志仅供本地验证，已加入忽略清单。

## 导出源码

在多项目父仓库中开发时，可以运行以下命令导出本项目当前源码，排除父仓库历史、构建产物及签名文件：

```sh
python3 scripts/export-open-source.py /tmp/legado-ios-open-source
```

目标目录必须尚不存在。导出后检查内容，再用独立仓库管理；`.gitignore` 不会自动清理已经跟踪的文件。

## 维护应用源

`docs/altstore.json` 是 AltStore Classic、SideStore 和 LiveContainer 共用的应用源，固定地址为：

```text
https://raw.githubusercontent.com/Aminark/legado-ios/main/docs/altstore.json
```

源仅列出最新正式版，同时提供 `versions` 和旧客户端使用的顶层版本字段。版本号、构建号、最低 iOS 版本和隐私权限从实际 IPA 的 `Info.plist` 读取，下载地址、发布日期和更新说明来自 GitHub Release。目前由维护者在发布正式版后手动运行生成脚本并提交源文件。

1. 新版发布时，先在 Release 草稿中上传唯一的未签名 `.ipa`，再发布正式版。
2. 下载 GitHub 标记的 latest 正式版元数据及 IPA，运行下方生成与测试命令，检查 `docs/altstore.json` 差异后提交到 `main`。
3. 源文件发布后，客户端刷新源即可获取该版本的下载与更新入口。只提交源码或上传未发布的草稿不会更新应用源。

本地生成（需要 Python 3.9+；获取 Release 元数据时使用已登录的 GitHub CLI）：

```sh
source_update_dir=$(mktemp -d)
gh api repos/Aminark/legado-ios/releases/latest > "$source_update_dir/release.json"
source_release_tag=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tag_name"])' "$source_update_dir/release.json")
gh release download "$source_release_tag" --repo Aminark/legado-ios \
  --pattern '*.ipa' --dir "$source_update_dir"
python3 scripts/update-altstore-source.py \
  --ipa "$source_update_dir/legado-ios-v0.1.14-build20-unsigned.ipa" \
  --release "$source_update_dir/release.json"
python3 -m unittest discover -s scripts/tests -v
```

请将示例 IPA 文件名换成实际下载的附件名。脚本会核对包标识、Release 标签与 IPA 版本、文件大小，以及 Release 提供的 SHA-256（如有），避免源指向与本地检查不一致的包。当前生成器针对本项目无扩展、无额外 entitlement 的未签名 IPA；改用签名包、增加扩展或 entitlement 时，需要同步完善权限提取，生成器会拒绝带签名资源、描述文件或扩展的 IPA。

发布后检查固定地址可匿名访问、图标和截图能正常加载，并下载源中 IPA 再核对大小、摘要和版本。客户端的添加源、安装、更新与签名流程需分别实测；源文件校验通过不代表已完成真机安装验证。

格式说明：[AltStore 源规范](https://faq.altstore.io/developers/make-a-source)、[SideStore 源字段](https://sidestore.io/sidestore-source-types/interfaces/Source.html)、[LiveContainer 源用法](https://livecontainer.github.io/docs/guides/sources)。

## EPUB 回归

`swift test --disable-sandbox --filter EPUB` 覆盖 EPUB 2/3 元数据、中文资源路径、同页锚点、无目录降级、书脊顺序、插图、损坏与加密文件、重命名导出、导入失败回滚和阅读进度恢复。样本均由测试自行生成，不依赖网络或第三方书籍。

核心解析器按需读取 ZIP 资源，不解压到磁盘；单资源上限为 32 MiB。它用于导入、书架元数据和文字朗读。EPUB 原排版阅读由 Readium 3.8.0 的 Streamer / Navigator 处理，保留 XHTML、CSS、SVG 和内嵌插图；不接入 DRM 解密服务。原排版位置和书签使用 EPUB locator 保存，旧的文字进度仍兼容。

`LegadoReaderTests/EPUBReaderIntegrationTests` 在 iOS 中实际渲染自造 EPUB，检查 SVG 封面、相对路径图片、外部 CSS、表格、目录跳转和字号变化后的续读。可通过 `xcodebuild -project Legado.xcodeproj -scheme LegadoReaderTests -destination 'platform=iOS Simulator,id=模拟器UUID' -only-testing:LegadoReaderTests/EPUBReaderIntegrationTests CODE_SIGNING_ALLOWED=NO test` 运行。真实书籍样例仅用于本机验证，不放进仓库。

## 自有书源协议原型（P0/P1）

协议工具位于 [tools/source-protocol](../tools/source-protocol/README.md)，候选合同与共享样本位于 [protocols/source-v1](../protocols/source-v1/README.md)。Node 工具可在 Windows/macOS/Linux 验证，App 中另有「其他设置 → 书源协议实验室」开发入口。现有 Legado 导入和阅读路径独立。

```sh
cd tools/source-protocol
npm ci --ignore-scripts
npm run check
npm run validate -- ../../docs/examples/example.source.js
```

在仓库根目录执行 `python scripts/source-protocol-baseline.py` 可检查合成旧库的静态 SQL 与结构。Node/SQLite 结果不能替代 Swift 构建、WebKit 或真机验收；进度与缺口见 [P0 阶段报告](reports/SOURCE_PROTOCOL_P0_REPORT.md)。

P1 的原生验收由 `.github/workflows/source-runtime-ci.yml` 执行：选择 iOS 26 模拟器，启动 loopback fixture 服务，并实际运行 `LegadoReaderTests/SourceRuntimeTests`。不能把 `xcodebuild build` 当成 WebKit 执行结果。使用当前仓库 `bemarkt/legado-ios` 触发和查看 CI，Windows 本机不尝试 Xcode。内嵌 parser 修改后执行 `npm --prefix tools/source-protocol run bundle`，再运行 `check` 并提交生成文件。详情与未完成项见 [P1 报告](reports/SOURCE_PROTOCOL_P1_REPORT.md)。


### 自有书源迭代的 CI 节奏

`Source Protocol Candidate` 和 `JavaScript Engine CI` 继续用于提交后的合同、Swift 核心与 App 编译回归。`Source Runtime WebKit` 改为仅 `workflow_dispatch`：桥接、生命周期或完整操作链收敛到可验收节点时手动运行。`Build Unsigned IPA` 原本就是手动构建，通常在该节点确认后统一生成。中间实现提交不重复启动慢的 WebKit/IPA 作业。

P2 的领域核心、独立原生源数据库与适配器可以在 G1 设备测量开放期间按实验范围开发；这不关闭 G1，也不替换现有 Legado/TXT/EPUB 数据或默认阅读路径。最终验收仍需对应原生测试、WebKit 执行和设备记录。

### 原生书源阅读预览

入口为「设置 → 其他设置 → 原生书源阅读」。添加 `.source.js` 文件、粘贴源码、下载 HTTPS 原始文本或载入离线示例，静态检查后审核名称/版本/声明网站，再保存。搜索后加入独立书架，在书籍详情加载目录、下载章节和打开阅读。仅离线模式读取已下载内容，缺章明确报错；重新打开 App 可读取书架、目录和文本锚点。

数据库位于 `Application Support/Legado/native-sources.sqlite3`，使用安装 UUID 和账号 scope，未迁移旧 Legado 数据。当前支持 guest 和独立本地账号；网页登录使用临时 WKWebView，明确保存后将选定网站 Cookie 写入 Keychain，原生 HTTP 按精确 origin 注入。封面复用同一网络/账号策略，具有独立有界缩略图缓存；“书源诊断”只导出有限操作摘要。源码或配置改变会使在线缓存失配；显式离线可读以前下载的版本，界面会提示。设置改变后重新打开书籍以使用新配置。

新 Swift 核心文件必须同时登记到 `Legado.xcodeproj/project.pbxproj`。SwiftPM 会发现文件，App target 不会；通过 SwiftPM 不等于通过 App 编译。见 [P2 实施与验收报告](reports/SOURCE_PROTOCOL_P2_REPORT.md)。

书源设置可查看/修改/导出源码、获取原地址候选更新、审阅访问范围并恢复历史源码（最多 8 个）。替换需摘要一致且 publisher ID 相同；本地草稿替换有确认，源码回滚要求确认已有 state 兼容，不能确认时另存新安装。来源下载当前只允许同 origin 重定向。

手动 WebKit 工作流的 `suite=runtime` 执行完整 SourceRuntime 套件，并加入已有 EPUB、书签、滚动几何和翻页进度回归；`suite=reader-layout` 只验证阅读布局并导出截图，适用于完整运行时已经通过且只修改截图/布局之后。后者不能替代桥接、网络、状态或操作变化所需的完整测试。
