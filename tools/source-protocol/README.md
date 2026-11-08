# 书源协议原型工具

此目录包含独立开发工具及 App 原型的共享解析/合同代码。现有 Legado 书源路径保持独立。需要 Node 22+；本轮在 Windows / Node 26.12.1 验证。锁定依赖见 package-lock.json。

```sh
cd tools/source-protocol
npm ci --ignore-scripts
npm run check
npm run validate -- ../../docs/examples/example.source.js
npm run validate -- ../../protocols/source-v1/fixtures/html.source.js ../../protocols/source-v1/fixtures/json.source.js
npm run fixtures
```

- `check`：确认生成类型、App 内嵌解析器及许可证没有漂移，并运行 Node 测试。
- `bundle`：使用锁定的 esbuild 和 Ajv standalone 生成可读的浏览器包；不在 App 运行时生成 validator 函数。
- `generate`：Schema 修改后重新生成类型。
- `validate`：读取受限大小 UTF-8 文件，在有 deadline/内存限制的 worker 内解析 AST。输出元数据、入口、摘要和未知能力；不 import/eval 输入。
- `fixtures`：启动本机确定性站点，Ctrl+C 结束。没有任意文件读取或代理转发入口。

validator 的静态通过只代表声明符合当前候选；不能证明整个源安全、网站正常或已适配 App。当前 Node 校验器不提供执行任意用户书源的 CLI；测试只导入仓库内固定的、自行编写的 JSON fixture。HTML 的真实 DOM 执行另由 `Source Runtime WebKit` workflow 验证。

`lib/contract-core.mjs` 提供共同的数据语义；`lib/contracts.mjs` 是 Node 装配，`browser/inspector.mjs` 是 App 入口。`build-browser.mjs` 将 AST parser 和预编译 Schema validators 打包为 `App/Resources/SourceRuntime/SourceInspector.js`。Node worker 的硬终止/内存限制与 WKWebView 的原生 deadline 不是同一种保证，D01 资源项仍需设备验证。

生成合成旧库与基线报告，在仓库根目录执行：

```sh
python scripts/source-protocol-baseline.py
```

可用 `--fixture-output` 指定一个不存在的 SQLite 文件路径，工具拒绝覆盖；`--report` 输出本次环境和源文件摘要。它执行仓库内的静态 SQL 块并构造合成数据，不运行 Swift，也不读取用户数据库。

合同语义见 [protocols/source-v1](../../protocols/source-v1/README.md)，进度见 [P1 报告](../../docs/reports/SOURCE_PROTOCOL_P1_REPORT.md)。
