import SwiftUI
import UIKit

// MARK: - 页内一栏

/// 页内一栏页眉 / 页脚的显示内容。
///
/// 尺寸口径：整栏 19pt、文字行 18pt、字号 11、文字用前景色 80% 透明度、
/// 分隔线 0.5pt / 12% 透明度。左右内边距与「距屏幕物理边缘的距离」由调用方给。
struct ReaderCurlBarSpec {
    static let height: CGFloat = 19

    var left: String = ""
    var middle: String = ""
    var right: String = ""
    var textColor: UIColor = .label
    /// 与屏幕物理边缘之间的距离：页眉距顶、页脚距底。
    var gap: CGFloat = 0
    var leftInset: CGFloat = 16
    var rightInset: CGFloat = 16
    var showsDivider: Bool = false
    var dividerOnBottom: Bool = true
    var pageIndex: Int = 0
    var pageCount: Int = 0

    /// 把模板里的页码占位符换成这一页的真实值。
    func resolved(_ template: String) -> String {
        guard template.contains("{") else { return template }
        return template
            .replacingOccurrences(of: "{page}", with: "\(pageIndex + 1)")
            .replacingOccurrences(of: "{pages}", with: "\(pageCount)")
    }
}

// MARK: - 页面模型

/// 一页纸上排好版的行。
struct ReaderCurlSheet {
    var lines: [String] = []
    var isParagraphEnd: [Bool] = []
    /// 首页的章节标题：设计稿有位图就用位图，没有就用这段文字。
    var titleText: String = ""
    /// 首页给标题预留的高度（含标题下留白）。0 表示这一页不画标题。
    var titleHeight: CGFloat = 0
    var titleImage: UIImage?

    var textSignature: String {
        lines.joined(separator: "\u{1}")
            + "#" + isParagraphEnd.map { $0 ? "1" : "0" }.joined()
            + "#" + titleText
            + "#\(titleHeight)"
            + "#" + (titleImage == nil ? "t0" : "t1")
    }
}

/// 一页纸的绘制参数。整卷共用一份，换主题 / 换字号时整体替换。
struct ReaderCurlStyle {
    var layout: ReaderPaginationLayout
    var alignment: ReaderLineAlignment
    var underline: Bool
    var underlineColor: UIColor?
    var textColor: UIColor
    var backgroundColor: UIColor
    var backgroundImage: UIImage?
    /// 正文区到「整块屏幕」四边的距离。
    var contentInsets: UIEdgeInsets
    /// 分页时用的可用宽度：绘制宽度只认这一个数。
    var contentWidth: CGFloat
    /// 章节标题字号。
    var titleFontSize: CGFloat = 18
    var header: ReaderCurlBarSpec?
    var footer: ReaderCurlBarSpec?

    var signature: String {
        var parts: [String] = []
        parts.reserveCapacity(18)
        parts.append("\(layout.fontSize)")
        parts.append("\(layout.lineSpacing)")
        parts.append("\(layout.letterSpacing)")
        parts.append("\(layout.paragraphSpacing)")
        parts.append("\(layout.firstLineIndent)")
        parts.append("\(layout.weightLevel)")
        parts.append(layout.fontPostScriptName)
        parts.append(layout.fontBoldPostScriptName)
        parts.append(alignment.rawValue)
        parts.append("\(underline)")
        parts.append(underlineColor?.description ?? "-")
        parts.append(textColor.description)
        parts.append(backgroundColor.description)
        parts.append("\(backgroundImage?.hashValue ?? 0)")
        parts.append("\(contentInsets.top)/\(contentInsets.left)/\(contentInsets.bottom)/\(contentInsets.right)")
        parts.append("\(contentWidth)")
        parts.append("\(titleFontSize)")
        // 整卷指纹只比「静态结构」：页内栏里的时间每秒都在变，把文案一起比进去，
        // 时钟每走一秒就会触发一次整卷替换（清页面缓存 + 重新定位当前页）。
        // 真机日志里那串每秒一条「换章=false 样式=true 内容=false」就是它。
        parts.append(header.map { "\($0.gap)/\($0.showsDivider)/\($0.dividerOnBottom)/\($0.leftInset)/\($0.rightInset)" } ?? "-")
        parts.append(footer.map { "\($0.gap)/\($0.showsDivider)/\($0.dividerOnBottom)/\($0.leftInset)/\($0.rightInset)" } ?? "-")
        return parts.joined(separator: "|")
    }

    /// 只含「会改变分页 / 行内排版」的那几项。
    ///
    /// 照 InkShelf `ReaderPageAppearance.hasSameLayout(as:)` 的分工：布局变了必须重投
    /// 控制器（这一页的画法真的换了），纯外观变化（底色、文字色、背景图、页内栏）
    /// 只需要就地刷新，绝不重投。此前两者合成一个 `signature`，于是任何一次外观更新
    /// 都被当成「页面变了」重投一遍 —— 正好撞在卷页收尾那一拍上。
    var layoutSignature: String {
        var parts: [String] = []
        parts.reserveCapacity(10)
        parts.append("\(layout.fontSize)")
        parts.append("\(layout.lineSpacing)")
        parts.append("\(layout.letterSpacing)")
        parts.append("\(layout.paragraphSpacing)")
        parts.append("\(layout.firstLineIndent)")
        parts.append("\(layout.weightLevel)")
        parts.append(layout.fontPostScriptName)
        parts.append(layout.fontBoldPostScriptName)
        parts.append("\(contentWidth)")
        parts.append("\(titleFontSize)")
        return parts.joined(separator: "|")
    }
}

/// 系统卷页会给卷起的那张纸加一层关不掉的提亮高光，纸背底色必须预压暗一档，
/// 被提亮之后正好落回主题色。
func readerCurlBackColor(_ color: UIColor) -> UIColor {
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0
    guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
        return UIColor(white: 0.92, alpha: 1)
    }
    let factor: CGFloat = 0.90
    return UIColor(red: red * factor, green: green * factor, blue: blue * factor, alpha: alpha)
}

// MARK: - 页序（扁平页表）

/// 一页在「整本书页序」里的坐标：第几章第几页（都从 0 起）。
///
/// 权威定义在 `LegadoCore.PageDeckLocation`（无 UIKit，由 `PageDeckTests` 每次 CI 覆盖）：
/// 页序的拼接顺序、章界相邻、坐标重映射全是纯算术，挂在 UIKit 文件里就只能靠真机试。
/// 这里用别名而不是新增模块导入：`PageDeck.swift` 已按 pbxproj 口径登记进 Legado target
/// （`PBXBuildFile` / `PBXFileReference` / 组 children / Sources phase 四处，路径写
/// `Sources/LegadoCore/Reader/PageDeck.swift`，与整套 JS 文件同一形式），与 App 同模块可见。
/// 改成用 SwiftPM 产品模块的方式导入会直接把 app target 编红
/// （`unable to resolve module dependency: 'LegadoCore'`），那条路不再走。
typealias ReaderDeckLocation = PageDeckLocation

/// 页序里的一页：内容归属 + 画这一页要用的纸。
struct ReaderDeckSlot {
    let location: ReaderDeckLocation
    let chapterTitle: String
    let sheet: ReaderCurlSheet
}

