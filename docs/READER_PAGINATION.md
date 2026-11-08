# 仿真翻页维护说明

本文描述当前文字阅读器的原生仿真翻页实现。EPUB 原书排版由 Readium 负责，参见 [开发指南的 EPUB 回归](DEVELOPMENT.md#epub-回归)。旧调试交接记录中的临时方案与待办，应先与本文和当前代码核对。

## 实现入口

| 文件 | 职责 |
| --- | --- |
| [PageDeck.swift](../Sources/LegadoCore/Reader/PageDeck.swift) | 章节与页的连续索引、逻辑页与双面纸页的映射 |
| [ReaderCurlPageBuilder.swift](../App/Features/Reader/ReaderCurlPageBuilder.swift) | 稳定视口、正文块、原文页首位置和纸页生成 |
| [ReaderPaginator.swift](../App/Features/Reader/ReaderPaginator.swift) | 行、段落、标题与页面的排版 |
| [ReaderNativeCurlPager.swift](../App/Features/Reader/ReaderNativeCurlPager.swift) | 原生卷页、相邻章节页序、完成与取消回调 |
| [ReaderTextView.swift](../App/Features/Reader/ReaderTextView.swift) | 连接排版、卷页控制器与进度回调 |
| [ReaderViewModel.swift](../App/Features/Reader/ReaderViewModel.swift) | 阅读位置解析、章节状态和 `ReaderPageProgress` 定义 |
| [ReaderView.swift](../App/Features/Reader/ReaderView.swift) | 接收落地快照并协调保存进度 |
| [ReaderChapterTitleDesigner.swift](../App/Features/Reader/ReaderChapterTitleDesigner.swift) | 章节标题设计稿、预览和标题高度 |

## 必须保持的约束

### 分页与绘制使用同一视口

`ReaderCurlViewport` 从窗口、安全区和最大阅读宽度计算阅读列，再叠加正文边距。分页容器与纸页绘制边距必须来自这一份几何。

进入或退出时，隐藏 `UITextView` 的高度可能短暂变化，例如从 811 pt 变为 860 pt；不能用这类临时高度重算仿真分页。窗口大小、阅读列或样式实际变化时仍应重新排版。

### 字符位置使用原文 UTF-16 坐标

页首位置指向原文章内的 UTF-16 偏移。跳过空行、处理 CRLF 和智能拆分长段落时，不能把处理后的字符串长度当成原文偏移。`ReaderCurlPageBuilder.blocks` 保留原始位置，分页结果中的 `startCharacters` 与实际显示内容对应。

`ReaderPositionResolver.pageIndex` 按字符位置寻找所在页。位置 `0` 是有效的章首；保存的页号和总页数保留供诊断，不用旧页号或页数比例覆盖字符位置。重新排版后页号可以变化，但应恢复到同一字符锚点所在页。

### 进度由落地快照统一提交

`ReaderPageProgress` 同时包含 `chapterIndex`、`pageIndex`、`pageCount` 和 `position`。仿真模式初次挂载与翻页落地都发布完整快照，外层据此保存，避免章节、页号和字符位置分别来自不同回调。

仿真模式中的隐藏 `UITextView` 不负责写阅读进度，包括卷页层尚未挂载或已经拆除时。UIKit 布局、滚动和销毁回调不能覆盖读者实际看到的页面。

### 完成与取消都要结束转场

翻页期间暂缓替换页表，避免手势途中切换布局。只有已完成的翻页提交新落点；取消手势保留原进度。两条路径都必须释放转场状态并处理延迟更新，避免取消一次后不能继续刷新。

相邻章节进入同一页序。跨章落地时，字符位置和页数取自目标章节的页表，不能拿旧章正文偏移与新章页号拼出存档。单页章节也走原生卷页路径。

### 排版变更保留阅读锚点

修改字体、边距、智能分段或标题设计稿时，要同步更新排版输入与样式标识。正文页首、标题高度、页眉页脚和绘制边距应一致；不要只更新纸页外观而继续使用旧页表。

## 诊断方法

在「我的 → 其他设置」中开启运行日志；需要观察隐藏正文几何时，可开启「正文几何 debug」。隐藏正文视图的坐标不等于卷页层的落点，分析时同时查看以下事件：

| 日志事件 | 核对内容 |
| --- | --- |
| `入场页 依据=位置` | 恢复的字符偏移、当前页号和存档页号 |
| `卷页落地` / `卷页落地(跨章)` | 手势实际落到哪一页、哪一章 |
| `进度写入` | 保存的章节、字符位置、页号和总页数是否匹配 |
| `页序更新` / `页序接管` / `页序换页` | 是否因相邻章加载或版面变化更新页表 |
| `正文几何` | 隐藏正文的视口与偏移，仅作辅助排查 |

先确认 IPA 文件名中的源码 SHA 和测试时间，再选取该版本的日志片段；同一导出文件可能同时含有旧包与新包记录。未改变排版且未翻页时，退出与重进应保存、恢复同一位置；改变排版后，先核对字符锚点而非要求页号不变。

页首 `0` 本身不是错误，第一页可以合法使用它。只有结合目标章节、目标页和原文页首表，才能判断跨章落点是否错误。导出日志前删除账号、Cookie、Token 与真实正文等信息。

## 自动回归

| 测试 | 覆盖范围 |
| --- | --- |
| [PageDeckTests](../Tests/LegadoCoreTests/PageDeckTests.swift) | 拼接顺序、章节边界、落点重映射与双面纸页映射 |
| [ReaderCurlPositionRegressionTests](../Tests/LegadoAppModelsTests/ReaderRegressionTests.swift) | 章首和末页位置恢复、重排后按字符锚点恢复 |
| [ReaderCurlProgressTests](../Tests/LegadoReaderTests/ReaderScrollGeometryTests.swift) | 临时高度、隐藏视图回调、翻页保存、取消与跨章、单页章节、分页与绘制几何、原文 UTF-16 位置 |

在 macOS 运行核心与页面模型回归：

```sh
swift test --disable-sandbox --filter PageDeckTests --no-parallel
swift test --disable-sandbox --filter ReaderCurlPositionRegressionTests --no-parallel
```

UIKit 回归使用已安装且可用的模拟器，将设备 UUID 替换为实际值：

```sh
xcodebuild -project Legado.xcodeproj -scheme LegadoReaderTests \
  -destination 'platform=iOS Simulator,id=模拟器UUID' \
  -only-testing:LegadoReaderTests/ReaderCurlProgressTests \
  CODE_SIGNING_ALLOWED=NO test
```

普通 CI 的模拟器 `build` 不执行上述 UIKit 测试；Windows 上的静态检查也不能替代它们。

## 真机检查

修改上述链路后，至少记录以下操作的实际结果：

1. 章首、中间页和末页退出后重进；翻页刚完成就退出。
2. 向前、向后跨章，停在相邻章末页后退出重进。
3. 章内和跨章拖动到中途取消，然后继续翻页并退出重进。
4. 单页章节、CRLF、连续空行、长段落智能拆分与含非 BMP 字符的正文。
5. 修改字体、字号、边距或标题设计稿；旋转或改变阅读列宽后按原字符位置续读。

这是一份后续回归清单，不表示其中所有场景都已实机执行。

## 验证记录

2026 年 11 月 8 日的修复验证使用源码 `650bbfc`（IPA 版本 `0.1.14`，构建号 `20`）：

- GitHub Actions run `42456597641`：335 个 LegadoCore 测试与 74 个 AppModels 测试通过，模拟器 App 构建通过。两项新增字符位置回归包含在 AppModels 中。
- IPA run `42456608078`：设备构建、打包和 IPA 上传成功；随后 dSYM 上传确认失败，导致旧工作流整体显示失败。该次 IPA 已下载并校验 ZIP 完整性。
- 用户反馈 IPA 真机测试通过。新格式设备日志中 33 次重新进入的页号与存档页号一致，未出现无页号的进度写入；这验证了反馈中的退出重进场景，不能外推为完整真机清单全部通过。
- 新增的八项 `ReaderCurlProgressTests` UIKit 回归尚未执行，不计入上述 409 项 SwiftPM 测试。
- 后续 `500eb60` 仅调整可选诊断附件上传的超时与容错。其配置经过静态检查，重跑被取消，尚无该调整的完整运行验证。

整理提交时，先验证合并后的完整文件树与 `500eb60` 一致，再单独提交本文等文档改动；此次整理未重新触发 CI。
