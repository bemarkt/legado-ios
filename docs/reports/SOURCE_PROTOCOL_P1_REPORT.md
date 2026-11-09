# P1 WebKit 垂直原型报告

日期：2026-11-08（Asia/Hong_Kong）。状态：原型及通用边界补测已通过原生编译、18 项 WebKit 模拟器测试及 IPA 构建。用户反馈真机离线示例及两份本地 JS 源测试正常；G1 的完整真机故障与资源验收尚未通过。

> 本报告记录 P1 验证时的历史范围。后续实验性 P2 已实现安装作用域的 storage、配置、领域核心及阅读预览；当前状态和证据见 [P2 报告](SOURCE_PROTOCOL_P2_REPORT.md)。下方“storage 不支持”等限制仅适用于 P1 基线及不绑定安装的协议实验室，不能据此判断后续代码。

## 本轮范围

- P1-01：CLI 与 App 共享 Acorn AST 和合同语义。App 内嵌离线生成的 Schema validator，在独立可信 WKWebView 中只解析字符串，绝不执行输入源码。25 项共同语料包含顶层异常及无限循环；这些只用于静态解析。
- P1-02：每次操作创建新的无持久化执行页，以 Blob ES Module 装载已检查的不可变源码。脚本和网站页面分离；暂不做页面池。
- P1-03：原生绑定页面、主 frame、session/operation ID；限制消息大小、方法、请求次数和重复 ID。成功/失败/取消/超时只结算一次。输出在另一可信页面校验。
- P1-04：原生 URLSession HTTP，逐跳 origin 检查、流式响应体上限、禁 Cookie/凭据共享、单次消费、POST 字节体和取消。App 默认仅 HTTPS；模拟器测试显式开启 loopback HTTP。
- P1-05：HTML/JSON 四项操作和两页目录的真实 WebKit 测试已通过独立 GitHub workflow。
- P1-06：加入无穷 Promise、取消、未等待 HTTP、全局状态清理和后续运行恢复测试。同步死循环不在普通测试套件执行；进程级故障恢复仍待真机专项。
- P1-07：尚未测量真机冷/热运行、总内存、能耗和并发档位。

## 使用入口

App → 设置 → 其他设置 → 书源协议实验室。先载入离线示例或打开/粘贴 `.source.js`，点击「检查元数据与语法」，再选择操作并执行。离线示例可直接运行四项操作；输出为可复制 JSON，不写入书架或现有书源库。执行网络源前界面会展示其声明的网站。

新代码在 `App/SourceRuntime`，只参与 iOS App target；不把 WebKit 引入跨平台 LegadoCore。Xcode 的 Swift 文件、内嵌运行时资源和测试 fixture 已显式登记。后续 P2 可根据验证结果提取模块边界。

## 本轮刻意保留的限制

- 这是候选协议原型，不是对外稳定 v1。`ctx.storage` 明确返回 UNSUPPORTED；日志暂不持久化；config 只使用静态 metadata 默认值。账号、凭据服务、安装/更新、阅读闭环尚未接入。
- 响应通过 base64 桥接；请求体限 2 MiB，响应体限 8 MiB。桥接前后的复制和对象扩展仍需资源测量；这不是 WebContent 硬内存上限。
- 目前放行 UTF-8/UTF-16LE/UTF-16BE；GB18030 保留为未验证候选，返回 UNSUPPORTED。json 始终使用严格 UTF-8。
- 冷 WebContent 启动单独设 15 秒宿主等待上限；页面准备完成后，解析/模块初始化按候选 2 秒，操作按候选 15 秒。原生超时收回结果与请求，不代表同步 JS 已停止计算。
- 独立 page 和非持久化 data store 不保证独立 OS 进程。未证明同步死循环可硬终止、进程崩溃后资源回收或恶意源完全隔离。
- CSP 和导航代理限制全局网络及子资源；测试矩阵仅覆盖已列入口，不能据此宣称所有 Web API 均已完成安全审计。页面 API、origin、前后台行为仍需最低系统真机记录。
- HTTPS 的内网/DNS 策略、账号网络会话、封面请求统一策略留到原生服务阶段，不能把当前无账号原型当作完整网络服务。

## 验证命令与证据

Windows：`npm --prefix tools/source-protocol run check`。当前 77 个 Node 测试通过，其中 25 项比对浏览器包与 Node 结果；浏览器包测试禁止字符串动态代码生成。内嵌解析器约 442 KB、非压缩、可复现生成，完整许可证随 App 资源提供。

GitHub：`Source Runtime WebKit` 在 macos-26 的 iOS 26 模拟器执行 `xcodebuild test -only-testing:LegadoReaderTests/SourceRuntimeTests`，同时启动只绑定 loopback 的受控 Node fixture 服务。不是仅 build。每次上传日志与 xcresult。

实现提交：`b9b7b5c5f6ee6b15e56504795efc84e4e167d164`。