/// 拼接好的扁平页序：上一章各页 + 本章各页 + 下一章各页（哪章没排进来就少哪段）。
///
/// 章界在数据层不存在 —— 翻页层只认 `slots` 的下标，`before` / `after` 就是
/// `index - 1` / `index + 1`。跨章于是退化成一次普通拖拽卷页：跟手、可取消、
/// 可反向，动画曲线与章内完全同源，不再需要任何程序化转场。
///
/// 参照 InkShelf `ReaderPageCatalog`：那边全书一份扁平页序 + `PoolLocation`
/// 反查，章界只在 UI 层表现为「下一页」。这里保留同样的形态，但按需只拼
/// 「上一章 + 本章 + 下一章」，不必为整本书分页。
struct ReaderPageDeck {

    /// 拼进来的一章：章下标 + 标题 + 这一章的页表（未加载时给空数组）。
    struct Chapter {
        let index: Int
        let title: String
        let sheets: [ReaderCurlSheet]
    }

    /// 页序算术的唯一实现：`LegadoCore.PageDeck`（已按 pbxproj 口径登记进 Legado target，
    /// 与 App 同模块，因此不需要 `import LegadoCore` —— 那条路曾把 app target 直接编红）。
    /// 这里只把泛型载荷换成「一页纸」，对外 API 与原来逐点一致，App 侧调用点零改动。
    private let base: PageDeck<ReaderCurlSheet>

    var slots: [ReaderDeckSlot] {
        base.slots.map {
            ReaderDeckSlot(location: $0.location, chapterTitle: $0.chapterTitle, sheet: $0.payload)
        }
    }

    var currentChapterIndex: Int { base.currentChapterIndex }
    /// 章下标 → 该章第一页在 `slots` 里的绝对下标。
    var chapterStarts: [Int: Int] { base.chapterStarts }

    init() { base = PageDeck() }

    init(chapters: [Chapter], currentChapterIndex: Int) {
        // 空页表的章由 `PageDeck` 自己跳过：相邻章还没排进来时，页序自然退化成「只有本章」，
        // 不会多出一段空白帧，也不会让下标映射错位。
        base = PageDeck(
            chapters: chapters.map {
                PageDeck<ReaderCurlSheet>.Chapter(index: $0.index, title: $0.title, pages: $0.sheets)
            },
            currentChapterIndex: currentChapterIndex
        )
    }

    var isEmpty: Bool { slots.isEmpty }
    var count: Int { slots.count }

    func slot(at index: Int) -> ReaderDeckSlot? {
        base.slot(at: index).map {
            ReaderDeckSlot(location: $0.location, chapterTitle: $0.chapterTitle, sheet: $0.payload)
        }
    }

    func index(of location: ReaderDeckLocation) -> Int? { base.index(of: location) }

    /// 本章第一页的绝对下标（本章没排进来时返回 nil）。
    var currentChapterStart: Int? { base.currentChapterStart }

    /// 本章最后一页的绝对下标（含）。
    func currentChapterEnd() -> Int? { base.currentChapterEnd() }

    /// 把某一页坐标落到最近的合法下标：同章里取不超过它的最后一页，没有就取该章首页。
    func nearestIndex(to location: ReaderDeckLocation) -> Int? { base.nearestIndex(to: location) }

    func firstIndex(inChapter chapterIndex: Int) -> Int? { base.firstIndex(inChapter: chapterIndex) }

    /// 某一章有多少页（该章没排进页序时返回 0）。页内栏按「章」编号，不按整卷绝对下标。
    func pageCount(inChapter chapterIndex: Int) -> Int { base.pageCount(inChapter: chapterIndex) }

    func lastIndex(inChapter chapterIndex: Int) -> Int? { base.lastIndex(inChapter: chapterIndex) }
}

// MARK: - 卷页控制器

/// 系统原生仿真翻页（`UIPageViewController` + `.pageCurl`）。
///
/// 折痕位置、掀起角度、纸背提亮与投影全部由 Core Animation 的 curl mesh 生成。
///
/// 三条不可动摇的约定：
/// - **双面，按物理页编号**：`front(i)` 的 tag 是 `2i`、`back(i)` 的 tag 是 `2i + 1`。
///   `after(front(i)) → back(i)`、`after(back(i)) → front(i + 1)`，反向对称；落地在
///   纸背上时按方向翻译成 `i`（往回）或 `i + 1`（往前），一次手势恰好一页。编号只要
///   错一位，观感就是「往后翻跳一页」或「左划整段失效」—— 前两轮都栽在这里。
/// - **纸背由我们自己画**：单面模式（`isDoubleSided = false`）时那一面由 UIKit 生成，
///   纯白、不吃主题色（真机实测「掀起的纸张太白」）。双面模式把这一面交出来，底色用
///   `readerCurlBackColor` 预压暗一档抵掉系统提亮，另印一张落地页的镜像淡影。
/// - 投递永远是这一张纸：带动画一张，不带画也一张；最后一页的 `viewControllerAfter`
///   必须返回 nil，章末那一下才能落到 gesture 的 ended 分支去通知换章；
/// - 换章不拆控制器：只换页面集合与缓存，按翻页方向卷过去。拆掉重建会让整屏
///   闪一下重新加载，落地页号也只能靠上一章遗留的偏移反推。
final class ReaderNativeCurlController: UIPageViewController {

    /// 当前页下标（0 基）。
    private(set) var index: Int
    /// 当前渲染的是哪一次「换章」：同一个 token 内的变化视为同章重排。
    private(set) var chapterToken: Int
    private var chapterTitle: String?
    /// 扁平页序：上一章 + 本章 + 下一章拼成一份页表。
    ///
    /// 翻页层只认这一个下标：`before` / `after` 就是 `index ∓ 1`，章界在数据层
    /// 不存在。相邻章还没排进来时（那一段页表为空），页序自然退化成「只有本章」，
    /// 行为与单章卷完全一致，不会多出空白帧。
    private var deck: ReaderPageDeck
    /// 页序里每一页的纸：只读派生，不再单独维护一份数组，免得两处不一致。
    private var pages: [ReaderCurlSheet] { deck.slots.map(\.sheet) }
    private var style: ReaderCurlStyle

    /// 落地后回调新下标（整卷绝对下标）。
    var onIndexChange: ((Int) -> Void)?
    /// 落地后回调新页的页序坐标（章下标 + 章内页号）。
    ///
    /// 跨章落地靠这一条：外层拿坐标去晋升该章（`promotePrevious` /
    /// `promoteContinuation`），再整卷换页并按坐标重映射，落点恒定、不重排。
    var onDeckCommit: ((ReaderDeckLocation) -> Void)?
    /// 章末继续往前翻。
    var onReachEnd: (() -> Void)?
    /// 章首继续往回翻。
    var onReachStart: (() -> Void)?
    /// 点击：把落点交给宿主按 3×3 点击区分派。
    var onTap: ((CGPoint) -> Void)?
    /// 转场进行中：此时禁止 setViewControllers 刷新页面。
    private(set) var isTurning = false
    /// 这一次手势的落地页：`willTransitionTo` 里算出来，`didFinishAnimating` 只确认成败。
    ///
    /// 照 InkShelf `CurlPageTurnController` 的 `PageTurnTransaction`：落点在手势**开始**时
    /// 由 pending 控制器决定，收尾不再从 `view.tag` 事后反推 —— tag 是可写状态，`adopt`
    /// 与纸背换面都会改写它，落地一拍读到的值完全可能比记账下标多一格（真机日志里
    /// 「从=29 到=27」「从=17 到=15」就是它，观感即「回翻时先闪一下前一页内容」）。
    private var pendingTurnTarget: Int?
    /// 章界换章的一次性闩锁：记已经为哪一次换章 token 触发过。
    ///
    /// 章界同时挂着位移旁听、左右划兜底和程序化翻页到头三条通路，一次抬手
    /// 三处都会到，而每一次回调都会让外层换一章 —— 实测「第 18 章往回一次退到
    /// 第 15 章」「第 15 章往回不是第 16 章」就是同一下手势换掉两三章的结果。
    /// 这里按换章 token 记账：同一章只许触发一次；页面集合换掉（换章落地）之后
    /// token 自然推进，闩锁自动解锁。
    private var boundaryFiredToken: Int?

