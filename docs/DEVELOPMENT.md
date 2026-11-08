# 开发与验证

## 环境

- macOS；支持 Swift 6 的 Xcode，当前开发环境为 Xcode 26.1。
- App 最低 iOS 26.0（`glassEffect` 一类 Liquid Glass API 属于 iOS 26 SDK，不设回落分支）；核心包也可在 macOS 14+ 测试。
- Swift Package Manager 依赖由 `Package.resolved` 锁定，初次解析需要网络。
- 运行脚本需 Python 3 和 `rg`（ripgrep）。

在独立仓库根目录打开 `Legado.xcodeproj`，选择 `Legado` Scheme。真机运行需要自行设置签名团队；请勿将证书或描述文件提交到仓库。

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

工作流定义来自触发分支，`ref` 决定 checkout 的源码；调整 CI 后应使用包含新定义的分支发起新运行。重新运行旧 run 不会采用后来修改的工作流定义。

编译、打包和 IPA 上传是必需步骤。dSYM 与构建日志用于排查问题，各设置三分钟超时并允许失败；摘要中的 `outcome` 保留实际结果。若 dSYM 上传失败，IPA 仍可能已经可下载，但该次构建的符号文件不保证可用。若 IPA 上传失败，整个 job 仍失败。

打包使用实际 `Info.plist` 的版本信息，不自动提升版本号，也不会发布 Release 或更新应用源。同一触发分支的新 IPA 运行会取消该分支上尚未完成的旧运行。

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
