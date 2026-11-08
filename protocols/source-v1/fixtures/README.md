# 确定性协议样本

全部内容由本项目构造，不包含个人书架、真实登录凭据或第三方正文。默认服务只监听 `127.0.0.1:18764`；设备不可把自身 loopback 当开发电脑地址。真机 runner 需要在 P1 明确设备可达的测试传输/地址映射和对应 origin，不能直接使用这些固定地址声称真机可用。

| 组 | 位置/入口 | 当前验证范围 |
| --- | --- | --- |
| A HTML | html.source.js、html-*.html | 静态导入与 HTTP 响应可用；DOM 提取/净化待设备验证 |
| B JSON | json.source.js、json-*.json | Node 中完整四项操作、两页目录、下一章、全新模块持久化 ref 读取 |
| C 状态 | /state/login、/state/account、/state/expired | 合成 Cookie/账号响应；没有宣称原生 cookie jar 已实现 |
| D 变化 | /changes/catalog?scenario=base/reorder/delete/insert/replace/revision | 稳定 ID、重复标题、版本变化的预期响应；目录协调器待 P2 |
| E 故障 | /failure/empty、rate-limited、server-error、parse、slow、disconnect、oversized、repeat-cursor | 固定故障输入；Node 取消只验证 fixture 服务和 fetch，不代表 WebKit 停算 |
| F 运行时 | runtime-faults/*.source.js | 仅设备故障注入输入；本轮不执行死循环等文件 |
| G 分发 | static-cases.json | 25 个合法/非法静态样本；安装更新故障在 P3 补齐 |
| 规范化 | text-normalization.json、html-normalization.expected.json | text 可执行；HTML 为待实现预期 |
| 旧库 | migration/legacy-v7-seed.json | 由已提交 SQL 生成合成 SQLite；不是用户数据库，也未通过 Swift 解码 |

JSON 源预期请求顺序：search → book → chapters(page=1) → chapters(page=2) → content(ch-1) → 在新模块中 content(ch-2)。预期书籍 ID 为 fixture-book，章节 ID 为 ch-1/ch-2，目录 revision=r1；第二页 nextCursor=null。正文由项目自造句子组成。

HTML 源对应相同流程与稳定 ID，HTML 路径在 `/html/` 下。正文内包含必须被丢弃的脚本标记，用于将来验证 DOM 不执行与宿主净化；不能直接把 HTML 作为活动网页加载。

持久化恢复测试目前通过 JSON 序列化 ref 后导入一个新模块实例模拟。它没有启动/终止真实 App、没有验证数据库或离线缓存；这些仍在 P2。