    /// 页序真的走到头（整本书首 / 尾，或相邻章还没备好）才通知外层续命。
    ///
    /// 章界不再是「换章」：页序把「上一章 + 本章 + 下一章」拼成一份页表，跨章就是
    /// `index + 1`，由系统自己的卷页手势完成 —— 天然跟手、可取消、可反向，时长曲线
    /// 与章内同源。于是这里只剩「页序走到尽头」这一种情况需要外层继续取正文，
    /// 也就再没有「换章意图 / 方向推断」那套事后猜测（那正是落页错、方向反、
    /// 重投闪退的总源头）。
    private func fireBoundary(forward: Bool) {
        guard boundaryFiredToken != chapterToken else {
            ReaderChapterTrace.log("页序到头信号重复，忽略 token=\(chapterToken)")
            return
        }
        // 转场进行中不接受新的请求：这一下属于上一次手势的余波。
        guard !isTurning else { return }
        boundaryFiredToken = chapterToken
        ReaderChapterTrace.log(
            "页序到头 forward=\(forward) page=\(index + 1)/\(deck.count) token=\(chapterToken)"
        )
        if forward { onReachEnd?() } else { onReachStart?() }
    }

    /// 转场中被挡下的一次状态更新，落地后补上。
    ///
    /// 带的是整份页序 + 落点下标：转场中收到的更新一律排队，落地后一次应用。
    /// 在完成回调里重投控制器会把系统的内部记账搅乱 —— 真机日志里「划多了崩溃
    /// 闪退」与那串每拍一条 `卷页规整` 都是这条路径。
    private struct PendingState {
        let deck: ReaderPageDeck
        let chapterToken: Int
        let style: ReaderCurlStyle
        let target: Int
        let animated: Bool
        /// true = 排队的是「只有邻章页表变了」的静默更新，落地后必须走 `adopt`。
        /// 若照旧走 `apply`，等于把刚避免掉的那一次重投又做一遍（只是没有动画）。
        let silent: Bool
    }
    private var pendingState: PendingState?

    private var frontCache: [Int: (key: String, controller: UIViewController)] = [:]
    /// 纸背缓存：按**内容页**编号（一张纸的反面），与正面同键但 content key 不同。
    private var backCache: [Int: (key: String, controller: UIViewController)] = [:]
    private static let cacheLimit = 6

