# P1 WebKit 垂直原型报告

日期：2026-11-08（Asia/Hong_Kong）。状态：首轮原型已实现；原生编译和模拟器测试结果待 GitHub CI 回填，G1 未通过。

## 本轮范围

- P1-01：CLI 与 App 共享 Acorn AST 和合同语义。App 内嵌离线生成的 Schema validator，在独立可信 WKWebView 中只解析字符串，绝不执行输入源码。25 项共同语料包含顶层异常及无限循环；这些只用于静态解析。
- P1-02：每次操作创建新的无持久化执行页，以 Blob ES Module 装载已检查的不可变源码。脚本和网站页面分离；暂不做页面池。
- P1-03：原生绑定页面、主 frame、session/operation ID；限制消息大小、方法、请求次数和重复 ID。成功/失败/取消/超时只结算一次。输出在另一可信页面校验。
- P1-04：原生 URLSession HTTP，逐跳 origin 检查、流式响应体上限、禁 Cookie/凭据共享、单次消费、POST 字节体和取消。App 默认仅 HTTPS；模拟器测试显式开启 loopback HTTP。
- P1-05：HTML/JSON 四项操作和两页目录的真实 WebKit 测试已加入独立 GitHub workflow，待运行证据。
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

原生运行结果、提交及 IPA：待 CI 完成后补充。上轮 `3045faf` 的 335 个核心测试、74 个 App model 测试和 IPA 构建基线已通过；该结果不覆盖本轮运行时。

## 下一轮

先依据本轮 CI 反馈修正实现，再扩充桥接身份/请求预算/错误编码与配置样本。随后在 iOS 26 真机专项执行同步死循环、进程异常、前后台切换、取消后总资源与恢复测量，形成 D01–D04、D10 的决定。G1 达标后才进入 P2 的领域接口、账号范围持久化、缓存和阅读闭环。
