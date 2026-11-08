# 自有书源作者指南

日期：2026-11-08。候选协议，尚未冻结为对外稳定 v1。最简单的源是一个可读的 `.source.js`；开发机工具可选，用户安装时不需要服务端、Node 或远程依赖。

## 直接写一个文件

从 [单文件示例](examples/example.source.js) 复制到自己的编辑器。metadata 必须直接写成 `export const metadata = {...}` 的静态 JSON 字面量，不能调用函数或读取另一个变量。`apiVersion`、`id`、名称、版本、允许网站都写在这里，不能另外维护一份会漂移的 manifest。

必需的 `book`、`chapters`、`content` 和可选 `search` 都是 async 函数。输入和返回值使用 [生成类型](../protocols/source-v1/types.generated.d.ts)，宿主能力见 [context.d.ts](../protocols/source-v1/context.d.ts)。在编辑器中可使用 JSDoc `@param {import(".../context").SourceContext} ctx` 获得提示，App 安装的仍是普通 JavaScript。

- 用稳定 `ref.id` 识别书籍和章节；重复标题不能当 ID。需要下次读取的参数放在有限 JSON `ref.state` 中，不能依赖上次搜索留下的全局变量。
- 搜索和目录返回 `nextCursor:null` 表示结束；非空游标由宿主在同一源码/配置/查询范围使用。允许空页继续，不允许重复游标形成循环。
- 通过 `ctx.http.fetch` 请求 metadata 声明的网站；显式处理非成功状态，每个响应体只消费一次。不要绕过桥使用全局 fetch，也不要在多层同时重试。
- content 返回 text 或 HTML 片段。HTML 会转换为有限原生文档，脚本、事件、媒体和任意网页样式不会成为阅读器 UI。
- settings 提供文本/数值/枚举/布尔选项；敏感凭据不使用普通文本选项。`ctx.storage` 的 null 值与不存在分开，需并发保护时使用 revision 条件写入。
- 不使用 import、动态 import、远程 eval 或常驻后台逻辑。每次操作均可在全新执行页运行；未等待工作会在终态失去宿主权限。

在工具目录执行 `npm run validate -- 路径/你的.source.js`。这只做静态检查，不执行源，不证明网站可用。随后在 App「书源协议实验室」按 search → book → chapters（含分页）→ content 操作，检查返回值与错误；正式安装作用域的状态、配置和阅读在「原生书源阅读」验证。

## 可选：TypeScript 与多文件开发

[离线多文件示例](examples/source-project/index.ts) 将类型和正文样本分开。构建只发生在作者的电脑，最终用户仍只收到一个文件。

```sh
cd tools/source-protocol
npm ci --ignore-scripts
npm run build-source -- ../../docs/examples/source-project/index.ts ../../build/built-offline.source.js
npm run validate -- ../../build/built-offline.source.js
```

若输出已存在，构建默认拒绝覆盖。确认要替换时，在工具目录直接调用 Node（此命令也已在 Windows PowerShell 验证）：

```sh
node build-source.mjs ../../docs/examples/source-project/index.ts ../../build/built-offline.source.js --replace
```

入口和任何依赖文件都不能用作输出。构建使用锁定的 esbuild，保留可读格式、依赖内的许可证注释，不生成 source map，也不加载作者自定义 JavaScript 构建插件。它转换 TypeScript 语法，不代替 `tsc --noEmit` 类型检查。

构建器将 metadata 保留为文件顶部可直接编辑的唯一静态字面量；内部代码引用同一个对象。所有实现和静态依赖内联在一个局部作用域中，以固定的 async 操作导出。动态导入、远程模块、外置资源、未知导出和同步操作会被拒绝；输出最后通过与 App 一致的静态合同检查。构建器不执行源初始化或用户函数；固定项目样本的执行测试不等于运行任意用户源码的调试器。

依赖管理只在作者侧：固定包版本，审阅许可并在成品中补齐依赖要求的完整授权文字。保留 esbuild 识别的法律注释不保证第三方许可已全部满足。构建器不自动联网下载依赖，也不在 App 安装时解析 npm。

## 分享、修改和更新

只分享最终 `.source.js` 的文件或 HTTPS 原始文本地址。App 导入后展示元数据与网站范围；相同作者 ID 不会静默接管别的安装。当前 URL 下载只跟随同 origin 重定向，分享地址应直接指向文本，避开跨站短链与 HTML 页面。

用户可在书源设置查看/修改源码并导出。更新先下载候选，再检查和审阅，保存时以当前摘要防止旧编辑器覆盖新内容；最近 8 个源码版本可审阅恢复。新增网站范围需要明确保存，同 ID 更新也不意味着信任自动继承。publisher ID 改变应另存安装。

源码回滚不等于 state 回滚。作者必须确认旧状态兼容，否则使用独立安装，不能写一个隐式安装钩子去修改用户状态。读取失败也不能通过修改 metadata 伪装为成功。导出应保持源码，不将令牌、配置、书架或下载正文拼进文件。

## 验证层次

1. Node 静态合同/生成/固定样本测试：作者可在 Windows 完成。
2. 实际 WebKit 操作、storage、配置和阅读：GitHub 的手动 Source Runtime WebKit 与 App 实验入口。
3. 真机资源、同步死循环恢复、键盘、VoiceOver 和 iPad：见 [设备验证步骤](SOURCE_RUNTIME_DEVICE_VALIDATION.md)。

目前没有源码单步调试器、完整运行时行号映射、账号登录扩展和发布级资源预算。错误带字段/行列时先定位对应声明，修复后重新静态检查，再在固定样本或 App 中重跑相关操作。当前范围和待办见 [P2 报告](reports/SOURCE_PROTOCOL_P2_REPORT.md)。