    init(
        pages: [ReaderCurlSheet],
        chapterToken: Int,
        chapterTitle: String?,
        startIndex: Int,
        style: ReaderCurlStyle
    ) {
        let resolved = pages.isEmpty ? [ReaderCurlSheet()] : pages
        // 先按「只有本章」建页序：相邻章还没排进来时页序自然退化成单章卷，
        // 行为与改动前逐点一致。多章拼接在下一步接上（同一份类型，不换结构）。
        self.deck = ReaderPageDeck(
            chapters: [ReaderPageDeck.Chapter(index: 0, title: chapterTitle ?? "", sheets: resolved)],
            currentChapterIndex: 0
        )
        self.chapterToken = chapterToken
        self.chapterTitle = chapterTitle
        self.style = style
        self.index = min(max(startIndex, 0), max(resolved.count - 1, 0))
        super.init(transitionStyle: .pageCurl, navigationOrientation: .horizontal, options: nil)
        dataSource = self
        delegate = self
        // 双面卷页：纸背交给我们自己画。单面模式下那一面由 UIKit 生成，纯白不吃主题色
        // （真机实测「掀起的纸张太白」）。物理页编号见 `front` / `back`，一次手势一页。
        isDoubleSided = true
        view.backgroundColor = style.backgroundColor
        view.isOpaque = true
        view.clipsToBounds = true
        // pageCurl 自带的双击手势会抢翻页；点击翻页由阅读器自己的 3×3 点击区处理。
        for gesture in view.gestureRecognizers ?? [] where gesture is UITapGestureRecognizer {
            gesture.isEnabled = false
        }
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.cancelsTouchesInView = false
        view.addGestureRecognizer(tap)
        // 章末 / 章首那一下 dataSource 已返回 nil，系统卷页手势可能直接不识别，
        // 自己补一层旁听：位移到位才通知外层换章。
        let boundaryPan = UIPanGestureRecognizer(target: self, action: #selector(handleBoundaryPan(_:)))
        boundaryPan.cancelsTouchesInView = false
        boundaryPan.delegate = self
        view.addGestureRecognizer(boundaryPan)
        for direction: UISwipeGestureRecognizer.Direction in [.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(handleBoundarySwipe(_:)))
            swipe.direction = direction
            swipe.cancelsTouchesInView = false
            view.addGestureRecognizer(swipe)
        }
        view.isUserInteractionEnabled = true
        setViewControllers([front(self.index)], direction: .forward, animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - 状态下发

    /// 页序 / 落点坐标 / 绘制参数的统一下发口。
    ///
    /// 页序含「上一章 + 本章 + 下一章」，所以一次同步里会同时发生两类变化，必须分开处置：
    ///
    /// - **规模变化**（相邻章页表刚拼进来）：只接管页序、按落点坐标重算下标、改写屏上
    ///   这张纸的物理 tag，绝不重投控制器 —— 走 `adopt`；
    /// - **可见内容变化**（读者眼前这一页真的变了）：才 `setViewControllers` 重新投递。
    ///
    /// - Parameters:
    ///   - newDeck: 新页序（上一章 + 本章 + 下一章，未加载的章自然不入页序）。
    ///   - focus: 希望落到的页坐标；换章 / 重排后按它重映射，绝不用旧绝对下标。
    ///   - newToken: 章节身份（由正文内容派生）；与当前值不同即视为换了一章。
    ///   - newStyle: 绘制参数。
    ///   - animated: 只有菜单跳章这类「明确要从别处过来」的动作才给 true。
    /// - Returns: 本次落地后的绝对下标；调用方按它换算回章内页号。
    @discardableResult
    func update(
        deck newDeck: ReaderPageDeck,
        focus: ReaderDeckLocation,
        chapterToken newToken: Int,
        style newStyle: ReaderCurlStyle,
        animated: Bool = false
    ) -> Int {
        let styleChanged = newStyle.signature != style.signature
        // 外观变了不必重投，排版变了必须重投：两类变化的处置完全不同，先分开。
        let layoutChanged = newStyle.layoutSignature != style.layoutSignature
        let chapterChanged = newToken != chapterToken
        // 落点只由页坐标决定：换章 / 重排之后页表会变（页数、分页点都可能不同），
        // 绝对下标必须按坐标重映射一次，否则读者会被「上一次的绝对下标」带偏一页。
        let target = newDeck.nearestIndex(to: focus) ?? min(max(index, 0), max(newDeck.count - 1, 0))
        // 两件事必须分开算：
        //
        // - `pageCountChanged`：整卷规模变了（多半是相邻章页表刚拼进来）。它只该丢缓存、
        //   换页序，**不能让控制器重投**；
        // - `visibleContentChanged`：读者眼前这一页（正落在 `target` 上的那一页）内容真的
        //   变了，这才需要重新投递。
        //
        // 以前这里比的是整卷：页序里含着上一章与下一章，邻章一到整卷必然「内容变了」
        // → `setViewControllers` 重投一次。真机日志 (7) 174–205 行同一落点 `(7,5)` 上
        // 页数 `77→75→73→45→77→78` 反复变（`内容=true`）就是它；快速来回划时这一下
        // 重投正好撞上手势，观感就是「跳了一下」。
        let pageCountChanged = newDeck.count != deck.count
        let visibleContentChanged: Bool = {
            guard let incoming = newDeck.slot(at: target) else { return pageCountChanged }
            guard let current = deck.slot(at: index) else { return true }
            return incoming.sheet.textSignature != current.sheet.textSignature
                || incoming.location.chapterIndex != current.location.chapterIndex
        }()

        if !chapterChanged, !styleChanged, !visibleContentChanged, !pageCountChanged, target == index {
            // 什么都没变：保持当前页。绝不再按外面的下标重新定位一次 —— 那一下会把
            // 读者自己上一次的残留页号顶掉一格（日志里每翻一页一条「入场=1 动画=false」）。
            return index
        }
        ReaderChapterTrace.log(
            "页序更新 换章=\(chapterChanged) 样式=\(styleChanged) 页面=\(visibleContentChanged) 规模=\(pageCountChanged) token=\(newToken) 落点=(\(focus.chapterIndex),\(focus.pageIndex)) 下标=\(target + 1)/\(newDeck.count)"
        )
        if !chapterChanged, !layoutChanged, !visibleContentChanged {
            // 眼前这一页一个字都没变，排版参数也没动：只是邻章页表拼进来了，或者只是
            // 底色 / 文字色 / 背景图 / 页内栏这类外观参数变了。
            // 静默接管页序，绝不重投。
            //
            // 照 InkShelf `CurlPageTurnController.configure` 的分工：只有
            // `contentChanged || layoutChanged` 才 `setViewControllers`，纯外观变化只
            // `updateHighlight`。这里对应「只 refreshBars」。此前把 `styleChanged` 并进
            // 重投分支，于是落地那一拍外层判 `样式=true 页面=false 规模=false` 就清缓存
            // 重投一次，正撞在卷页收尾上 —— 观感就是「回翻先闪一下前一页」。
            if isTurning {
                // 转场途中改 tag 会搅乱 UIKit 的记账：先排队，落地后再补。
                pendingState = PendingState(
                    deck: newDeck,
                    chapterToken: newToken,
                    style: newStyle,
                    target: target,
                    animated: animated,
                    silent: true
                )
                return target
            }
            adopt(deck: newDeck, focus: focus, chapterToken: newToken, style: newStyle)
            // 绘制参数真的变了就就地刷栏（时间、页码这类），不重建页面集合。
            refreshBars(header: newStyle.header, footer: newStyle.footer)
            return index
        }
        if isTurning {
            // 卷到一半时 setViewControllers 会把纸弹回原页：先排队，落地后再补。
            pendingState = PendingState(
                deck: newDeck,
                chapterToken: newToken,
                style: newStyle,
                target: target,
                animated: animated,
                silent: false
            )
            return target
        }
        apply(deck: newDeck, chapterToken: newToken, style: newStyle, target: target, animated: animated)
        return index
    }

    /// 整份页序与绘制参数整体替换。
    ///
    /// 换页序不再等于「换章转场」：页序里已经含相邻章，当前落点在两份页序里是同一页
    /// 内容，所以默认不带动画 —— 静默换成新页表，屏幕上那一页纹丝不动。只有菜单跳章
    /// 这类明确要从别处过来的动作才传 `animated: true`。
    private func apply(
        deck newDeck: ReaderPageDeck,
        chapterToken newToken: Int,
        style newStyle: ReaderCurlStyle,
        target: Int,
        animated: Bool
    ) {
        let resolved: ReaderPageDeck = newDeck.isEmpty
            ? ReaderPageDeck(
                chapters: [ReaderPageDeck.Chapter(index: 0, title: "", sheets: [ReaderCurlSheet()])],
                currentChapterIndex: 0
            )
            : newDeck
        let goal = min(max(target, 0), max(resolved.count - 1, 0))
        deck = resolved
        chapterToken = newToken
        chapterTitle = resolved.slot(at: goal)?.chapterTitle
        style = newStyle
        // 页序换了：旧缓存里每一页都属于旧页序，整体丢掉。
        frontCache.removeAll()
        backCache.removeAll()
        // token 推进，到头闩锁随之解锁。
        boundaryFiredToken = nil
        ReaderChapterTrace.log(
            "页序换页 token=\(newToken) 页数=\(resolved.count) 落地页=\(goal + 1) 动画=\(animated)"
        )
        index = goal
        view.backgroundColor = newStyle.backgroundColor

        // 还没上屏时没有可卷的画面，直接投递。
        guard animated, view.window != nil, !view.isHidden else {
            setViewControllers([front(goal)], direction: .forward, animated: false)
            return
        }
        isTurning = true
        setViewControllers(pair(goal, animated: true), direction: .forward, animated: true) { [weak self] finished in
            guard let self else { return }
            self.isTurning = false
            guard finished else { return }
            // 落地那一面可能是纸背：下一拍换回同一页的正面（内容一致，看不见换面）。
            // 绝不在这个回调里同步重投控制器 —— 转场收尾期间重入会把系统记账搅乱。
            self.normalizeBackFaceIfNeeded()
            self.onIndexChange?(self.index)
        }
    }

    /// 静默接管新页序：只换页表、重算下标、改写屏上那张纸的物理 tag，绝不重投控制器。
    ///
    /// 页序里含着上一章与下一章，邻章页表一到整卷规模就变，可读者眼前这一页一个字都
    /// 没变。这种时候 `setViewControllers` 是纯粹的坏事：它会把纸重新压一遍，快速来回
    /// 划时正好撞上手势（真机日志 (7) 同一落点上页数 `77→75→73→45→77→78` 反复变）。
    ///
    /// 所以只做四件事：
    /// 1. 把新页序接管为当前页序（`before` / `after` 立刻能看到新拼进来的邻章页）；
    /// 2. 按**页坐标**把屏上那一页重新映射成新下标（插进上一章之后，绝对下标会整体后移）；
    /// 3. 改写这张纸的物理 tag（正面 `2i` / 纸背 `2i + 1`），让 dataSource 从它继续算；
    /// 4. 丢掉带旧下标的页面缓存。
    ///
    /// 全程没有任何画面动作，UIKit 的内部记账也不会被动到 —— 与 InkShelf 的 `configure`
    /// 在「内容没变」时只 rebase、不重投，是同一手。
    private func adopt(
        deck newDeck: ReaderPageDeck,
        focus: ReaderDeckLocation,
        chapterToken newToken: Int,
        style newStyle: ReaderCurlStyle
    ) {
        // 空页序不许走静默接管：那会把屏上这一页换成空纸（`front(0)` 兜底成空 sheet）。
        // 这种情况退回让调用方走 `apply`，由它按「空页序 → 单张占位纸」的老规矩处理。
        guard !newDeck.isEmpty else { return }
        // 屏上这张纸在**旧**页序里的坐标：换页序之前按旧 tag 反查并记下来。
        var visibleLocation: ReaderDeckLocation?
        var visibleIsBack = false
        if let current = viewControllers?.first {
            // 用控制器身份而不是 `view.tag` 反查：tag 可写，改写它只为兼容，
            // 记账一律走 `deckIndex`（照 InkShelf `CurlPageSide.physicalPageIndex`）。
            if let back = current as? ReaderCurlBackController {
                visibleIsBack = true
                visibleLocation = deck.slot(at: back.deckIndex)?.location
            } else if let front = current as? ReaderCurlFrontController {
                visibleLocation = deck.slot(at: front.deckIndex)?.location
            }
        }
        deck = newDeck
        chapterToken = newToken
        style = newStyle
        // 缓存里每个 controller 都带着旧下标，整体丢掉；屏上那一张由 UIKit 持有，不在缓存里。
        frontCache.removeAll()
        backCache.removeAll()
        boundaryFiredToken = nil
        let landing: Int
        if let location = visibleLocation, let mapped = newDeck.index(of: location) {
            landing = mapped
        } else {
            landing = newDeck.nearestIndex(to: focus) ?? min(max(index, 0), max(newDeck.count - 1, 0))
        }
        index = landing
        chapterTitle = newDeck.slot(at: landing)?.chapterTitle
        // 物理 tag 必须跟着改写：dataSource 全靠它算 before / after，留着旧 tag 会指到错的页。
        if let current = viewControllers?.first {
            if let front = current as? ReaderCurlFrontController {
                front.deckIndex = landing
            } else if let back = current as? ReaderCurlBackController {
                back.deckIndex = landing
            }
            // tag 只作兼容保留（调试与系统内部不作数），记账一律走 `deckIndex`。
            current.view.tag = visibleIsBack ? landing * 2 + 1 : landing * 2
        }
        view.backgroundColor = newStyle.backgroundColor
        ReaderChapterTrace.log(
            "页序接管 页数=\(newDeck.count) 下标=\(landing + 1) 纸背=\(visibleIsBack) 落点=(\(focus.chapterIndex),\(focus.pageIndex))"
        )
    }

    /// 页内栏文案刷新：时间、页码这类每秒都会变的东西只换文字，不动页面集合。
    func refreshBars(header: ReaderCurlBarSpec?, footer: ReaderCurlBarSpec?) {
        for (_, entry) in frontCache {
            (entry.controller as? ReaderCurlFrontController)?.refreshBars(header: header, footer: footer)
        }
        // 屏上那一张不在缓存里（`adopt` 刚把缓存整体清空）：外观变化要就地刷到它身上，
        // 否则「不重投」就变成「这一页的底色 / 页码永远停在旧值」。
        (viewControllers?.first as? ReaderCurlFrontController)?.refreshBars(header: header, footer: footer)
    }

    /// 状态刷新时把当前页对齐：不重建控制器，避免丢掉进行中的卷页状态。
    func syncIndex(_ newIndex: Int) {
        guard !isTurning else { return }
        let clamped = min(max(newIndex, 0), max(pages.count - 1, 0))
        guard clamped != index else { return }
        index = clamped
        setViewControllers([front(clamped)], direction: .forward, animated: false)
    }

    /// 程序化翻一页（点击、自动阅读、手势守卫都走这里）。
    /// - Returns: false 表示到头了（已回调 onReachEnd / onReachStart）或正在转场。
    @discardableResult
    func turn(forward: Bool, animated: Bool = true) -> Bool {
        guard !isTurning else { return false }
        let target = index + (forward ? 1 : -1)
        guard target >= 0, target < pages.count else {
            // 到头这一下与章界旁听共用同一个闩锁：同一章只换一次。
            fireBoundary(forward: forward)
            return false
        }
        let direction: UIPageViewController.NavigationDirection = forward ? .forward : .reverse
        isTurning = true
        setViewControllers(
            pair(target, animated: animated),
            direction: direction,
            animated: animated
        ) { [weak self] finished in
            guard let self else { return }
            self.isTurning = false
            guard finished else { return }
            self.index = target
            self.normalizeBackFaceIfNeeded()
            self.onIndexChange?(target)
            if let location = self.deck.slot(at: target)?.location { self.onDeckCommit?(location) }
        }
        return true
    }

    // MARK: - 手势

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        onTap?(gesture.location(in: view))
    }

    /// 章末继续往前划：系统没有下一页可给，落在外层换章。
    @objc private func handleBoundaryPan(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .ended || gesture.state == .cancelled else { return }
        let translation = gesture.translation(in: view)
        let velocity = gesture.velocity(in: view)
        let forward = translation.x < -40 || velocity.x < -320
        let backward = translation.x > 40 || velocity.x > 320
        if forward, index >= pages.count - 1 {
            fireBoundary(forward: true)
        } else if backward, index <= 0 {
            fireBoundary(forward: false)
        }
    }

    /// 边界那一下系统手势可能不触发，用 swipe 兜底。
    @objc private func handleBoundarySwipe(_ gesture: UISwipeGestureRecognizer) {
        switch gesture.direction {
        case .left:
            if index >= pages.count - 1 { fireBoundary(forward: true) }
        case .right:
            if index <= 0 { fireBoundary(forward: false) }
        default:
            break
        }
    }

    // MARK: - 页面与缓存

    /// 一页的缓存键 = 绘制参数指纹 + 页数 + 下标 + 这一页的实际内容。
    /// 只看下标不行：换章时下标会重复，会拿到上一章的旧页面。
    private func cacheKey(_ pageIndex: Int) -> String {
        let sheet = pages[min(max(pageIndex, 0), pages.count - 1)]
        return style.signature + "|\(pages.count)|\(pageIndex)|" + sheet.textSignature
    }

    private func front(_ pageIndex: Int) -> UIViewController {
        let clamped = min(max(pageIndex, 0), max(deck.count - 1, 0))
        let key = cacheKey(clamped)
        if let cached = frontCache[clamped], cached.key == key { return cached.controller }
        let slot = deck.slot(at: clamped)
        // 页码按「所在章」编，不按整卷绝对下标：页序拼进相邻章之后，绝对下标一跨章
        // 就等于整本进度，页眉会显示成读者对不上的数。首页标题也只给该章的第 0 页。
        let chapterIndex = slot?.location.chapterIndex ?? 0
        let pageInChapter = slot?.location.pageIndex ?? clamped
        let pageCount = max(deck.pageCount(inChapter: chapterIndex), 1)
        let slotTitle = slot?.chapterTitle ?? ""
        let slotTitleForPage: String? = pageInChapter == 0
            ? (slotTitle.isEmpty ? chapterTitle : slotTitle)
            : nil
        let controller = ReaderCurlFrontController(
            sheet: slot?.sheet ?? ReaderCurlSheet(),
            style: style,
            chapterTitle: slotTitleForPage,
            pageIndex: pageInChapter,
            pageCount: pageCount
        )
        // 物理页编号：正面 = 2i（纸背 = 2i + 1，见 `back`）。
        controller.deckIndex = clamped
        controller.view.tag = clamped * 2
        frontCache[clamped] = (key, controller)
        trim(&frontCache)
        return controller
    }

    /// 一张纸的反面。
    ///
    /// 画的是「落地那一页」的镜像淡影 + 与纸张同色的底：翻过来看到的就是下一页（或
    /// 上一页）的韵味，落地后立刻换回同一页的正面，两者内容一致、看不见换面。
    private func back(_ pageIndex: Int) -> UIViewController {
        let clamped = min(max(pageIndex, 0), max(deck.count - 1, 0))
        let key = cacheKey(clamped) + "|back"
        if let cached = backCache[clamped], cached.key == key { return cached.controller }
        let controller = ReaderCurlBackController(
            style: style,
            ghostSheet: deck.slot(at: clamped)?.sheet ?? ReaderCurlSheet()
        )
        controller.deckIndex = clamped
        controller.view.tag = clamped * 2 + 1
        backCache[clamped] = (key, controller)
        trim(&backCache)
        return controller
    }

    /// 带动画投递要凑两张（`.min` 书脊下凑不齐会抛 count 断言），不带画只投正面。
    private func pair(_ pageIndex: Int, animated: Bool) -> [UIViewController] {
        let face = front(pageIndex)
        guard animated else { return [face] }
        let clamped = min(max(pageIndex, 0), max(deck.count - 1, 0))
        return [face, back(clamped)]
    }

    /// 落在纸背上时，下一拍换回同一页的正面。
    ///
    /// 绝不在 `didFinishAnimating` 里同步 `setViewControllers`：转场收尾期间重入会把
    /// 系统的内部记账搅乱 —— 真机日志里「划多了崩溃闪退」就是这条路径。所以放下一拍，
    /// 且带窗口在场与转场闸门两道检查。
    private func normalizeBackFaceIfNeeded() {
        guard view.window != nil, deck.count > 0 else { return }
        let target = index
        DispatchQueue.main.async { [weak self] in
            guard let self, self.view.window != nil, !self.isTurning else { return }
            guard self.viewControllers?.first is ReaderCurlBackController else { return }
            self.setViewControllers([self.front(target)], direction: .forward, animated: false)
        }
    }

    /// 缓存不能无限涨：按离当前页的距离淘汰最远的。
    private func trim(_ cache: inout [Int: (key: String, controller: UIViewController)]) {
        let limit = Self.cacheLimit
        guard cache.count > limit else { return }
        let evict = cache.keys.sorted { abs($0 - index) > abs($1 - index) }
        for key in evict.prefix(cache.count - limit) {
            cache.removeValue(forKey: key)
        }
    }
}

// MARK: - UIPageViewControllerDataSource / Delegate

extension ReaderNativeCurlController: UIPageViewControllerDataSource, UIPageViewControllerDelegate {