| 验证 | 证据 | 结果 |
| --- | --- | --- |
| Swift 核心与 App model、模拟器编译 | [JavaScript Engine CI 42476920071](https://github.com/bemarkt/legado-ios/actions/runs/42476920071) | 335 + 74 测试通过，App 编译通过 |
| 实际 WebKit 执行 | [Source Runtime WebKit 42476920073](https://github.com/bemarkt/legado-ios/actions/runs/42476920073) | 12 项测试通过；iPhone Air 模拟器，iOS 26.5，Xcode 26.6；约 213 秒 |
| Release arm64 IPA | [Build Unsigned IPA 42476935559](https://github.com/bemarkt/legado-ios/actions/runs/42476935559) | 构建成功；最低 iOS 26.0，版本 0.1.14 build 20 |
| 真机离线及联网样本 | 2026-11-08 用户在当前开发会话先后反馈离线示例和两份本地 JS 源测试正常 | 用户报告通过；网站专用脚本及资料仅保存在本机忽略目录；未提供机型、精确系统小版本、性能数据或操作明细 |

IPA 文件名 `Legado-0.1.14-20-b9b7b5c-unsigned.ipa`，17,575,055 bytes；SHA-256 `f97f568061ed7169a0b6bb60be148f2b3c633786bacb31c7f868e78d9793e9c6`。已检查 ZIP CRC、Info.plist、arm64 Mach-O、未签名状态，以及全部内嵌 SourceRuntime 资源与提交文件一致。日志/包校验记录保存在本地忽略目录 `build/github-actions/b9b7b5c`。

上述真机反馈覆盖用户报告的离线示例和两份本地联网样本体验，不推导所有书源、最低 iOS 26.0、iPad、后台运行、内存恢复或同步死循环已通过。

## 通用边界补测（2026-11-08）

用户已报告两份本地 JS 源在真机运行正常。网站专用源、转换资料与测试均仅保存在本机忽略目录，不纳入项目或 CI；以下测试全部使用合成脚本和 loopback fixture。

- P1-03/P1-06：ready 只能初始化一次且必须使用固定控制 ID；取消只能指向本操作已见请求。新增实际 WebKit 消息测试覆盖初始化前请求、重复 ID、重复 ready、会话/操作串用、未知字段、畸形数据和结束后的调用；通过 fixture 请求轨迹验证被拒绝消息没有触发网络。
- P1-04：失败请求同样消耗单次操作 64 次预算；下一操作重新计数。URLSession 超时映射 TIMEOUT，断连映射 NETWORK，取消映射 CANCELLED。
- P1-05：四种配置默认值保持类型，空字符串、false、0 不丢失，config 冻结且操作之间无修改泄漏；storage 继续明确返回 UNSUPPORTED。
- 错误边界：修正 403 被误判为 AUTH_REQUIRED（应为 HTTP）；保留 429 的合法 retryAfterMs；未知异常码和异常 getter 产生有界备用诊断，原生二次检查错误码、消息长度和重试间隔。

实现提交：`e8294dd8cb59f6c4ce1959672e0f7c5ac6bba7eb`。Windows 本地 77 项合同/静态测试通过；六项新增原生测试与既有十二项全部在 GitHub 实际 WebKit 通过。

| 本轮验证 | 证据 | 结果 |
| --- | --- | --- |
| 候选合同与内嵌解析器 | [Source Protocol Candidate 42483763689](https://github.com/bemarkt/legado-ios/actions/runs/42483763689) | 77 项通过，内嵌 bundle 与生成结果一致 |
| Swift 核心、App model、模拟器编译 | [JavaScript Engine CI 42483763721](https://github.com/bemarkt/legado-ios/actions/runs/42483763721) | 335 + 74 测试通过，App 编译通过 |
| 真实 WebKit 执行 | [Source Runtime WebKit 42483763699](https://github.com/bemarkt/legado-ios/actions/runs/42483763699) | 18 项测试，零失败，145.880 秒；iPhone Air 模拟器、iOS 26.5、Xcode 26.6 |
| Release arm64 IPA | [Build Unsigned IPA 42483764569](https://github.com/bemarkt/legado-ios/actions/runs/42483764569) | 成功；最低 iOS 26.0，0.1.14 build 20 |

本轮 IPA 为 `Legado-0.1.14-20-e8294dd-unsigned.ipa`，17,582,565 bytes，SHA-256 `871cd0d616087c6ad75155bc2fca2d4622ebbf29a051ce59cc181ae0e95c3360`。已验证 ZIP CRC、plist、arm64 Mach-O、未签名状态和五项内嵌 SourceRuntime 资源与实现提交逐字节相同；本地证据保存在忽略目录 `build/github-actions/e8294dd`。

源码、原生编译、WebKit 执行和 IPA 使用同一个实现提交。Windows 冒烟验证只作 JS 逻辑证据，不冒充 WebKit 结果。错误详情 details、持久化配置与账号服务仍不在本轮范围。测试日志仍含系统进程终止权限诊断；此次未执行同步死循环，不将套件通过视为硬终止或资源回收通过。

## 下一轮

本轮边界补测已通过；下一步按 [真机验证步骤](../SOURCE_RUNTIME_DEVICE_VALIDATION.md) 在 iOS 26 真机专项执行同步死循环、进程异常、前后台切换、取消后总资源与恢复测量，形成 D01–D04、D10 的决定。原计划将 G1 作为进入 P2 的前置；2026-11-09 的实施流程已明确实验实现与正式验收分开。P2/P3 实验实现已推进，独立工作可继续；G1 的缺失证据仍须补齐，不能据此切换默认路径或承诺运行时稳定性。当前任务统一见 [实施流程](../SOURCE_PROTOCOL_IMPLEMENTATION_PLAN.md)。