    func pageViewController(
        _ pageViewController: UIPageViewController,
        viewControllerBefore viewController: UIViewController
    ) -> UIViewController? {
        // 一张纸两个面：从纸背往回翻 = 回到同一页的正面；从正面往回翻 = 上一张纸的背面。
        // 寻址走控制器自己的 `deckIndex`，不看 `view.tag` —— tag 可写，一旦被改写就会指错页。
        if let backPage = viewController as? ReaderCurlBackController { return front(backPage.deckIndex) }
        guard let frontPage = viewController as? ReaderCurlFrontController else { return nil }
        let previous = frontPage.deckIndex - 1
        return previous >= 0 ? back(previous) : nil
    }

    func pageViewController(
        _ pageViewController: UIPageViewController,
        viewControllerAfter viewController: UIViewController
    ) -> UIViewController? {
        // 从正面往前翻 = 这一张纸的背面（落地后按方向翻译成 i + 1）；从纸背往前翻 =
        // 下一张纸的正面。页序到头必须返回 nil：给了纸，系统会把它卷出来卡在那里，
        // 章末那一下也落不到 gesture 的 ended 分支去请求下一段正文。
        if let backPage = viewController as? ReaderCurlBackController {
            let next = backPage.deckIndex + 1
            return next < deck.count ? front(next) : nil
        }
        guard let frontPage = viewController as? ReaderCurlFrontController else { return nil }
        guard frontPage.deckIndex + 1 < deck.count else { return nil }
        return back(frontPage.deckIndex)
    }

    func pageViewController(
        _ pageViewController: UIPageViewController,
        willTransitionTo pendingViewControllers: [UIViewController]
    ) {
        isTurning = true
        guard let pending = pendingViewControllers.first else { return }
        // 落点在手势开始时就算出来（照 InkShelf `PageTurnTransaction.begin`）：
        // 正面 = 这一页自己；纸背看方向 —— 往前翻是「这一张纸越过去了」＝下一页，
        // 往回翻是「上一张纸」＝它自己那一页。收尾只确认成败，不再事后反推。
        let target: Int
        if let front = pending as? ReaderCurlFrontController {
            target = front.deckIndex
        } else if let back = pending as? ReaderCurlBackController {
            let backPage = back.deckIndex
            target = backPage == index ? min(index + 1, max(deck.count - 1, 0)) : backPage
        } else {
            target = index
        }
        pendingTurnTarget = target
        // 纸背上的淡影必须是「落地那一页」：往前翻是下一张纸，往回翻是上一张纸。
        guard let back = pending as? ReaderCurlBackController else { return }
        back.configure(ghostSheet: deck.slot(at: target)?.sheet ?? ReaderCurlSheet())
    }

    func pageViewController(
        _ pageViewController: UIPageViewController,
        didFinishAnimating finished: Bool,
        previousViewControllers: [UIViewController],
        transitionCompleted completed: Bool
    ) {
        // 不管落没落地都先放开闸门，否则取消一次手势就把刷新卡死。
        isTurning = false
        // 手势开始时定下的落点在这里消费掉：取消的手势也一并清空，绝不留给下一次。
        let gestureTarget = pendingTurnTarget
        pendingTurnTarget = nil
        if completed,
           let controllers = pageViewController.viewControllers,
           !controllers.isEmpty {
            // 物理页 → 内容页：落在纸背上是「这一张纸已经翻过去了」，往前翻就是下一页，
            // 往回翻就是这一张纸自己那一页。这是双面卷页唯一的记账点，错一位就是
            // 「往后翻跳一页」或「翻不动」。
            // 落地页在手势开始时已经定下（`willTransitionTo`），这里只确认成败：
            // 照 InkShelf `CurlPageTurnController` 的 `transaction.finish(committed:)`，
            // 落点由 begin 决定、收尾只做确认。绝不再按屏上控制器的 tag 事后反推 ——
            // tag 是可变状态，`adopt` 与纸背换面都会改写它，落地一拍读到的 tag
            // 完全可能比记账下标多一格。
            let newIndex = gestureTarget ?? index
            let landedOnBack = (controllers[0] as? ReaderCurlBackController) != nil
            if newIndex >= 0, newIndex < deck.count, newIndex != index {
                // 一次手势只许走一页。页序重建与纸背换面叠在一起时，物理 tag 会比记账
                // 下标多走一格（真机日志里「从=29 到=27」「从=17 到=15」就是它）：记账
                // 一旦滑过位，下一帧的落点、纸背鬼影、页内页码全都跟着错一格 —— 回翻时
                // 看到的「先闪一下前一页内容」正是这一格。越界只夹回 ±1 并记一条日志。
                let clamped = index + (newIndex > index ? 1 : -1)
                ReaderChapterTrace.log("卷页落地 从=\(index + 1) 到=\(newIndex + 1) 纸背=\(landedOnBack)")
                if clamped != newIndex {
                    ReaderChapterTrace.log("卷页落地越界已夹回 从=\(index + 1) 到=\(newIndex + 1) 夹后=\(clamped + 1)")
                }
                index = clamped
                onIndexChange?(clamped)
                if let location = deck.slot(at: clamped)?.location { onDeckCommit?(location) }
            }
            // 落在纸背上：下一拍换回同一页的正面。绝不在转场收尾里同步重投控制器。
            normalizeBackFaceIfNeeded()
        }
        flushPendingState()
    }

    /// 转场期间攒下的状态更新在这里一次性补上。
    private func flushPendingState() {
        guard let pending = pendingState else { return }
        pendingState = nil
        guard !isTurning else { return }
        // 排队时就是静默更新，落地后也必须静默接管：走 `apply` 会把屏上这张纸重新
        // 投递一遍 ——「邻章页表一拼进来就重投」这条老路的最后一处残留就在这里。
        if pending.silent, let location = pending.deck.slot(at: pending.target)?.location {
            adopt(
                deck: pending.deck,
                focus: location,
                chapterToken: pending.chapterToken,
                style: pending.style
            )
            // 静默接管同样要把栏文案刷到新参数上：不重投，但也不能停着旧时间。
            refreshBars(header: pending.style.header, footer: pending.style.footer)
            return
        }
        apply(
            deck: pending.deck,
            chapterToken: pending.chapterToken,
            style: pending.style,
            target: pending.target,
            animated: pending.animated
        )
    }
}

// MARK: - 旁听手势

extension ReaderNativeCurlController: UIGestureRecognizerDelegate {
    /// 旁听的 pan 必须与卷页层自己的手势同时识别，否则会把翻页抢掉。
    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        true
    }
}

// MARK: - 纸背

/// 一张纸的反面。
///
/// 单面卷页（`isDoubleSided = false`）时这一面由 UIKit 自己画，纯白、不吃主题色 —— 真机
/// 实测「掀起的纸张太白」。双面模式把这一面交出来：底色用 `readerCurlBackColor` 预压暗
/// 一档（系统卷起时还会叠一层关不掉的提亮，压暗后正好落回主题纸色），另印一张「落地那
/// 一页」的镜像淡影，翻过来看到的是下一页（或上一页）的韵味。
private final class ReaderCurlBackController: UIViewController {
    private let style: ReaderCurlStyle
    private var ghostSheet: ReaderCurlSheet
    /// 这一面属于哪一页（整卷绝对下标）：与正面同一口径，供寻址与落地确认使用。
    var deckIndex = 0
    private let backgroundView = UIImageView()
    private lazy var ghostView = PaginatedTextPageView(frame: .zero)

    init(style: ReaderCurlStyle, ghostSheet: ReaderCurlSheet) {
        self.style = style
        self.ghostSheet = ghostSheet
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 换一张淡影：`willTransitionTo` 里按落地页当场给。
    func configure(ghostSheet sheet: ReaderCurlSheet) {
        ghostSheet = sheet
        guard isViewLoaded else { return }
        applyGhost()
    }

    override func loadView() {
        let container = UIView()
        container.clipsToBounds = true
        container.backgroundColor = readerCurlBackColor(style.backgroundColor)
        // 纸背必须整页不透明：透出下面那张纸，卷起来就是重影。
        container.isOpaque = true
        if let image = style.backgroundImage {
            backgroundView.image = image
            backgroundView.contentMode = .scaleAspectFill
            backgroundView.clipsToBounds = true
            container.addSubview(backgroundView)
        }
        // 镜像淡影：与页面上那一页方向相反，像纸背透过来的墨。
        ghostView.transform = CGAffineTransform(scaleX: -1, y: 1)
        ghostView.alpha = 0.18
        container.addSubview(ghostView)
        view = container
        applyGhost()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if style.backgroundImage != nil {
            backgroundView.frame = view.bounds
        }
        let insets = style.contentInsets
        let width = max(view.bounds.width, 1)
        let height = max(view.bounds.height, 1)
        let reservedWidth = max(width - insets.left - insets.right, 1)
        let drawWidth = style.contentWidth > 1 ? style.contentWidth : reservedWidth
        let bodyTop = insets.top + ghostSheet.titleHeight
        let bodyHeight = max(height - bodyTop - insets.bottom, 1)
        ghostView.frame = CGRect(x: insets.left, y: bodyTop, width: drawWidth, height: bodyHeight)
        ghostView.containerHeight = bodyHeight
        ghostView.renderSignature = ghostView.currentSignature()
    }

    private func applyGhost() {
        ghostView.lines = ghostSheet.lines
        ghostView.isParagraphEnd = ghostSheet.isParagraphEnd
        ghostView.fontSize = style.layout.fontSize
        ghostView.lineSpacing = style.layout.lineSpacing
        ghostView.letterSpacing = style.layout.letterSpacing
        ghostView.paragraphSpacing = style.layout.paragraphSpacing
        ghostView.firstLineIndent = style.layout.firstLineIndent
        ghostView.weightLevel = style.layout.weightLevel
        ghostView.fontPostScriptName = style.layout.fontPostScriptName
        ghostView.boldPostScriptName = style.layout.fontBoldPostScriptName
        ghostView.textColor = style.textColor
        ghostView.textAlignment = style.alignment
        ghostView.underlineEnabled = style.underline
        ghostView.underlineColor = style.underlineColor
        ghostView.containerWidth = style.contentWidth
        ghostView.renderSignature = ghostView.currentSignature()
    }
}

// MARK: - 正面

/// 一页纸的正面：排好版的行逐行绘制 + 首页标题 + 页内页眉页脚 + 整页背景图。
private final class ReaderCurlFrontController: UIViewController {
    private let sheet: ReaderCurlSheet
    private let style: ReaderCurlStyle
    private let chapterTitle: String?
    private let pageIndex: Int
    private let pageCount: Int
    /// 这一页在整卷页序里的绝对下标。
    ///
    /// 寻址一律认它（照 InkShelf `CurlPageSide.physicalPageIndex` 的控制器身份），
    /// `view.tag` 只作兼容保留：tag 可写、会被 `adopt` 改写，靠它反推邻页与落地页
    /// 会错一格。`pageIndex` 是「章内页号」，只用于页内栏盖章，不能当寻址用。
    var deckIndex = 0

    private let backgroundView = UIImageView()
    private let titleImageView = UIImageView()
    private let titleLabel = UILabel()
    private lazy var pageView = PaginatedTextPageView(frame: .zero)
    private lazy var headerBar: ReaderCurlBarView? = style.header.map { spec in
        var stamped = spec
        stamped.pageIndex = pageIndex
        stamped.pageCount = pageCount
        return ReaderCurlBarView(spec: stamped)
    }
    private lazy var footerBar: ReaderCurlBarView? = style.footer.map { spec in
        var stamped = spec
        stamped.pageIndex = pageIndex
        stamped.pageCount = pageCount
        return ReaderCurlBarView(spec: stamped)
    }

    init(sheet: ReaderCurlSheet, style: ReaderCurlStyle, chapterTitle: String?, pageIndex: Int, pageCount: Int) {
        self.sheet = sheet
        self.style = style
        self.chapterTitle = chapterTitle
        self.pageIndex = pageIndex
        self.pageCount = pageCount
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 时间 / 页码只更新文案：整卷若为一行时间重建，会清掉页面缓存并重新定位当前页。
    func refreshBars(header: ReaderCurlBarSpec?, footer: ReaderCurlBarSpec?) {
        if var spec = header {
            spec.pageIndex = pageIndex
            spec.pageCount = pageCount
            headerBar?.apply(spec)
        }
        if var spec = footer {
            spec.pageIndex = pageIndex
            spec.pageCount = pageCount
            footerBar?.apply(spec)
        }
    }

    override func loadView() {
        let container = UIView()
        container.clipsToBounds = true
        container.backgroundColor = style.backgroundColor
        // 纸面必须整页不透明：用背景图时底色是透明色，这一页若不自铺背景图，
        // 掀起来的纸就会透出下面那一页，看上去正是「翻页时上一页的重影」。
        if let image = style.backgroundImage {
            backgroundView.image = image
            backgroundView.contentMode = .scaleAspectFill
            backgroundView.clipsToBounds = true
            container.isOpaque = true
            container.addSubview(backgroundView)
        } else {
            container.isOpaque = style.backgroundColor.cgColor.alpha >= 0.99
        }

        // 首页标题：设计稿有位图就画位图，没有就把标题当文字画在预留高度里。
        // 预留高度由分页层给出，所以标题回来晚一点也不会让正文重排。
        if sheet.titleHeight > 0 {
            if let image = sheet.titleImage {
                titleImageView.image = image
                // 高度就是设计稿画布等比后的高度，宽度就是正文可用宽度：整幅铺满，
                // 不再等比缩到小盒子里（那样标题只剩顶部一小块、又小又残）。
                titleImageView.contentMode = .scaleToFill
                titleImageView.clipsToBounds = true
                container.addSubview(titleImageView)
            } else {
                titleLabel.text = sheet.titleText.isEmpty ? chapterTitle : sheet.titleText
                titleLabel.font = .systemFont(ofSize: max(10, style.titleFontSize), weight: .semibold)
                titleLabel.textColor = style.textColor
                titleLabel.numberOfLines = 0
                titleLabel.lineBreakMode = .byWordWrapping
                container.addSubview(titleLabel)
            }
        }

        pageView.lines = sheet.lines
        pageView.isParagraphEnd = sheet.isParagraphEnd
        pageView.fontSize = style.layout.fontSize
        pageView.lineSpacing = style.layout.lineSpacing
        pageView.letterSpacing = style.layout.letterSpacing
        pageView.paragraphSpacing = style.layout.paragraphSpacing
        pageView.firstLineIndent = style.layout.firstLineIndent
        pageView.weightLevel = style.layout.weightLevel
        pageView.fontPostScriptName = style.layout.fontPostScriptName
        pageView.boldPostScriptName = style.layout.fontBoldPostScriptName
        pageView.textColor = style.textColor
        pageView.textAlignment = style.alignment
        pageView.underlineEnabled = style.underline
        pageView.underlineColor = style.underlineColor
        pageView.paragraphSeparatorLines = style.layout.paragraphSpacing > 0 ? 0 : 0
        pageView.containerWidth = style.contentWidth
        container.addSubview(pageView)

        if let headerBar { container.addSubview(headerBar) }
        if let footerBar { container.addSubview(footerBar) }
        view = container
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = max(view.bounds.width, 1)
        let height = max(view.bounds.height, 1)
        let insets = style.contentInsets
        if style.backgroundImage != nil {
            backgroundView.frame = view.bounds
        }
        // 绘制宽度只认分页时那一份：从 frame 反算会差一丝，行尾那个字就被裁掉一点。
        let reservedWidth = max(width - insets.left - insets.right, 1)
        let drawWidth = style.contentWidth > 1 ? style.contentWidth : reservedWidth
        let titleHeight = sheet.titleHeight
        if titleHeight > 0 {
            let box = CGRect(x: insets.left, y: insets.top, width: drawWidth, height: titleHeight)
            if sheet.titleImage != nil {
                titleImageView.frame = box
            } else {
                titleLabel.frame = box
            }
        }
        let bodyTop = insets.top + titleHeight
        let bodyHeight = max(height - bodyTop - insets.bottom, 1)
        pageView.frame = CGRect(x: insets.left, y: bodyTop, width: drawWidth, height: bodyHeight)
        pageView.containerHeight = bodyHeight
        pageView.renderSignature = pageView.currentSignature()

        let barHeight = ReaderCurlBarView.barHeight
        if let headerBar {
            let gap = style.header?.gap ?? 0
            headerBar.frame = CGRect(x: 0, y: gap, width: width, height: barHeight)
        }
        if let footerBar {
            let gap = style.footer?.gap ?? 0
            footerBar.frame = CGRect(x: 0, y: height - gap - barHeight, width: width, height: barHeight)
        }
    }
}

// MARK: - 页内栏

/// 页内一栏页眉 / 页脚。必须画在页里而不是留在外层 chrome：只有在这一层，
/// 它才会跟着纸页一起被卷起。
private final class ReaderCurlBarView: UIView {
    static let barHeight: CGFloat = ReaderCurlBarSpec.height
    private static let textRowHeight: CGFloat = 18
    private static let dividerHeight: CGFloat = 0.5
    private static let columnSpacing: CGFloat = 8

    private var spec: ReaderCurlBarSpec
    private let leftLabel = UILabel()
    private let middleLabel = UILabel()
    private let rightLabel = UILabel()
    private let divider = UIView()

    init(spec: ReaderCurlBarSpec) {
        self.spec = spec
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isOpaque = false
        backgroundColor = .clear
        let tint = spec.textColor.withAlphaComponent(0.8)
        let columns: [(UILabel, NSTextAlignment, String)] = [
            (leftLabel, .left, spec.left),
            (middleLabel, .center, spec.middle),
            (rightLabel, .right, spec.right)
        ]
        for (label, alignment, value) in columns {
            label.font = .systemFont(ofSize: 11)
            label.textColor = tint
            label.textAlignment = alignment
            label.lineBreakMode = .byTruncatingTail
            label.numberOfLines = 1
            label.text = spec.resolved(value)
            addSubview(label)
        }
        divider.isHidden = !spec.showsDivider
        divider.backgroundColor = spec.textColor.withAlphaComponent(0.12)
        addSubview(divider)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 只换文案与颜色：页内栏每秒都在更新，不该为此重建整卷。
    func apply(_ newSpec: ReaderCurlBarSpec) {
        spec = newSpec
        let tint = newSpec.textColor.withAlphaComponent(0.8)
        leftLabel.text = newSpec.resolved(newSpec.left)
        middleLabel.text = newSpec.resolved(newSpec.middle)
        rightLabel.text = newSpec.resolved(newSpec.right)
        leftLabel.textColor = tint
        middleLabel.textColor = tint
        rightLabel.textColor = tint
        divider.isHidden = !newSpec.showsDivider
        divider.backgroundColor = newSpec.textColor.withAlphaComponent(0.12)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let width = max(bounds.width, 1)
        let rowY = spec.dividerOnBottom ? 0 : Self.dividerHeight
        let dividerY = spec.dividerOnBottom ? Self.textRowHeight : 0
        divider.frame = CGRect(x: 0, y: dividerY, width: width, height: Self.dividerHeight)
        let contentWidth = max(width - spec.leftInset - spec.rightInset, 1)
        let columnWidth = max((contentWidth - Self.columnSpacing * 2) / 3, 1)
        leftLabel.frame = CGRect(x: spec.leftInset, y: rowY, width: columnWidth, height: Self.textRowHeight)
        middleLabel.frame = CGRect(
            x: spec.leftInset + columnWidth + Self.columnSpacing,
            y: rowY,
            width: columnWidth,
            height: Self.textRowHeight
        )
        rightLabel.frame = CGRect(
            x: width - spec.rightInset - columnWidth,
            y: rowY,
            width: columnWidth,
            height: Self.textRowHeight
        )
    }
}

extension UIView {
    /// 最近的宿主控制器：原生卷页要 `addChild`，必须拿到真正的父控制器。
    func readerEnclosingViewController() -> UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController { return controller }
            responder = current.next
        }
        return nil
    }
}
