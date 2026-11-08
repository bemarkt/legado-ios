import SwiftUI
import UIKit


private final class ReaderLayoutTextView: UITextView {
    var onLayout: ((UITextView) -> Void)?
    private var reportedSize = CGSize.zero
    private var reportedContentSize = CGSize.zero

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { onLayout?(self) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0,
              bounds.size != reportedSize || contentSize != reportedContentSize else { return }
        reportedSize = bounds.size
        reportedContentSize = contentSize
        onLayout?(self)
    }
}

struct ReaderTextView: UIViewRepresentable {
    let text: String
    let title: String
    let previousTitle: String?
    let previousText: String
    let isPreviousReady: Bool
    let continuationTitle: String?
    let continuationText: String
    let isContinuationReady: Bool
    /// 当前章在整本书里的绝对下标。
    ///
    /// 页序拼接必须用**绝对章号**（上一章 = chapterIndex − 1 / 本章 / 下一章 = chapterIndex + 1）。
    /// 相对编号（−1/0/+1）在每次晋升后都得整体重映射，于是必须靠「待消费锚点」把落点搬过
    /// 重映射那道缝 —— 真机日志 (6) 里那串 `落点=(0,0) … 下标=1/29` 就是落点掉进缝里、
    /// `nearestIndex` 只能映射成新章首页（「掀起是尾页、落下是首页」）。
    /// 绝对章号下，一页的坐标跨帧不变（17 章末页永远是 (17, 14)），不需要锚点。
    let chapterIndex: Int
    let isVolume: Bool
    let fontSize: Double
    let fontPath: String
    let letterSpacing: Double
    let lineSpacing: Double
    let paragraphSpacing: Double
    let paragraphIndent: String
    let paddingLeft: Double
    let paddingRight: Double
    let paddingTop: Double
    let paddingBottom: Double
    let headerInset: Double
    let footerInset: Double
    /// 仿真翻页的页内页眉 / 页脚：画在每一页里，跟着纸页一起被卷起。
    /// 按页盖章（页码）由 `Coordinator.livePageContent` 负责。
    let headerBar: ReaderCurlBarSpec?
    let footerBar: ReaderCurlBarSpec?
    let fontWeight: Int
    let titleMode: Int
    let titleSize: Double
    let titleTopSpacing: Double
    let titleBottomSpacing: Double
    let underlineMode: Int
    /// 页末匀空白（Juyue `reader_justify_last_page`）。
    let justifyLastPage: Bool
    /// 中文标点禁则（Juyue `reader_punctuation_kinsoku`）。
    let punctuationKinsoku: Bool
    /// 智能分段（Juyue `reader_smart_paragraphs`）。
    let smartParagraphs: Bool
    /// 简繁转换（Juyue `chinese_conversion`）：0 原文 / 1 转简 / 2 转繁。
    let chineseConversion: Int
    /// 下划线线型（Juyue `reader_underline_pattern`）：0 实 / 1 点 / 2 虚 / 3 点划。
    let underlinePattern: Int
    /// 段末分隔线根数（Juyue `paragraph_separator_lines`）。
    let paragraphSeparatorLines: Int
    /// 章节标题设计稿的 HTML 模板（Juyue `chapterTitleHTMLTemplate`）。
    let titleHTMLTemplate: String
    /// 设计稿工程 JSON：资源内联与「下次打开设计器回灌」都靠它（Juyue `chapterTitleProjectJSON`）。
    let titleProjectJSON: String
    /// 设计器回传的画布高度：工程 JSON 里缺 canvas 字段时用它兜住预留高度。
    let titleCanvasHeight: Double
    let isSelectable: Bool
    let fullJustify: Bool
    let pageAnimation: Int
    let isEInkMode: Bool
    let clickActions: [Int]
    let backgroundColor: UIColor
    /// 阅读背景图：仿真翻页的每一页（含纸背）都要自己铺一份。
    ///
    /// 用背景图时 `backgroundColor` 是透明色，页与页之间就会互相透出来 —— 掀起的
    /// 那一页下面还压着上一页，看上去就是「翻页时上一页的重影」，纸背也成了半透明
    /// 的薄片（卷边阴影跟着发脏）。整页铺图之后每一页都是不透明的纸。
    let backgroundImage: UIImage?
    let foregroundColor: UIColor
    let requestedPosition: Int
    /// 旧存档页号仅供诊断；不能用页数相同推断分页边界相同。
    var requestedPage: Int = 0
    /// 存下 `requestedPage` 时那一章的页数：与当前分页结果不同即视为版面变了，旧页号作废。
    var requestedPageCount: Int = 0
    let jumpPosition: Int?
    let renderRevision: Int
    @Binding var readerPosition: Int
    @Binding var pageRanges: [NSRange]
    @Binding var currentPage: Int
    @Binding var totalPages: Int
    let isAutoReading: Bool
    let isAutoReadPaused: Bool
    let isLoadingNextChapter: Bool
    let secondsPerScreen: Double
    let onReachedEnd: (Int) -> Void
    let onReachedStart: (Int) -> Void
    let onEnteredPrevious: (Int) -> Void
    let onEnteredContinuation: (Int) -> Void
    let onDeferredRender: () -> Void
    let onCancelNextLoading: () -> Void
    let onPageChanged: () -> Void
    /// 同一次落地的章号、页号、页数与原文位置，作为一个快照回报。
    var onPageSettled: (ReaderPageProgress) -> Void = { _ in }
    let onTapAction: (Int) -> Void
    /// 仿真模式下卷页层是否已经在屏上。
    ///
    /// 阅读页用它决定要不要盖「正在打开本章」这层提示：换章那一帧新章正文还没到，
    /// 旧页必须继续留在屏上。一旦把界面换成加载提示，SwiftUI 会把 ReaderTextView
    /// 连同卷页层一起拆掉重建 —— 观感就只剩闪一下加载、永远没有卷页转场。
    let onCurlPublished: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    /// 系统卷页会给卷起的那张纸加一层关不掉的提亮高光，纸背底色必须预压暗一档，
    /// 被提亮之后正好落回主题色。
    static func nativeCurlBackColor(_ color: UIColor) -> UIColor {
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

    func makeUIView(context: Context) -> UITextView {
        // Pagination uses NSLayoutManager. Start in TextKit 1 rather than
        // switching a TextKit 2 view after its content size has been computed.
        let view: ReaderLayoutTextView
        if #available(iOS 16.0, *) {
            view = ReaderLayoutTextView(usingTextLayoutManager: false)
        } else {
            view = ReaderLayoutTextView(frame: .zero)
        }
        view.onLayout = { [weak coordinator = context.coordinator] view in
            coordinator?.syncNativeCurl(in: view)
            coordinator?.reportPage(in: view)
            coordinator?.reportPageRanges(in: view)
        }
        view.accessibilityIdentifier = "reader.text"
        let effectivePageAnimation = isEInkMode ? 4 : pageAnimation
        view.backgroundColor = backgroundColor
        view.isOpaque = backgroundColor != .clear
        view.delegate = context.coordinator
        view.isEditable = false
        view.isSelectable = false
        view.alwaysBounceVertical = effectivePageAnimation == 3
        view.isScrollEnabled = true
        view.panGestureRecognizer.isEnabled = effectivePageAnimation == 3
        view.textContainer.lineFragmentPadding = 4
        view.showsVerticalScrollIndicator = false
        view.isPagingEnabled = effectivePageAnimation != 3
        view.decelerationRate = effectivePageAnimation == 3 ? .normal : .fast
        context.coordinator.installDisplayLink(for: view)
        context.coordinator.installGestures(on: view)
        context.coordinator.updateInteractionMode(on: view, isScrollMode: effectivePageAnimation == 3)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        if context.coordinator.isCurlTurning {
            context.coordinator.needsDeferredRender = true
            return
        }
        if !isEInkMode, pageAnimation == 2, text.isEmpty, context.coordinator.hasPublishedCurlPages { return }
        context.coordinator.parent = self
        context.coordinator.isUpdatingView = true
        defer {
            context.coordinator.isUpdatingView = false
            context.coordinator.syncNativeCurl(in: view)
            context.coordinator.reportPage(in: view)
            context.coordinator.reportPageRanges(in: view)
        }
        let viewportSizeChanged = view.bounds.size != .zero
            && context.coordinator.lastViewportSize != view.bounds.size
        if viewportSizeChanged {
            context.coordinator.lastViewportSize = view.bounds.size
        }
        let effectivePageAnimation = isEInkMode ? 4 : pageAnimation
        view.isSelectable = false
        view.alwaysBounceVertical = effectivePageAnimation == 3
        view.isScrollEnabled = true
        view.panGestureRecognizer.isEnabled = effectivePageAnimation == 3
        view.showsVerticalScrollIndicator = false
        view.isPagingEnabled = effectivePageAnimation != 3
        view.decelerationRate = effectivePageAnimation == 3 ? .normal : .fast
        context.coordinator.updateInteractionMode(on: view, isScrollMode: effectivePageAnimation == 3)
        view.backgroundColor = backgroundColor
        view.isOpaque = backgroundColor != .clear
        view.isSelectable = false
        view.selectedRange = NSRange(location: 0, length: 0)
        view.resignFirstResponder()
        view.textContainerInset = .init(
            top: CGFloat(paddingTop + headerInset),
            left: CGFloat(paddingLeft),
            bottom: CGFloat(paddingBottom + footerInset),
            right: CGFloat(paddingRight)
        )
        let contentKey = text.hashValue
        let primaryContentKey = "\(chapterIndex)|\(title)|\(text)".hashValue
        let showsContinuation = effectivePageAnimation == 3 && isContinuationReady && continuationTitle != nil
        let showsPrevious = showsContinuation && isPreviousReady && previousTitle != nil
        let adjacentContentKey = "\(showsPrevious)|\(previousTitle ?? "")|\(previousText)|\(showsContinuation)|\(continuationTitle ?? "")|\(continuationText)".hashValue
        let displaysTitle = titleMode != 2 || isVolume
        let titlePrefix = displaysTitle && !title.isEmpty ? title + "\n" : ""
        let styleKey = "\(contentKey)|\(adjacentContentKey)|\(title)|\(isVolume)|\(fontSize)|\(fontPath)|\(letterSpacing)|\(lineSpacing)|\(paragraphSpacing)|\(paragraphIndent)|\(paddingLeft)|\(paddingRight)|\(paddingTop)|\(paddingBottom)|\(headerInset)|\(footerInset)|\(fontWeight)|\(titleMode)|\(titleSize)|\(titleTopSpacing)|\(titleBottomSpacing)|\(underlineMode)|\(underlinePattern)|\(paragraphSeparatorLines)|\(justifyLastPage)|\(punctuationKinsoku)|\(smartParagraphs)|\(chineseConversion)|\(isSelectable)|\(fullJustify)|\(effectivePageAnimation)|\(foregroundColor.hash)|\(backgroundImage?.hashValue ?? 0)"
        if context.coordinator.styleKey != styleKey || context.coordinator.primaryContentKey != primaryContentKey {
            if context.coordinator.shouldDeferRender(in: view) {
                context.coordinator.needsDeferredRender = true
                return
            }
            let primaryContentChanged = context.coordinator.primaryContentKey != primaryContentKey
            let visiblePosition = context.coordinator.contentCharacter(at: view.contentOffset, in: view)
            if primaryContentChanged {
                context.coordinator.prepareCurlEntry(position: requestedPosition, preservingChapter: true)
            }
            context.coordinator.resetAutoReadForPageChange()
            context.coordinator.resetPageRangeRetry()
            context.coordinator.contentKey = contentKey
            context.coordinator.primaryContentKey = primaryContentKey
            context.coordinator.styleKey = styleKey
            let typography = ReaderTypography(configuration: self)
            let bodyAttributes = typography.bodyAttributes
            let rendered = NSMutableAttributedString(string: "")
            context.coordinator.previousBodyStart = nil
            context.coordinator.previousBodyEnd = nil
            context.coordinator.continuationSectionStart = nil
            context.coordinator.continuationBodyStart = nil
            if showsPrevious {
                let previousHeading = displaysTitle ? (previousTitle ?? "") + "\n" : ""
                rendered.append(NSAttributedString(string: previousHeading, attributes: typography.headingAttributes))
                context.coordinator.previousBodyStart = rendered.length
                rendered.append(NSAttributedString(
                    string: previousText.isEmpty ? String(repeating: "\n", count: 80) : previousText,
                    attributes: bodyAttributes
                ))
                context.coordinator.previousBodyEnd = rendered.length
                rendered.append(NSAttributedString(string: "\n\n", attributes: bodyAttributes))
            }
            context.coordinator.currentSectionStart = rendered.length
            if !titlePrefix.isEmpty {
                rendered.append(NSAttributedString(string: titlePrefix, attributes: typography.headingAttributes))
            }
            context.coordinator.renderedPrefixLength = rendered.length
            rendered.append(NSAttributedString(string: text, attributes: bodyAttributes))
            context.coordinator.currentBodyEnd = rendered.length
            if showsContinuation {
                rendered.append(NSAttributedString(string: "\n\n", attributes: bodyAttributes))
                context.coordinator.continuationSectionStart = rendered.length
                let continuationHeading = displaysTitle ? (continuationTitle ?? "") + "\n" : ""
                rendered.append(NSAttributedString(string: continuationHeading, attributes: typography.headingAttributes))
                context.coordinator.continuationBodyStart = rendered.length
                rendered.append(NSAttributedString(
                    string: continuationText.isEmpty ? String(repeating: "\n", count: 80) : continuationText,
                    attributes: bodyAttributes
                ))
            }
            context.coordinator.isApplyingContent = true
            view.attributedText = rendered
            // 活页容器复用同一份 attributedText：翻页时正文是矢量的，不是快照。
            context.coordinator.livePageText = rendered
            context.coordinator.isApplyingContent = false
            context.coordinator.scroll(
                to: primaryContentChanged ? requestedPosition : visiblePosition,
                in: view
            )
            let generation = context.coordinator.layoutGeneration
            DispatchQueue.main.async { [weak coordinator = context.coordinator] in
                guard coordinator?.layoutGeneration == generation else { return }
                coordinator?.reportPage(in: view)
                coordinator?.reportPageRanges(in: view)
            }
        } else if viewportSizeChanged {
            context.coordinator.scroll(to: readerPosition, in: view)
            let generation = context.coordinator.layoutGeneration
            DispatchQueue.main.async { [weak coordinator = context.coordinator] in
                guard coordinator?.layoutGeneration == generation else { return }
                coordinator?.reportPage(in: view)
                coordinator?.reportPageRanges(in: view)
            }
        }
        if let jumpPosition, context.coordinator.lastJumpPosition != jumpPosition {
            context.coordinator.lastJumpPosition = jumpPosition
            context.coordinator.prepareCurlEntry(position: jumpPosition, preservingChapter: false)
            context.coordinator.scroll(to: jumpPosition, in: view)
        } else if jumpPosition == nil {
            context.coordinator.lastJumpPosition = nil
        }
        context.coordinator.updateLoadingFooter(in: view, visible: isLoadingNextChapter)
        context.coordinator.updateAutoRead(
            isRunning: isAutoReading,
            isPaused: isAutoReadPaused,
            secondsPerScreen: secondsPerScreen
        )

    }

    static func dismantleUIView(_ view: UITextView, coordinator: Coordinator) {
        coordinator.invalidate()
    }

    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var parent: ReaderTextView
        var contentKey = 0
        var primaryContentKey = 0
        var styleKey = ""
        var renderedPrefixLength = 0
        var currentSectionStart = 0
        var currentBodyEnd = 0
        var previousBodyStart: Int?
        var previousBodyEnd: Int?
        var continuationSectionStart: Int?
        var continuationBodyStart: Int?
        var lastJumpPosition: Int?
        private(set) var layoutGeneration = 0
        var lastViewportSize = CGSize.zero
        private var isAutoReading = false
        private var isAutoReadPaused = false
        private var secondsPerScreen = 10.0
        private weak var textView: UITextView?
        private var displayLink: CADisplayLink?
        private var lastTimestamp: CFTimeInterval = 0
        private var isUserDragging = false
        private var lastDragOffsetY: CGFloat = 0
        private var dragDirection = 0
        private var didReachEnd = false
        private var didReachStart = false
        private var didEnterPrevious = false
        private var didEnterContinuation = false
        private var pendingPreviousPosition: Int?
        private var pendingContinuationPosition: Int?
        var needsDeferredRender = false
        var isUpdatingView = false
        var isApplyingContent = false
        private var isTurningPage = false
        private var isRenderingAutoPage = false
        private var lastReportedPage: Int?
        private var autoPageProgress: CGFloat = 0
        private var eInkElapsed: CFTimeInterval = 0
        private var eInkPageInterval: CFTimeInterval = 10
        private var autoPageTarget: CGFloat?
        private weak var autoPageOverlay: UIImageView?
        private var pageRangeRetryCount = 0
        private weak var nextSwipe: UISwipeGestureRecognizer?
        private weak var previousSwipe: UISwipeGestureRecognizer?
        private weak var readerTap: UITapGestureRecognizer?
        private weak var loadingFooter: UIView?
        private var didRequestLoadingCancellation = false
        /// 仿真翻页的原生卷页层（`UIPageViewController` + `.pageCurl`）。
        /// 强引用：父控制器一旦找错（宿主是 UIWindow，responder 链上没有控制器），
        /// 弱引用会让卷页控制器当场释放 —— 页面还在，手势与 dataSource 全哑。
        private var nativeCurl: ReaderNativeCurlController?
        private var nativeCurlHost: UIView?
        /// 纸铺满整屏、宿主只占安全区那一块：宿主若裁剪子视图，纸的上下两截会被切回去。
        /// 这里记下被放开裁剪的宿主与原值，拆层时还原，不影响别的界面。
        private weak var nativeCurlClipHost: UIView?
        private var nativeCurlClipHostOriginal = true
        /// 卷页层在场时被清空字色的正文视图，与它原来的字色：拆层时要还原。
        private weak var nativeCurlTextHiddenView: UITextView?
        private var nativeCurlTextHiddenColor: UIColor?
        private var nativeCurlPageCount = 0
        private var nativeCurlSignatureValue = ""
        /// 换章序号：由「正文章节身份」派生（标题 + 正文哈希），不再自增。
        ///
        /// 自增版本的问题：新章正文是由布局回调先送进卷页层的，那时序号还没 +1，
        /// 于是被当成「同章重排」在无动画下把第 1 页推上去；随后 SwiftUI 更新才 +1，
        /// 又从第 1 页带画卷到末页 —— 真机日志里一次换章就是三条「卷页换页」。
        /// 改成内容派生后，「正文到」与「换章」是同一件事，只会有一次替换。
        var curlChapterToken: Int {
            var hasher = Hasher()
            hasher.combine(parent.title)
            hasher.combine(parent.text.hashValue)
            return hasher.finalize()
        }
        /// 卷页层是否已经上屏：仿真模式下正文为空（换章那一帧）时据此跳过渲染。
        var hasPublishedCurlPages: Bool { nativeCurl != nil }
        /// 换章那一帧定下的入场页号：nil 表示还没定。定过之后同章内一直沿用它。
        var curlEntryIndex: Int?
        private var curlRequestedPosition: Int?
        private var settledCurlProgress: ReaderPageProgress?
        private var progressPublication = 0
        private var isInvalidated = false
        private var isSyncingCurl = false
        var isCurlTurning: Bool { nativeCurl?.isTurning == true }

        func prepareCurlEntry(position: Int, preservingChapter: Bool) {
            guard effectiveAnimation == 2 else { return }
            if preservingChapter, let active = activeDeckLocation, active.chapterIndex == parent.chapterIndex {
                curlEntryIndex = active.pageIndex
                curlCurrentIndex = active.pageIndex
                curlRequestedPosition = nil
            } else {
                curlEntryIndex = nil
                curlRequestedPosition = position
                activeDeckLocation = nil
            }
        }

        /// 卷页层当前页号：卷页落地时更新，同章内的同步都以它为准。
        private var curlCurrentIndex = 0
        /// 当前屏上那份页序：卷页层的绝对下标要靠它换算回「章内页号」。
        private var curlDeck: ReaderPageDeck?
        /// 屏上这一页的页序坐标（绝对章号 + 章内页号）。
        ///
        /// 这是仿真模式里「读者现在在哪一页」的**唯一权威**。`requestedPosition`、正文
        /// 字符偏移、上一帧的绝对下标都只是它的输入，绝不反过来决定第几页。
        /// 真机日志 (6) 里那串 `落点=(0,0) … 下标=1/29` 就是反过来的结果：晋升后坐标
        /// 退回 (0,0)，`nearestIndex` 只能映射到新章首页。
        private var activeDeckLocation: ReaderDeckLocation?
        /// 相邻章页表的缓存：`updateUIView` 每帧都会走一次页序构建，
        /// 不缓存就等于每帧给两章各排一次版（一章十几页，纯浪费）。
        private var curlDeckCache: ReaderPageDeck?
        private var curlDeckCacheKey = ""
        /// 相邻章页表的页首字符表，按**绝对章号**存一份。
        ///
        /// 跨章落地要给新章写真实的页首字符（而不是 0）：否则「仿真模式下 `readerPosition`
        /// 永远等于卷页层当前页首字符」这条不变量被破坏，存档的字符偏移那一半就废了 ——
        /// 真机日志里那批 `偏移=0 页>1` 正是它。侧表与 `curlDeckCache` 用同一把键，
        /// 避免两套相邻章缓存各自过期、拼出一份页表却配上一份旧页首表。
        private var curlAdjacentStarts: [Int: [Int]] = [:]

        /// 卷页落地：把「落在页序的哪一章哪一页」翻译成外层动作。
        ///
        /// 章内落地什么都不用做（`onIndexChange` 已经按章内页号对齐了正文偏移）。
        /// 落在相邻章才是页序的真正收益：读者是**继续拖**过来的，不是被程序化转场推
        /// 过来的。这里只把该章晋升成当前章并记下章内页号，下一帧页序按这个页号落位，
        /// 内容不变、不重排、不闪。
        private func handleDeckCommit(_ location: ReaderDeckLocation) {
            // 落点先记账：绝对坐标跨帧有效，章内 / 跨章都不需要再消费一次。
            activeDeckLocation = location
            guard location.chapterIndex != parent.chapterIndex else { return }
            // 跨章落地：读者是把相邻章那一页「继续拖」过来的，正文早就在手。
            // 这里只把该章晋升成当前章；页序坐标不变，下一帧按同一个坐标落位。
            // 交出去的是**新章那一页的首字符**，不是 0。
            // 仿真模式的进度不变量是「`readerPosition` 永远等于卷页层当前页首字符」，
            // 这一拍写 0 就把它打断了：随后 `saveProgress` 存下「偏移 0 + 页号 n」，
            // 重进只能落章首（真机日志里那批 `偏移=0 页>1` 就是这条路径）。
            guard let startCharacter = deckStartCharacter(for: location) else { return }
            ReaderChapterTrace.log("卷页落地(跨章) 章=\(location.chapterIndex + 1) 页=\(location.pageIndex + 1) 页首=\(startCharacter)")
            if location.chapterIndex < parent.chapterIndex {
                parent.onEnteredPrevious(startCharacter)
            } else {
                parent.onEnteredContinuation(startCharacter)
            }
        }
        /// 已经回报给阅读页的「卷页层是否上屏」状态：只在翻转时回调一次。
        private var curlPublishedReported = false

        /// 回报卷页层是否已在屏上。
        ///
        /// 阅读页据此决定要不要盖「正在打开本章」：换章那一帧旧页还在屏上，这一层
        /// 必须留着，否则整块阅读面被换成加载提示，卷页层连动画一起被拆掉重建。
        private func notifyCurlPublished(_ published: Bool) {
            guard curlPublishedReported != published else { return }
            curlPublishedReported = published
            let callback = parent.onCurlPublished
            // 回调会改 SwiftUI 状态：落到下一个 runloop，避免在视图更新途中改状态。
            DispatchQueue.main.async { callback(published) }
        }
        /// 分页 / 绘制结果的缓存：分页层、绘制层、卷页层共用同一份。
        private var curlSheets: [ReaderCurlSheet] = []
        private var curlStartCharacters: [Int] = []
        private var curlStyleCache: ReaderCurlStyle?
        private var curlContentKey = ""
        /// 活页容器的正文：与主视图完全同一份 attributedText，翻页时矢量清晰。
        /// 不带 `private`：`updateUIView`（外层 struct 的方法）在渲染后要写入它，
        /// 同文件不同类型读不到 `private` 成员，CI 实测报 “'livePageText' is inaccessible
        /// due to 'private' protection level”。与 `isApplyingContent` 等状态同级即可。
        var livePageText: NSAttributedString?
        /// 行对齐的页首偏移缓存（textContainer 坐标），键含布局代数与视口尺寸。
        private var pageStartCache: [CGFloat] = []
        private var pageStartCacheKey = ""
        /// 正文几何 debug 的屏幕浮层与去重键：只在几何真的变了时才重画，避免每帧重建子视图。
        private weak var debugOverlayView: UIView?
        private var debugOverlaySignature = ""
        private var debugLogKey = ""

        /// E-Ink 模式强制成 case 4，其余模式直接用设置里的翻页动画。
        private var effectiveAnimation: Int { parent.isEInkMode ? 4 : parent.pageAnimation }

        /// 从入场到退出，隐藏的 UITextView 都不能成为仿真模式的进度来源。
        private var usesCurlAsProgressAuthority: Bool {
            effectiveAnimation == 2
        }

        init(parent: ReaderTextView) { self.parent = parent }

        func installDisplayLink(for view: UITextView) {
            textView = view
            let link = CADisplayLink(target: self, selector: #selector(step(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        func installGestures(on view: UITextView) {
            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
            tap.delaysTouchesBegan = false
            tap.cancelsTouchesInView = false
            tap.delegate = self
            view.addGestureRecognizer(tap)
            readerTap = tap
            let next = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
            next.direction = .left
            view.addGestureRecognizer(next)
            let previous = UISwipeGestureRecognizer(target: self, action: #selector(swiped(_:)))
            previous.direction = .right
            view.addGestureRecognizer(previous)
            nextSwipe = next
            previousSwipe = previous
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            gestureRecognizer === readerTap || otherGestureRecognizer === readerTap
        }

        func updateInteractionMode(on view: UITextView, isScrollMode: Bool) {
            // The scroll reader owns the vertical pan gesture. Horizontal
            // swipe recognizers must be disabled there or UIKit can cancel the
            // pan before the user reaches the end of a long chapter.
            // 仿真翻页交给原生卷页层，滑动手势让位。
            let allowsSwipe = !isScrollMode && effectiveAnimation != 2
            nextSwipe?.isEnabled = allowsSwipe
            previousSwipe?.isEnabled = allowsSwipe
            view.panGestureRecognizer.isEnabled = isScrollMode
            view.alwaysBounceVertical = isScrollMode
            view.isPagingEnabled = !isScrollMode
            view.showsVerticalScrollIndicator = false
            // 页表在 updateUIView 结束后统一安装，不能提前读取半更新的正文/边距。
            if effectiveAnimation != 2 { tearDownNativeCurl() }
        }

        func updateLoadingFooter(in view: UITextView, visible: Bool) {
            if !visible {
                loadingFooter?.removeFromSuperview()
                loadingFooter = nil
                view.contentInset.bottom = 0
                didRequestLoadingCancellation = false
                return
            }
            let footer: UIView
            if let loadingFooter {
                footer = loadingFooter
            } else {
                let container = UIView()
                container.isUserInteractionEnabled = false
                let indicator = UIActivityIndicatorView(style: .medium)
                indicator.color = parent.foregroundColor.withAlphaComponent(0.65)
                indicator.startAnimating()
                let label = UILabel()
                label.text = "正在加载下一章…"
                label.textColor = parent.foregroundColor.withAlphaComponent(0.65)
                label.font = .systemFont(ofSize: 13)
                let stack = UIStackView(arrangedSubviews: [indicator, label])
                stack.axis = .horizontal
                stack.spacing = 8
                stack.alignment = .center
                stack.translatesAutoresizingMaskIntoConstraints = false
                container.addSubview(stack)
                NSLayoutConstraint.activate([
                    stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                    stack.centerYAnchor.constraint(equalTo: container.centerYAnchor)
                ])
                view.addSubview(container)
                loadingFooter = container
                footer = container
            }
            view.contentInset.bottom = 64
            footer.frame = CGRect(x: 0, y: view.contentSize.height, width: view.bounds.width, height: 52)
        }

        func shouldDeferRender(in view: UITextView) -> Bool {
            parent.pageAnimation == 3 && (isUserDragging || view.isDragging || view.isDecelerating)
        }

        func invalidate() {
            isInvalidated = true
            progressPublication &+= 1
            layoutGeneration &+= 1
            resetAutoPage()
            // 收掉进行中的卷页与补完动画。
            tearDownNativeCurl()
            isTurningPage = false
            displayLink?.invalidate()
            displayLink = nil
        }

        func updateAutoRead(isRunning: Bool, isPaused: Bool, secondsPerScreen: Double) {
            let wasRunning = isAutoReading
            let wasPaused = isAutoReadPaused
            self.isAutoReading = isRunning
            isAutoReadPaused = isPaused
            self.secondsPerScreen = max(1, secondsPerScreen)
            if wasRunning && !isRunning {
                resetAutoPage()
            } else if !wasRunning && isRunning {
                didReachEnd = false
                lastTimestamp = 0
                eInkPageInterval = self.secondsPerScreen
            } else if isPaused || wasPaused != isPaused {
                lastTimestamp = 0
            }
        }

        func resetAutoReadForPageChange() {
            didReachEnd = false
            didReachStart = false
            lastReportedPage = nil
            didEnterPrevious = false
            didEnterContinuation = false
            pendingPreviousPosition = nil
            pendingContinuationPosition = nil
            resetAutoPage()
        }

        /// 把字符位置换算成 contentOffset。
        /// `alignToPage` 吸附到 pageHeight 的整数倍，章节起始强制落第一页。
        func scroll(to characterPosition: Int, in view: UITextView, alignToPage: Bool = true) {
            // 仿真模式直接按原文位置寻页，隐藏的 TextKit 视图不执行位置恢复。
            guard effectiveAnimation != 2, !view.text.isEmpty else { return }
            layoutGeneration &+= 1
            let generation = layoutGeneration
            // 从章首继续往回翻：调用方给的是 `Int.max`，语义是「落到本章最后一页」。
            // 之前一律按字符位置反算再吸附，末页附近的字符会落到末页之前的某一页
            // （实测「上一章 17 页，直接翻到了第 7 页」）。这里显式认这一档语义。
            let wantsLastPage = characterPosition >= Int.max - 1
            let prefix = characterPosition == 0 && parent.pageAnimation == 3
                ? currentSectionStart
                : renderedPrefixLength
            let location = ReaderPositionResolver.renderedLocation(
                position: characterPosition,
                prefixLength: prefix,
                renderedLength: view.text.utf16.count
            )
            DispatchQueue.main.async { [weak self] in
                guard let self, self.layoutGeneration == generation else { return }
                view.layoutManager.ensureLayout(for: view.textContainer)
                let limits = self.scrollLimits(for: view)
                var target: CGFloat
                if wantsLastPage {
                    // 末页页首由分页内核给，不靠字符位置反推。
                    target = self.pageStarts(for: view).last ?? limits.maximum
                } else {
                    let glyph = view.layoutManager.glyphIndexForCharacter(at: location)
                    var point = view.layoutManager.boundingRect(
                        forGlyphRange: NSRange(location: glyph, length: 1),
                        in: view.textContainer
                    ).origin
                    point.y += view.textContainerInset.top
                    target = point.y - view.adjustedContentInset.top
                }
                target = min(max(target, limits.minimum), limits.maximum)
                let starts = self.pageStarts(for: view)
                if alignToPage,
                   self.effectiveAnimation != 3,
                   starts.count > 1 {
                    // 章节起始固定落在第一页；往回翻落在最后一页；其余位置吸附到最近的
                    // 「行对齐页首」，于是跳转后页顶同样压在行边界上。
                    if wantsLastPage {
                        target = starts[starts.count - 1]
                    } else if characterPosition == 0 {
                        target = starts[0]
                    } else {
                        var nearest = starts[0]
                        for candidate in starts where abs(candidate - target) < abs(nearest - target) {
                            nearest = candidate
                        }
                        target = nearest
                    }
                }
                view.setContentOffset(CGPoint(x: 0, y: target), animated: false)
            }
        }

        private func readingViewportHeight(for view: UITextView) -> CGFloat {
            max(
                view.bounds.height
                    - view.adjustedContentInset.top
                    - view.adjustedContentInset.bottom
                    - view.textContainerInset.top
                    - view.textContainerInset.bottom,
                1
            )
        }


        private func scrollLimits(for view: UITextView) -> (minimum: CGFloat, maximum: CGFloat) {
            let minimum = -view.adjustedContentInset.top
            let maximum = max(
                view.contentSize.height - view.bounds.height + view.adjustedContentInset.bottom,
                minimum
            )
            return (minimum, maximum)
        }

        /// 行对齐的页首偏移（contentOffset 空间）。
        ///
        /// 对齐 legadoC `TextChapterLayout`：页只在「下一整行放不下」时切换，
        /// 页顶与页底因此永远压在行边界上，不会出现半截字。
        private func pageStarts(for view: UITextView) -> [CGFloat] {
            guard view.bounds.width > 1, view.bounds.height > 1, !view.text.isEmpty else { return [] }
            if effectiveAnimation == 2 {
                guard view.window != nil, !isInvalidated else { return [] }
                if isCurlTurning { return coreTextStartsCache }
                return coreTextPageStarts(in: view) ?? []
            }
            // 仿真翻页：页界由 CoreText 排版内核给。页码、页范围、卷页落地偏移都跟着它走，
            // 否则「页内栏显示总页数」与「卷页层实际页数」会是两套数。
            let key = "\(styleKey)|\(view.bounds.width)x\(view.bounds.height)|\(view.textContainerInset.top)|\(view.textContainerInset.bottom)|\(view.adjustedContentInset.top)|\(view.adjustedContentInset.bottom)|\(view.text.utf16.count)"
            if key == pageStartCacheKey, !pageStartCache.isEmpty { return pageStartCache }
            view.layoutManager.ensureLayout(for: view.textContainer)
            let glyphCount = view.layoutManager.numberOfGlyphs
            guard glyphCount > 0 else { return [] }
            let limits = scrollLimits(for: view)
            let viewport = readingViewportHeight(for: view)
            // textContainer 坐标 → contentOffset 坐标。
            let origin = view.textContainerInset.top - view.adjustedContentInset.top
            var lines: [(top: CGFloat, bottom: CGFloat)] = []
            lines.reserveCapacity(glyphCount)
            var glyph = 0
            while glyph < glyphCount {
                var range = NSRange(location: glyph, length: 0)
                let used = view.layoutManager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: &range)
                lines.append((used.minY, used.maxY))
                glyph += max(range.length, 1)
            }
            // 首页从可视区顶部起算（保留上边距与标题），后续页从行顶起算，
            // 与 legadoC 的「逐行累积 durY、换页点落在整行」一致。
            var starts: [CGFloat] = []
            var index = 0
            var pageStart = limits.minimum
            while index < lines.count {
                let clamped = min(max(pageStart, limits.minimum), limits.maximum)
                if let last = starts.last, clamped <= last + 0.5 {
                    // 单行高于视口等极端情况：至少前进一行，避免死循环。
                    break
                }
                starts.append(clamped)
                var next = index + 1
                while next < lines.count, lines[next].bottom + origin - pageStart <= viewport {
                    next += 1
                }
                index = next
                guard index < lines.count else { break }
                pageStart = lines[index].top + origin
            }
            if starts.isEmpty { starts = [limits.minimum] }
            pageStartCache = starts
            pageStartCacheKey = key
            return starts
        }

        /// 当前页序号（0 基）。
        private func pageIndex(for view: UITextView) -> Int {
            let starts = pageStarts(for: view)
            guard starts.count > 1 else { return 0 }
            let offset = view.contentOffset.y
            var index = 0
            for (candidate, start) in starts.enumerated() where offset >= start - 0.5 {
                index = candidate
            }
            return index
        }

        /// 卷页层的入场页号。
        ///
        /// 换章那一帧新章刚渲染、正文偏移还停在上一章的位置，按偏移反查页号会落到
        /// 本章中间。入场意图在换章那次 `updateUIView` 里记下：往回翻＝本章末页，
        /// 向后续翻＝本章第一页；两者都直接由分页结果给定，不再问偏移。
        private func landingIndex(in view: UITextView, starts: [CGFloat]) -> Int {
            guard !starts.isEmpty else { return 0 }
            if curlEntryIndex == nil {
                let position = curlRequestedPosition ?? parent.requestedPosition
                let entry = pageIndex(forCharacter: position)
                curlEntryIndex = entry
                curlCurrentIndex = entry
                curlRequestedPosition = nil
                ReaderChapterTrace.log("入场页 依据=位置 偏移=\(position) 页=\(entry + 1)/\(starts.count) 存档页=\(parent.requestedPage + 1)/\(parent.requestedPageCount)")
            }
            return min(max(curlCurrentIndex, 0), starts.count - 1)
        }

        private func pageIndex(forCharacter position: Int) -> Int {
            ReaderPositionResolver.pageIndex(position: position, startCharacters: curlStartCharacters)
        }

        /// 翻页落点；nil 表示已到首/末页。
        private func pageTarget(from direction: Int, in view: UITextView) -> CGFloat? {
            let starts = pageStarts(for: view)
            guard starts.count > 1 else { return nil }
            let next = pageIndex(for: view) + (direction > 0 ? 1 : -1)
            guard starts.indices.contains(next) else { return nil }
            return starts[next]
        }

        private func pageMetrics(for view: UITextView) -> (current: Int, total: Int) {
            let pageHeight = readingViewportHeight(for: view)
            // 仿真模式：页码只认卷页层的当前页，不按量尺的偏移反推。
            // 量尺常在别的页上（日志里卷页层 27/28 与量尺 8/28 同时出现），
            // 按它报页码会让 `onPageChanged` 拿错页号频繁存进度。
            if usesCurlAsProgressAuthority {
                let count = curlStartCharacters.count
                return (min(max(curlCurrentIndex, 0), max(count - 1, 0)) + 1, max(count, 1))
            }
            if parent.pageAnimation == 3, currentBodyEnd > currentSectionStart {
                view.layoutManager.ensureLayout(for: view.textContainer)
                let glyphCount = view.layoutManager.numberOfGlyphs
                if glyphCount > 0 {
                    let first = min(view.layoutManager.glyphIndexForCharacter(at: currentSectionStart), glyphCount - 1)
                    let last = min(view.layoutManager.glyphIndexForCharacter(at: currentBodyEnd - 1), glyphCount - 1)
                    let start = view.layoutManager.boundingRect(
                        forGlyphRange: NSRange(location: first, length: 1), in: view.textContainer
                    ).minY + view.textContainerInset.top - view.adjustedContentInset.top
                    let end = view.layoutManager.boundingRect(
                        forGlyphRange: NSRange(location: last, length: 1), in: view.textContainer
                    ).maxY + view.textContainerInset.top - view.adjustedContentInset.top
                    let total = max(Int(ceil((end - start) / pageHeight)), 1)
                    let position = max(view.contentOffset.y - start, 0)
                    return (min(Int(floor(position / pageHeight)) + 1, total), total)
                }
            }
            let starts = pageStarts(for: view)
            guard starts.count > 1 else { return (1, 1) }
            return (pageIndex(for: view) + 1, starts.count)
        }

        private func renderedCharacter(at offset: CGPoint, in view: UITextView) -> Int {
            guard !view.text.isEmpty else { return 0 }
            let point = CGPoint(
                x: view.textContainerInset.left + 1,
                y: offset.y + view.textContainerInset.top + 1
            )
            let glyphCount = view.layoutManager.numberOfGlyphs
            guard glyphCount > 0 else { return 0 }
            let glyph = min(view.layoutManager.glyphIndex(for: point, in: view.textContainer), glyphCount - 1)
            let character = view.layoutManager.characterIndexForGlyph(at: glyph)
            return min(max(character, 0), view.text.utf16.count)
        }

        func contentCharacter(at offset: CGPoint, in view: UITextView) -> Int {
            let character = renderedCharacter(at: offset, in: view)
            return min(max(character - renderedPrefixLength, 0), parent.text.utf16.count)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            // 从入场到拆层始终只认纸页，隐藏视图也不能触发进度保存。
            guard !usesCurlAsProgressAuthority, !isInvalidated else { return }
            guard !isRenderingAutoPage, !isApplyingContent else { return }
            guard let view = scrollView as? UITextView, !view.text.isEmpty else { return }
            if parent.isLoadingNextChapter, !didRequestLoadingCancellation {
                let textBottom = max(
                    view.contentSize.height - view.bounds.height
                        + view.adjustedContentInset.bottom - view.contentInset.bottom,
                    -view.adjustedContentInset.top
                )
                if view.contentOffset.y < textBottom - 44 {
                    didRequestLoadingCancellation = true
                    DispatchQueue.main.async { [weak self] in self?.parent.onCancelNextLoading() }
                }
            }
            if isUserDragging {
                let delta = scrollView.contentOffset.y - lastDragOffsetY
                if abs(delta) > 0.5 { dragDirection = delta > 0 ? 1 : -1 }
                lastDragOffsetY = scrollView.contentOffset.y
            }
            let metrics = pageMetrics(for: view)
            reportPage(in: view)
            if let lastReportedPage, lastReportedPage != metrics.current {
                self.lastReportedPage = metrics.current
                let generation = layoutGeneration
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.layoutGeneration == generation else { return }
                    self.parent.onPageChanged()
                }
            } else if lastReportedPage == nil {
                lastReportedPage = metrics.current
            }
            // 仿真翻页：位置、章界、进度一律由卷页层给，隐藏的量尺到此为止。
            //
            // 底下那个 `UITextView` 只是分页量尺：布局重建、重排、`scroll(to:)` 都会挪它，
            // 它停的位置与读者眼前那一页常常不是同一页（真机日志里「卷页层 27/28，
            // 隐藏视图 8/28」同时出现）。它一旦参与判定，会同时污染三处：
            //   ① 末尾把它的偏移写回 `readerPosition` → 存档记成「量尺停在哪」；
            //   ② 跨段判定误触发 `onEnteredPrevious / onEnteredContinuation` →
            //      仿真模式外层会 `readerPosition = 0`，存档直接退化成章首；
            //   ③ `lastReportedPage` 与读者实际所在页不一致 → 反复存进度。
            // 页码展示已经在 `pageMetrics` 里改认卷页层当前页，这里直接收工。
            guard !usesCurlAsProgressAuthority else { return }
            let contentCharacter = contentCharacter(at: scrollView.contentOffset, in: view)
            let renderedCharacter = renderedCharacter(at: scrollView.contentOffset, in: view)
            if let previousBodyStart,
               let previousBodyEnd,
               renderedCharacter < currentSectionStart {
                pendingContinuationPosition = nil
                let position = min(max(renderedCharacter - previousBodyStart, 0), max(previousBodyEnd - previousBodyStart - 1, 0))
                if isUserDragging || view.isDecelerating {
                    pendingPreviousPosition = position
                    return
                }
                guard !didEnterPrevious else { return }
                didEnterPrevious = true
                let generation = layoutGeneration
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.layoutGeneration == generation else { return }
                    self.parent.onEnteredPrevious(position)
                }
                return
            }
            if let continuationSectionStart,
               let continuationBodyStart,
               renderedCharacter >= continuationSectionStart {
                pendingPreviousPosition = nil
                let position = max(renderedCharacter - continuationBodyStart, 0)
                if isUserDragging || view.isDecelerating {
                    pendingContinuationPosition = position
                    return
                }
                guard !didEnterContinuation else { return }
                didEnterContinuation = true
                let generation = layoutGeneration
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.layoutGeneration == generation else { return }
                    self.parent.onEnteredContinuation(position)
                }
                return
            }
            pendingPreviousPosition = nil
            pendingContinuationPosition = nil
            guard contentCharacter != parent.readerPosition else { return }
            let generation = layoutGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.layoutGeneration == generation else { return }
                self.parent.readerPosition = contentCharacter
            }
        }

        /// 正文几何 debug 开关（设置 → 其他设置 → 诊断）。
        private var debugContentEnabled: Bool {
            UserDefaults.standard.bool(forKey: "readerDebugOverlay")
        }

        /// 正文几何 debug：把「可排版区四条边 / 页首落点 / 关键数值」直接画在正文上，并写一行日志。
        ///
        /// 上一次「正文整体上移」之所以返工，就是因为日志里看不到 contentInsets 的实际取值，
        /// 只能读代码推理，结果把常量当成了变量。这一层把决定观感的量一次摊开：
        /// 正文视图 frame 与 contentOffset、textContainerInset、正文区到屏幕四边的距离、
        /// 页首偏移、当前页号。红框 = 可排版区，绿线 = 页首落点，左上角文字 = 上述数值。
        func updateContentDebug(in view: UITextView) {
            guard debugContentEnabled else {
                debugOverlayView?.removeFromSuperview()
                debugOverlayView = nil
                debugOverlaySignature = ""
                debugLogKey = ""
                return
            }
            guard let host = view.superview,
                  view.bounds.width > 1, view.bounds.height > 1,
                  !view.text.isEmpty else { return }
            let starts = pageStarts(for: view)
            let screenInsets = pageContentInsets(in: view)
            let current = starts.isEmpty ? 0 : min(pageIndex(for: view), max(starts.count - 1, 0))
            let pageTop = starts.isEmpty ? 0 : starts[current]
            let signature = "\(view.frame)|\(view.contentOffset.y)|\(screenInsets.top)|\(starts.count)|\(current)"
            if signature != debugOverlaySignature || debugOverlayView?.superview !== host {
                debugOverlaySignature = signature
                let overlay: UIView
                if let existing = debugOverlayView, existing.superview === host {
                    overlay = existing
                } else {
                    debugOverlayView?.removeFromSuperview()
                    let created = UIView(frame: view.frame)
                    created.isUserInteractionEnabled = false
                    created.backgroundColor = .clear
                    host.addSubview(created)
                    debugOverlayView = created
                    overlay = created
                }
                overlay.frame = view.frame
                overlay.subviews.forEach { $0.removeFromSuperview() }
                let inset = view.textContainerInset
                let content = CGRect(
                    x: inset.left,
                    y: inset.top,
                    width: max(view.bounds.width - inset.left - inset.right, 1),
                    height: max(view.bounds.height - inset.top - inset.bottom, 1)
                )
                let edges = [
                    CGRect(x: content.minX, y: content.minY, width: content.width, height: 1),
                    CGRect(x: content.minX, y: content.maxY, width: content.width, height: 1),
                    CGRect(x: content.minX, y: content.minY, width: 1, height: content.height),
                    CGRect(x: content.maxX, y: content.minY, width: 1, height: content.height)
                ]
                for rect in edges {
                    let edge = UIView(frame: rect)
                    edge.backgroundColor = UIColor.systemRed.withAlphaComponent(0.85)
                    overlay.addSubview(edge)
                }
                if !starts.isEmpty {
                    let marker = UIView(frame: CGRect(x: 0, y: pageTop - view.contentOffset.y, width: view.bounds.width, height: 1.5))
                    marker.backgroundColor = UIColor.systemGreen.withAlphaComponent(0.9)
                    overlay.addSubview(marker)
                }
                let label = UILabel(frame: CGRect(x: 6, y: 2, width: max(view.bounds.width - 12, 10), height: 64))
                label.numberOfLines = 4
                label.font = .monospacedSystemFont(ofSize: 9, weight: .regular)
                label.textColor = UIColor.systemBlue
                label.backgroundColor = UIColor.white.withAlphaComponent(0.55)
                label.text = "frame=\(Int(view.frame.minX)),\(Int(view.frame.minY)) \(Int(view.bounds.width))x\(Int(view.bounds.height)) offset=\(Int(view.contentOffset.y))\n"
                    + "inset t=\(Int(inset.top)) b=\(Int(inset.bottom)) l=\(Int(inset.left)) r=\(Int(inset.right))\n"
                    + "屏边距 t=\(Int(screenInsets.top)) b=\(Int(screenInsets.bottom)) l=\(Int(screenInsets.left)) r=\(Int(screenInsets.right))\n"
                    + "页=\(current + 1)/\(max(starts.count, 1)) 页首=\(Int(pageTop)) 视口=\(Int(readingViewportHeight(for: view)))"
                overlay.addSubview(label)
            }
            let logKey = "\(Int(view.bounds.width))x\(Int(view.bounds.height))|\(Int(screenInsets.top))|\(starts.count)|\(current)"
            if logKey != debugLogKey {
                debugLogKey = logKey
                ReaderChapterTrace.log("正文几何 frame=(\(Int(view.frame.minX)),\(Int(view.frame.minY))) size=(\(Int(view.bounds.width))x\(Int(view.bounds.height))) offset=\(Int(view.contentOffset.y)) inset=\(Int(view.textContainerInset.top))/\(Int(view.textContainerInset.bottom)) 屏边距=\(Int(screenInsets.top))/\(Int(screenInsets.bottom)) 页=\(current + 1)/\(max(starts.count, 1)) 页首=\(Int(pageTop)) 视口=\(Int(readingViewportHeight(for: view)))")
            }
        }

        func reportPage(in view: UITextView) {
            guard !isInvalidated, !isUpdatingView else { return }
            if effectiveAnimation == 2, nativeCurl == nil { return }
            guard view.bounds.width > 0, view.bounds.height > 0 else { return }
            let metrics = pageMetrics(for: view)
            updateContentDebug(in: view)
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-uiPagingDiagnostics") {
                view.accessibilityLabel = "bounds=\(view.bounds.size) content=\(view.contentSize) used=\(view.layoutManager.usedRect(for: view.textContainer)) mode=\(parent.pageAnimation) pages=\(metrics.total)"
            }
            #endif
            guard metrics.current != parent.currentPage || metrics.total != parent.totalPages else { return }
            let generation = layoutGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.layoutGeneration == generation else { return }
                self.parent.currentPage = metrics.current
                self.parent.totalPages = metrics.total
            }
        }

        func reportPageRanges(in view: UITextView) {
            guard !isInvalidated, !isUpdatingView else { return }
            if effectiveAnimation == 2 {
                guard nativeCurl != nil, !curlStartCharacters.isEmpty else { return }
                let length = parent.text.utf16.count
                let ranges = curlStartCharacters.enumerated().map { index, start in
                    let end = index + 1 < curlStartCharacters.count ? curlStartCharacters[index + 1] : length
                    return NSRange(location: min(start, length), length: max(0, min(end, length) - start))
                }
                guard ranges != parent.pageRanges else { return }
                let generation = layoutGeneration
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.isInvalidated, self.layoutGeneration == generation else { return }
                    self.parent.pageRanges = ranges
                }
                return
            }
            guard view.bounds.width > 0, view.bounds.height > 0 else { return }
            if parent.pageAnimation == 3 {
                let ranges = parent.text.isEmpty
                    ? []
                    : [NSRange(location: 0, length: parent.text.utf16.count)]
                guard ranges != parent.pageRanges else { return }
                DispatchQueue.main.async { [weak self] in self?.parent.pageRanges = ranges }
                return
            }
            guard !view.text.isEmpty else { return }
            view.layoutManager.ensureLayout(for: view.textContainer)
            let pageHeight = readingViewportHeight(for: view)
            // 按行对齐的页首取范围：页码统计与翻页落点共用同一套边界。
            let starts = pageStarts(for: view)
            let origin = view.textContainerInset.top - view.adjustedContentInset.top
            var ranges: [NSRange] = []
            for offset in starts {
                let rect = CGRect(
                    x: 0,
                    y: max(0, offset - origin),
                    width: max(view.textContainer.size.width, 1),
                    height: pageHeight
                )
                let glyphRange = view.layoutManager.glyphRange(
                    forBoundingRect: rect,
                    in: view.textContainer
                )
                guard glyphRange.length > 0 else { continue }
                let characterRange = view.layoutManager.characterRange(
                    forGlyphRange: glyphRange,
                    actualGlyphRange: nil
                )
                let start = max(characterRange.location - renderedPrefixLength, 0)
                let end = min(
                    characterRange.location + characterRange.length - renderedPrefixLength,
                    parent.text.utf16.count
                )
                guard end > start else { continue }
                let range = NSRange(location: start, length: end - start)
                if ranges.last?.location == range.location,
                   ranges.last?.length == range.length { continue }
                ranges.append(range)
            }
            if ranges.isEmpty {
                guard pageRangeRetryCount < 10 else { return }
                pageRangeRetryCount += 1
                let generation = layoutGeneration
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    guard let self, self.layoutGeneration == generation else { return }
                    self.reportPageRanges(in: view)
                }
                return
            }
            pageRangeRetryCount = 0
            guard ranges != parent.pageRanges else { return }
            let generation = layoutGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.layoutGeneration == generation else { return }
                self.parent.pageRanges = ranges
            }
        }

        func resetPageRangeRetry() {
            pageRangeRetryCount = 0
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            isUserDragging = true
            lastDragOffsetY = scrollView.contentOffset.y
            dragDirection = 0
            didReachEnd = false
            didReachStart = false
        }
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if parent.pageAnimation == 3, let view = scrollView as? UITextView {
                triggerChapterBoundaryIfNeeded(in: view)
            }
            if !decelerate {
                isUserDragging = false
                flushPendingChapterTransition()
                requestDeferredRenderIfNeeded()
            }
        }
        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            if parent.pageAnimation == 3, let view = scrollView as? UITextView {
                triggerChapterBoundaryIfNeeded(in: view)
            }
            isUserDragging = false
            flushPendingChapterTransition()
            requestDeferredRenderIfNeeded()
        }

        private func requestDeferredRenderIfNeeded() {
            guard needsDeferredRender else { return }
            needsDeferredRender = false
            DispatchQueue.main.async { [weak self] in self?.parent.onDeferredRender() }
        }

        private func flushPendingChapterTransition() {
            let previous = pendingPreviousPosition
            let continuation = pendingContinuationPosition
            pendingPreviousPosition = nil
            pendingContinuationPosition = nil
            let generation = layoutGeneration
            if let previous, !didEnterPrevious {
                didEnterPrevious = true
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.layoutGeneration == generation else { return }
                    self.parent.onEnteredPrevious(previous)
                }
            } else if let continuation, !didEnterContinuation {
                didEnterContinuation = true
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.layoutGeneration == generation else { return }
                    self.parent.onEnteredContinuation(continuation)
                }
            }
        }

        private func triggerChapterBoundaryIfNeeded(in view: UITextView) {
            let starts = pageStarts(for: view)
            guard starts.count > 1 else { return }
            let index = pageIndex(for: view)
            let atEnd = index >= starts.count - 1
            let atStart = index <= 0
            if atEnd, dragDirection > 0, continuationSectionStart == nil, !didReachEnd {
                didReachEnd = true
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                parent.onReachedEnd(contentCharacter(at: view.contentOffset, in: view))
            } else if atStart, dragDirection < 0, previousBodyStart == nil, !didReachStart {
                didReachStart = true
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                parent.onReachedStart(contentCharacter(at: view.contentOffset, in: view))
            }
        }

        @objc private func tapped(_ gesture: UITapGestureRecognizer) {
            guard let view = textView, gesture.state == .ended else { return }
            let point = gesture.location(in: view)
            // UIScrollView changes its bounds origin as content scrolls, and
            // gesture locations use that content coordinate space. Convert
            // back to viewport coordinates before dividing the visible screen
            // into the 3×3 tap grid.
            let viewportX = point.x - view.bounds.minX
            let viewportY = point.y - view.bounds.minY
            performTap(
                column: min(max(Int(viewportX / max(view.bounds.width / 3, 1)), 0), 2),
                row: min(max(Int(viewportY / max(view.bounds.height / 3, 1)), 0), 2)
            )
        }

        /// 3×3 点击区分派。原生卷页层盖住整屏后收不到正文视图的点击，
        /// 由卷页层把自己的落点换算成 column / row 转交到这里。
        private func performTap(column: Int, row: Int) {
            let index = row * 3 + column
            let action = index == 4
                ? 0
                : (parent.clickActions.indices.contains(index) ? parent.clickActions[index] : 0)

            if parent.pageAnimation == 3, action == 1 || action == 2 {
                return
            }
            switch action {
            case 1: turnPage(1)
            case 2: turnPage(-1)
            case -1: break
            default: parent.onTapAction(action)
            }
        }

        @objc private func swiped(_ gesture: UISwipeGestureRecognizer) {
            turnPage(gesture.direction == .left ? 1 : -1)
        }

        private func turnPage(_ direction: Int) {
            guard !isTurningPage, let view = textView else { return }
            if isAutoReading { resetAutoReadForPageChange() }
            // 落点取行对齐的页首：页顶页底都不会切到半截字。
            guard let target = pageTarget(from: direction, in: view) else {
                if direction < 0 {
                    parent.onReachedStart(contentCharacter(at: view.contentOffset, in: view))
                } else {
                    parent.onReachedEnd(contentCharacter(at: view.contentOffset, in: view))
                }
                return
            }
            isTurningPage = true
            switch parent.isEInkMode ? 4 : parent.pageAnimation {
            case 4:
                view.setContentOffset(CGPoint(x: 0, y: target), animated: false)
                isTurningPage = false
            case 0:
                let transition = CATransition()
                transition.duration = 0.3
                transition.type = direction > 0 ? .reveal : .moveIn
                transition.subtype = direction > 0 ? .fromRight : .fromLeft
                view.layer.add(transition, forKey: "reader-cover")
                view.setContentOffset(CGPoint(x: 0, y: target), animated: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.31) { [weak self] in self?.isTurningPage = false }
            case 1:
                let transition = CATransition()
                transition.duration = 0.3
                transition.type = .push
                transition.subtype = direction > 0 ? .fromRight : .fromLeft
                view.layer.add(transition, forKey: "reader-slide")
                view.setContentOffset(CGPoint(x: 0, y: target), animated: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.31) { [weak self] in self?.isTurningPage = false }
            case 2:
                // 原生卷页：折痕位置、掀起角度、纸背高光全由系统的 curl mesh 生成。
                // 只有卷页层还没装上（首帧、视口未定）时才回退到直接改偏移。
                isTurningPage = false
                if nativeCurl == nil { syncNativeCurl(in: view) }
                if nativeCurl != nil {
                    // 卷页层在场：翻页完全交给它（转场中的连点由它自己忽略）。
                    _ = nativeCurl?.turn(forward: direction > 0)
                    return
                }
                view.setContentOffset(CGPoint(x: 0, y: target), animated: false)
            default:
                view.setContentOffset(CGPoint(x: 0, y: target), animated: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self] in self?.isTurningPage = false }
            }
        }

        // MARK: - 原生卷页层

        /// 整块屏幕在宿主坐标系里的矩形：卷页层的坐标空间。
        ///
        /// 取窗口 bounds 而不是宿主 bounds —— 宿主是安全区里的那块矩形，比屏幕矮
        /// 一截，用它卷出来的纸也就矮一截（顶部状态栏、底部 Home 指示条两条不在纸上）。
        private func screenRect(for view: UITextView, in host: UIView) -> CGRect {
            guard let window = view.window else { return host.bounds }
            return host.convert(window.bounds, from: window)
        }

        /// 可读区域取窗口安全区，导航栏/标签栏转场产生的临时正文高度不参与计算。
        private func curlViewport(in view: UITextView) -> ReaderCurlViewport {
            // 调用方等 window 就绪后才建立页表，不使用首帧 UITextView.bounds 兜底。
            let window = view.window!
            return ReaderCurlViewport(
                windowBounds: window.bounds,
                safeAreaInsets: window.safeAreaInsets,
                maximumWidth: UIDevice.current.userInterfaceIdiom == .pad ? 760 : .greatestFiniteMagnitude
            )
        }

        private func pageContentInsets(in view: UITextView) -> UIEdgeInsets {
            guard let window = view.window else { return view.textContainerInset }
            if effectiveAnimation == 2 {
                return curlViewport(in: view).contentInsets(padding: view.textContainerInset)
            }
            let text = view.convert(view.bounds, to: window)
            let inset = view.textContainerInset
            return UIEdgeInsets(
                top: text.minY + inset.top, left: text.minX + inset.left,
                bottom: max(0, window.bounds.maxY - text.maxY) + inset.bottom,
                right: max(0, window.bounds.maxX - text.maxX) + inset.right
            )
        }

        /// 卷页层在场时清空宿主正文视图的字色，避免它透过透明底色与 CoreText 页重叠。
        ///
        /// `textColor` 只影响绘制，不改 `textContainer` 与 `layoutManager` 的分页结果：
        /// `pageStarts` / 页范围 / 卷页落地偏移仍照旧从这个视图量出来。
        private func hideHostTextIfNeeded(in view: UITextView) {
            guard nativeCurlTextHiddenView !== view else { return }
            if nativeCurlTextHiddenView !== view, let previous = nativeCurlTextHiddenView {
                if let color = nativeCurlTextHiddenColor { previous.textColor = color }
            }
            nativeCurlTextHiddenColor = view.textColor
            nativeCurlTextHiddenView = view
            view.textColor = .clear
        }

        /// 装/拆原生卷页层：只有仿真模式（case 2）且正在分页阅读时才存在。
        ///
        /// 层插在正文视图正上方并铺满整块屏幕，页内容是 CoreText 逐行排好的一页，
        /// 卷曲过程中文字仍是矢量的；点击由卷页层转交 `performTap(column:row:)`。
        func syncNativeCurl(in view: UITextView) {
            guard !isInvalidated, !isUpdatingView, !isApplyingContent, !isSyncingCurl else { return }
            isSyncingCurl = true
            defer { isSyncingCurl = false }
            guard effectiveAnimation == 2, !view.text.isEmpty else {
                tearDownNativeCurl()
                return
            }
            guard let window = view.window, window.bounds.width > 1, window.bounds.height > 1 else { return }
            // 手势进行中保留正在显示的页表及其字符坐标，结束/取消后再同步。
            guard !isCurlTurning else { return }
            // 宿主取正文视图的直接父视图（SwiftUI 容器），不挂窗口：
            // 阅读器的菜单/工具栏是同一窗口里更早创建的视图，卷页层一旦常驻就会
            // 把它们永久压在下面 —— 点开菜单会「没反应」。挂在正文视图的父视图上，
            // 卷页层仍是正文区最上层，而菜单/工具栏在它之上，照常可点。
            guard let host = view.superview ?? view.window,
                  host.bounds.width > 1, host.bounds.height > 1 else {
                tearDownNativeCurl()
                return
            }
            // 纸比宿主大一圈：宿主是安全区里那块矩形，纸是整块屏幕。宿主一旦裁剪
            // 子视图，顶部状态栏那条与底部 Home 指示条那条就被切回去，改了半天
            // 等于没改。这里显式放开，拆层时还原原值。
            if host.clipsToBounds {
                nativeCurlClipHost = host
                nativeCurlClipHostOriginal = true
                host.clipsToBounds = false
            }
            let previousStarts = curlStartCharacters
            let anchor = settledCurlProgress
            let starts = pageStarts(for: view)
            guard !starts.isEmpty else {
                tearDownNativeCurl()
                return
            }
            // 纸上的正文由 CoreText 逐页画；底下那个正文视图若还留着自己的字，主题底色
            // 一旦变透明（用背景图时），底层 TextKit 那份就透出来 —— 实测「开背景图后
            // 正文重影，重影像系统字体」。这里只把字色清掉，布局与 layoutManager 一点
            // 不动（分页还要靠它量行边界），拆层时还原。
            hideHostTextIfNeeded(in: view)
            let signature = nativeCurlSignature(in: view)
            // 分页层、绘制层、卷页层共用同一份结果：页内容与「正文宽度」都来自这里。
            let built = curlContent(in: view)
            let hasAnyGlyph = built.sheets.contains { !$0.lines.isEmpty }
            // 空页表（换章那一帧正文还没到）不许覆盖已经在屏上的页：
            // 真机日志里这一下会把卷页层推成「1 页」，紧跟着再换成新章，观感就是闪一下。
            if !hasAnyGlyph, nativeCurl != nil {
                return
            }
            guard !built.sheets.isEmpty else {
                tearDownNativeCurl()
                return
            }
            // 入场页号由分页结果显式给定，不从上一章遗留的正文偏移反推。
            // 真正重排时用原文锚点重新定位，旧页号不能覆盖重算出的落点。
            if curlRequestedPosition == nil,
               let active = activeDeckLocation, active.chapterIndex == parent.chapterIndex,
               let anchor, anchor.chapterIndex == parent.chapterIndex,
               previousStarts != curlStartCharacters {
                let page = pageIndex(forCharacter: anchor.position)
                activeDeckLocation = ReaderDeckLocation(chapterIndex: parent.chapterIndex, pageIndex: page)
                curlCurrentIndex = page
                curlEntryIndex = page
            }
            let target = landingIndex(in: view, starts: starts)
            // 整份页序：上一章 + 本章 + 下一章。相邻章没就绪时自动退化成单章卷。
            let deck = curlDeck(in: view, built: built)
            curlDeck = deck
            // 页序里的落点：刚从相邻章拖过来就用那一页的章内页号，否则用本章入场页。
            //
            // 锚点只在「那一章的正文真的到手」时才消费：正文没到之前把锚点用掉，读者落下的
            // 那一页就丢了，`landingIndex` 随后会按 `requestedPosition <= 0` 把页号清成首页
            // （真机实测「掀起是尾页、落下是首页」）。
            // 记账坐标只在「页序仍然覆盖它」时有效：菜单跳章会一次跨好几章，那时
            // 旧坐标不在新页序里，必须作废重算，否则屏上会一直停在旧页。
            if let active = activeDeckLocation,
               abs(active.chapterIndex - parent.chapterIndex) > 1 {
                activeDeckLocation = nil
            }
            // 落点只认页序坐标，三条分支互斥：
            //   ① 有记账坐标且页序里真有这一页 → 用它（跨帧有效，晋升后仍是同一页）；
            //   ② 有记账坐标但页序里还没有（相邻章正文未到）→ 屏上这一页继续留着，
            //      下一帧正文到位后按同一个坐标落位。绝不退回 `requestedPosition` 反推 ——
            //      那条路在 `<= 0` 时直接给出首页，正是「掀起是尾页、落下是首页」的成因；
            //   ③ 没有记账坐标（初次打开、菜单跳章）→ 用入场页号初始化一次。
            let focus: ReaderDeckLocation
            if let active = activeDeckLocation, let landed = deck.index(of: active) {
                focus = active
                let page = deck.slot(at: landed)?.location.pageIndex ?? curlCurrentIndex
                curlCurrentIndex = page
                curlEntryIndex = page
            } else if activeDeckLocation != nil {
                return
            } else {
                focus = ReaderDeckLocation(chapterIndex: parent.chapterIndex, pageIndex: target)
                activeDeckLocation = focus
                curlEntryIndex = target
                curlCurrentIndex = target
            }
            if let existing = nativeCurl, nativeCurlHost?.superview === host {
                // 每次同步都先把整屏容器重新对准窗口：键盘收起、分屏尺寸变化后宿主会
                // 挪位置，容器不跟着挪，纸就歪在屏幕中间。
                if let container = nativeCurlHost {
                    let rect = screenRect(for: view, in: host)
                    if container.frame != rect { container.frame = rect }
                }
                // 页内栏的时间每秒都在变：只刷文案，不进整卷指纹、不重建页面。
                existing.refreshBars(header: parent.headerBar, footer: parent.footerBar)
                // 换章 / 重新分页都走同一个口：卷页控制器常驻，只换页面集合并按方向卷过去。
                // 拆层重建会闪一下重新加载（观感就是「刷新了一下」）。
                let landed = existing.update(
                    deck: deck,
                    focus: focus,
                    chapterToken: curlChapterToken,
                    style: built.style
                )
                // 卷页层是「当前页」的唯一权威：绝对下标只在页序内部使用，页码与落地
                // 偏移一律换算回「章内页号」—— 页序把相邻章拼进来之后，绝对下标一跨章
                // 就等于整本进度，直接当页码会显示成读者对不上的数。
                let landedPage = deck.slot(at: landed)?.location.pageIndex ?? landed
                curlCurrentIndex = landedPage
                curlEntryIndex = landedPage
                nativeCurlPageCount = deck.count
                nativeCurlSignatureValue = signature
                publishCurlProgress(location: focus, deferred: true)
                return
            }
            tearDownNativeCurl()
            // tearDown 会把正文视图的字色还原，重建这一路要再隐藏一次，否则底色透明的
            // 主题下底层 TextKit 那份字又透出来，重影照旧。
            hideHostTextIfNeeded(in: view)
            let controller = ReaderNativeCurlController(
                pages: built.sheets,
                chapterToken: curlChapterToken,
                chapterTitle: parent.titleMode == 2 ? nil : parent.title,
                startIndex: target,
                style: built.style
            )
            controller.onIndexChange = { [weak self, weak view] index in
                guard let self, let view else { return }
                // 页序绝对下标 → 本章章内页号：落地偏移只认章内页号。
                // 换章后页表已经换了一份，必须按当前页表重新取，不能吃旧闭包的 starts。
                guard let slot = self.curlDeck?.slot(at: index) else { return }
                guard slot.location.chapterIndex == self.parent.chapterIndex else {
                    // 跨章落地：正文偏移那一份还属于旧章，不能拿来对齐新章；但页坐标必须记下。
                    //
                    // 以前这里直接 return，于是「翻到上一章尾页」那一拍既不记页坐标、
                    // 随后 `onEnteredPrevious` 又把字符偏移写成 0 —— 存档退化成
                    // 「上一章第 1 页、偏移 0」，重进只能落章首（日志 (11) 第 59 行
                    // `入场页(存档页号) 页=1/15 偏移=18` 就是这份坏存档）。
                    self.reportSettled(location: slot.location)
                    return
                }
                self.commitNativeCurl(index: slot.location.pageIndex, starts: self.coreTextStartsCache, in: view)
            }
            controller.onTransitionEnd = { [weak self] in
                DispatchQueue.main.async {
                    guard let self, !self.isInvalidated else { return }
                    self.needsDeferredRender = false
                    self.parent.onDeferredRender()
                }
            }
            // 落在相邻章：交给外层晋升该章（页序拼接的落地闭环）。
            controller.onDeckCommit = { [weak self] location in
                self?.handleDeckCommit(location)
            }
            controller.onReachEnd = { [weak self, weak view] in
                guard let self, let view else { return }
                self.dragDirection = 1
                // 交给外层的边界位置必须是读者眼前这一页的首字符，不能读量尺的偏移。
                self.parent.onReachedEnd(self.currentCurlCharacter(in: view))
            }
            controller.onReachStart = { [weak self, weak view] in
                guard let self, let view else { return }
                self.dragDirection = -1
                self.parent.onReachedStart(self.currentCurlCharacter(in: view))
            }
            controller.onTap = { [weak self] point in
                guard let self, let host = self.nativeCurlHost, host.bounds.width > 1 else { return }
                self.performTap(
                    column: min(max(Int(point.x / max(host.bounds.width / 3, 1)), 0), 2),
                    row: min(max(Int(point.y / max(host.bounds.height / 3, 1)), 0), 2)
                )
            }
            // 首次挂载就交付完整页序，避免首个手势按单章下标读取三章页表。
            _ = controller.update(deck: deck, focus: focus, chapterToken: curlChapterToken, style: built.style)
            // 一页纸 = 整块屏幕，不再是正文视图那一块矩形。
            //
            // 卷页层与正文视图同尺寸时，翻起来的纸只覆盖正文那片区域：顶部状态栏
            // 那条与底部 Home 指示条那条留在原地静止不动（实测观感就是「只有屏幕
            // 中间在翻页」），页脚也永远停在屏幕物理底边之上。改成窗口矩形换算到
            // 宿主坐标之后，纸是整块屏幕；正文区在纸上的位置由 `pageContentInsets`
            // 另行换算 —— 行宽、行高、内边距一个不动，分页不会因此改变。
            let container = UIView(frame: screenRect(for: view, in: host))
            container.backgroundColor = parent.backgroundColor
            // 尺寸跟着窗口走：旋转 / 分屏时窗口 bounds 变了要重新对齐，不能按父视图
            // 自动伸缩（父视图是安全区内的矩形，不是屏幕）。
            container.autoresizingMask = []
            // 从正文视图向上找宿主控制器：宿主可能是窗口，链上没有控制器。
            let parentController = view.readerEnclosingViewController()
                ?? host.readerEnclosingViewController()
                ?? host.window?.rootViewController
            parentController?.addChild(controller)
            container.addSubview(controller.view)
            controller.view.frame = container.bounds
            controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            // 插在正文视图正上方，而不是 addSubview 到容器顶层：
            // 阅读器的菜单 / 工具栏若与正文同层且更上层，addSubview 会把卷页层压到
            // 它们上面，点开菜单就「没反应」。插在正文正上方，卷页层盖住正文，
            // 菜单照常显示与点击。
            host.insertSubview(container, aboveSubview: view)
            controller.didMove(toParent: parentController)
            nativeCurlHost = container
            nativeCurl = controller
            curlCurrentIndex = focus.pageIndex
            curlEntryIndex = focus.pageIndex
            activeDeckLocation = focus
            nativeCurlPageCount = starts.count
            nativeCurlSignatureValue = signature
            notifyCurlPublished(true)
            publishCurlProgress(location: focus, deferred: true)
        }

        // MARK: - 分页 / 绘制同源

        /// 正文字体名与字重档：字体只在一个地方解析，分页量宽与绘制取字体都走同一个名字。
        private func curlFontNames() -> (regular: String, bold: String, weightLevel: Int) {
            let size = CGFloat(max(5, parent.fontSize))
            let name = ReaderFontStore.font(at: parent.fontPath, size: size, weight: parent.fontWeight)?.fontName
            let regular = (name?.isEmpty == false) ? (name ?? "PingFangSC-Regular") : "PingFangSC-Regular"
            // 0 常规 / 1 粗 / 2 细（设置里那一档）→ 字重档：<=0 细、>=2 粗。
            let weightLevel: Int
            switch parent.fontWeight {
            case 1: weightLevel = 2
            case 2: weightLevel = 0
            default: weightLevel = 1
            }
            return (regular, "", weightLevel)
        }

        /// 排版参数。可用宽度就是「容器宽 − 左右内边距」，绘制层直接吃这一个数。
        private func curlLayout(in view: UITextView) -> ReaderPaginationLayout {
            let names = curlFontNames()
            let insets = view.textContainerInset
            let titleScale = parent.fontSize > 0 ? CGFloat(parent.titleSize) / CGFloat(parent.fontSize) : 1.2
            return ReaderPaginationLayout(
                version: 0,
                containerSize: curlViewport(in: view).rect.size,
                fontSize: CGFloat(max(5, parent.fontSize)),
                lineSpacing: CGFloat(parent.lineSpacing),
                letterSpacing: CGFloat(parent.letterSpacing),
                firstLineIndent: CGFloat(parent.paragraphIndent.count),
                paragraphSpacing: CGFloat(parent.paragraphSpacing),
                weightLevel: names.weightLevel,
                fontPostScriptName: names.regular,
                fontBoldPostScriptName: names.bold,
                punctuationKinsoku: parent.punctuationKinsoku,
                // 页眉页脚的高度已经并进 textContainerInset，这里不能再算一遍。
                headerEnabled: false,
                footerEnabled: false,
                headerOffset: 0,
                footerOffset: 0,
                paddingTop: insets.top,
                paddingBottom: insets.bottom,
                paddingLeft: insets.left,
                paddingRight: insets.right,
                chapterTitleScale: max(1, titleScale),
                titleHidden: parent.titleMode == 2
            )
        }

        /// 分页 + 绘制参数：一次算好，三处共用。
        private func curlContent(in view: UITextView) -> (sheets: [ReaderCurlSheet], startCharacters: [Int], style: ReaderCurlStyle) {
            let layout = curlLayout(in: view)
            let insets = pageContentInsets(in: view)
            let contentWidth = CGFloat(layout.usableWidth)
            let titleHeight = coreTextTitleHeight(in: view)
            let titleImage = titleHeight > 0
                ? coreTextTitleImage(in: view, size: CGSize(width: contentWidth, height: titleHeight))
                : nil

            var keyParts: [String] = []
            keyParts.reserveCapacity(18)
            keyParts.append("\(layout.fontSize)")
            keyParts.append("\(layout.lineSpacing)")
            keyParts.append("\(layout.letterSpacing)")
            keyParts.append("\(layout.firstLineIndent)")
            keyParts.append("\(layout.paragraphSpacing)")
            keyParts.append("\(layout.weightLevel)")
            keyParts.append(layout.fontPostScriptName)
            keyParts.append("\(layout.containerSize.width)x\(layout.containerSize.height)")
            keyParts.append("\(insets.top)/\(insets.left)/\(insets.bottom)/\(insets.right)")
            keyParts.append("\(contentWidth)")
            keyParts.append("\(parent.text.utf16.count)")
            keyParts.append("\(parent.text.hashValue)")
            keyParts.append(parent.title)
            keyParts.append("\(parent.titleMode)|\(parent.titleSize)|\(parent.titleCanvasHeight)")
            keyParts.append("\(parent.fullJustify)|\(parent.underlineMode)|\(parent.punctuationKinsoku)|\(parent.smartParagraphs)")
            keyParts.append("\(parent.titleHTMLTemplate.hashValue)|\(parent.titleProjectJSON.hashValue)")
            keyParts.append("\(parent.backgroundImage?.hashValue ?? 0)|\(parent.backgroundColor.hashValue)")
            // 标题位图回填后必须重排一版：缓存里那份还是「无图」的页。
            keyParts.append(titleImage == nil ? "t0" : "t1")
            let key = keyParts.joined(separator: "|")
            if key == curlContentKey, let cachedStyle = curlStyleCache, !curlSheets.isEmpty {
                return (curlSheets, curlStartCharacters, cachedStyle)
            }

            let input = ReaderCurlPageBuildInput(
                blocks: ReaderCurlPageBuilder.blocks(from: parent.text, smartParagraphs: parent.smartParagraphs),
                title: layout.titleHidden ? nil : parent.title,
                layout: layout,
                alignment: parent.fullJustify ? .justify : .leading,
                underline: parent.underlineMode != 0,
                underlineColor: parent.underlineMode == 0 ? nil : parent.foregroundColor,
                textColor: parent.foregroundColor,
                backgroundColor: parent.backgroundColor,
                backgroundImage: parent.backgroundImage,
                contentInsets: insets,
                contentWidth: contentWidth,
                header: parent.headerBar,
                footer: parent.footerBar,
                // 设计稿高度直达分页与绘制：标题位图按整宽铺满，不再被压成一行小字。
                titleHeightOverride: titleHeight,
                titleImage: titleImage
            )
            let result = ReaderCurlPageBuilder.build(input)
            curlSheets = result.sheets
            curlStartCharacters = result.startCharacters
            curlStyleCache = result.style
            curlContentKey = key
            return (result.sheets, result.startCharacters, result.style)
        }

        /// 把一段正文按「同一套排版参数」排成一份页表。
        ///
        /// 相邻章必须用与本章逐点相同的 layout / insets / contentWidth 排版：宽度、行高、
        /// 段距、缩进只要差一丝，拼进同一份页序后跨章那一页的行数就变，观感是「过章后
        /// 字号变小、行数变了」。所以这里不接受任何「另算一套参数」的入口。
        ///
        /// 设计章节标题也必须一起进来：本章走 `curlContent(in:)` 时带了
        /// `titleHeightOverride` / `titleImage`，相邻章这里若漏传，掀起来那张纸上的
        /// 首页就是「无标题排版」（多排几行），落下后本章按「有标题排版」重排 ——
        /// 真机实测「往上一章尾页多行、往下一章首页缩行」就是这一处漏传造成的。
        private func curlSheets(
            text: String,
            title: String?,
            titleHeight: CGFloat,
            titleImage: UIImage?,
            layout: ReaderPaginationLayout,
            insets: UIEdgeInsets,
            contentWidth: CGFloat
        ) -> (sheets: [ReaderCurlSheet], startCharacters: [Int]) {
            let input = ReaderCurlPageBuildInput(
                blocks: ReaderCurlPageBuilder.blocks(from: text, smartParagraphs: parent.smartParagraphs),
                title: layout.titleHidden ? nil : title,
                layout: layout,
                alignment: parent.fullJustify ? .justify : .leading,
                underline: parent.underlineMode != 0,
                underlineColor: parent.underlineMode == 0 ? nil : parent.foregroundColor,
                textColor: parent.foregroundColor,
                backgroundColor: parent.backgroundColor,
                backgroundImage: parent.backgroundImage,
                contentInsets: insets,
                contentWidth: contentWidth,
                header: parent.headerBar,
                footer: parent.footerBar,
                // 与本章同一条口径：预留高度先占住，位图有没有都不影响行数。
                titleHeightOverride: titleHeight,
                titleImage: titleImage
            )
            // 相邻章也要把页首字符表一起带回来。
            //
            // 跨章落地必须给新章写**真实的页首字符**：写成 0 会破坏「仿真模式下
            // `readerPosition` 永远等于卷页层当前页首字符」这条不变量，存档的偏移那一半
            // 随即失效 —— 真机日志里那批 `偏移=0 页>1` 就是这条路径。
            // 分页内核本来就算了这份表，此前只是在这里被丢掉。
            let built = ReaderCurlPageBuilder.build(input)
            return (built.sheets, built.startCharacters)
        }

        /// 拼一份「上一章 + 本章 + 下一章」的扁平页序。
        ///
        /// 章下标用**相对编号**（上一章 −1 / 本章 0 / 下一章 +1），不引入绝对章节下标：
        /// 正文层只握着自己手上这三段正文，绝对章号由外层在落地回调里换算。这样这一层
        /// 既不必新增章节号参数，也就不会出现「两处各记一份章节号、迟一拍就错章」的老问题。
        ///
        /// 相邻章没就绪时那一段页表为空，页序自然退化成单章卷 —— 行为与改动前逐点一致，
        /// 不会多出空白帧。
        private func curlDeck(
            in view: UITextView,
            built: (sheets: [ReaderCurlSheet], startCharacters: [Int], style: ReaderCurlStyle)
        ) -> ReaderPageDeck {
            let layout = curlLayout(in: view)
            let insets = pageContentInsets(in: view)
            let contentWidth = CGFloat(layout.usableWidth)
            // 相邻章的分页结果必须缓存：`updateUIView` 每一帧都会走这里。
            var keyParts: [String] = []
            keyParts.append("\(layout.fontSize)|\(layout.lineSpacing)|\(layout.letterSpacing)")
            keyParts.append("\(layout.firstLineIndent)|\(layout.paragraphSpacing)|\(layout.weightLevel)")
            keyParts.append(layout.fontPostScriptName)
            keyParts.append("\(insets.top)/\(insets.left)/\(insets.bottom)/\(insets.right)")
            keyParts.append("\(contentWidth)")
            keyParts.append(curlContentKey)
            keyParts.append("\(layout.containerSize.width)x\(layout.containerSize.height)")
            keyParts.append("\(parent.text.hashValue)|\(parent.title)|\(parent.chapterIndex)")
            keyParts.append("\(parent.isPreviousReady)|\(parent.previousText.hashValue)|\(parent.previousTitle ?? "")")
            keyParts.append("\(parent.isContinuationReady)|\(parent.continuationText.hashValue)|\(parent.continuationTitle ?? "")")
            keyParts.append("\(parent.fullJustify)|\(parent.underlineMode)|\(parent.smartParagraphs)|\(parent.punctuationKinsoku)")
            // 设计章节标题：相邻章首页必须按**同一份预留高度**排。
            //
            // 高度只由页宽与设计稿画布决定，与哪一章无关，所以三章共用 `deckTitleHeight`；
            // 位图才是逐章的。只把高度透传过去而不传位图，行数与页数就已经完全一致 ——
            // 这正是「翻页未落下时是未加载设计标题的排版、落下后才加载」那条抖动的正解。
            let deckTitleHeight = coreTextTitleHeight(in: view)
            let deckTitleSize = CGSize(width: contentWidth, height: max(deckTitleHeight, 1))
            let previousTitleImage = deckTitleHeight > 1
                ? designTitleImage(for: parent.previousTitle ?? "", size: deckTitleSize, in: view)
                : nil
            let continuationTitleImage = deckTitleHeight > 1
                ? designTitleImage(for: parent.continuationTitle ?? "", size: deckTitleSize, in: view)
                : nil
            keyParts.append("title=\(deckTitleHeight)|\(parent.titleHTMLTemplate.hashValue)|\(parent.titleProjectJSON.hashValue)|\(parent.titleCanvasHeight)")
            keyParts.append("titleImage=\(previousTitleImage == nil ? 0 : 1)|\(continuationTitleImage == nil ? 0 : 1)")
            let key = keyParts.joined(separator: "|")
            if key == curlDeckCacheKey, let cached = curlDeckCache { return cached }
            var chapters: [ReaderPageDeck.Chapter] = []
            // 相邻章的页首字符表按**绝对章号**记下来：跨章落地要用它给新章写真实的页首字符。
            //
            // 与 `curlDeckCache` 同一次构建、同一把键：缓存命中时这里根本不会走到，
            // 所以不会出现「页表是新的、页首表还是旧的」。相邻章就绪状态变了会重进来，
            // 先清空再填，旧章号不会残留。
            curlAdjacentStarts.removeAll(keepingCapacity: true)
            if parent.isPreviousReady, !parent.previousText.isEmpty {
                let previous = curlSheets(
                    text: parent.previousText,
                    title: parent.previousTitle,
                    titleHeight: deckTitleHeight,
                    titleImage: previousTitleImage,
                    layout: layout,
                    insets: insets,
                    contentWidth: contentWidth
                )
                curlAdjacentStarts[parent.chapterIndex - 1] = previous.startCharacters
                chapters.append(ReaderPageDeck.Chapter(
                    index: parent.chapterIndex - 1,
                    title: parent.previousTitle ?? "",
                    sheets: previous.sheets
                ))
            }
            chapters.append(ReaderPageDeck.Chapter(index: parent.chapterIndex, title: parent.title, sheets: built.sheets))
            if parent.isContinuationReady, !parent.continuationText.isEmpty {
                let continuation = curlSheets(
                    text: parent.continuationText,
                    title: parent.continuationTitle,
                    titleHeight: deckTitleHeight,
                    titleImage: continuationTitleImage,
                    layout: layout,
                    insets: insets,
                    contentWidth: contentWidth
                )
                curlAdjacentStarts[parent.chapterIndex + 1] = continuation.startCharacters
                chapters.append(ReaderPageDeck.Chapter(
                    index: parent.chapterIndex + 1,
                    title: parent.continuationTitle ?? "",
                    sheets: continuation.sheets
                ))
            }
            let deck = ReaderPageDeck(chapters: chapters, currentChapterIndex: parent.chapterIndex)
            curlDeckCache = deck
            curlDeckCacheKey = key
            return deck
        }

        /// 渲染指纹：字体、行距、视口、内边距、正文长度、底色变了就得重建页面。
        ///
        /// 逐项 `append` 而不是一个十项数组字面量：十个 `String(...)` 挤在同一条
        /// 表达式里会让类型检查器超时（CI 实测报 "unable to type-check this
        /// expression in reasonable time"）。拆成独立语句后每个转换都有唯一上下文。
        ///
        /// 用字符串插值而不是 `String(...)`：`CGFloat` 不满足 `LosslessStringConvertible`，
        /// `String(width)` 没有可用初始化器（CI 实测四处 `no exact matches in call to
        /// initializer`）。插值走 `String(describing:)` 通路，对 `CGFloat` 合法；每条
        /// `append` 仍是独立语句，也不会回到「一个表达式里堆十个转换」的类型检查超时。
        private func nativeCurlSignature(in view: UITextView) -> String {
            var parts: [String] = []
            parts.reserveCapacity(12)
            parts.append("\(parent.fontSize)")
            parts.append("\(parent.lineSpacing)")
            parts.append("\(parent.letterSpacing)")
            parts.append("\(parent.paragraphSpacing)")
            parts.append("\(view.bounds.width)")
            parts.append("\(view.bounds.height)")
            parts.append("\(view.textContainerInset.top)")
            parts.append("\(view.textContainerInset.bottom)")
            parts.append("\(view.text.utf16.count)")
            // 只比长度不够：换章后正文长度恰好相同就会继续用上一章的快照。
            // 正文哈希与页数一起进指纹，换章必然重建。
            parts.append("\(view.text.hashValue)")
            parts.append("\(pageStarts(for: view).count)")
            parts.append("\(parent.backgroundColor.hashValue)")
            // 背景图换了也要重建活页：纸面是靠每页自铺的背景图撑成不透明的。
            parts.append("\(parent.backgroundImage?.hashValue ?? 0)")
            // CoreText 分页对字体文件、缩进字符、对齐开关同样敏感：漏了这几项，
            // 换字体后卷页层会继续用旧页（页数与切口全都对不上）。
            parts.append(parent.fontPath)
            parts.append(parent.paragraphIndent)
            parts.append("\(parent.fullJustify)")
            parts.append("\(parent.underlineMode)")
            parts.append("\(parent.smartParagraphs)")
            parts.append("\(parent.underlinePattern)")
            parts.append("\(parent.paragraphSeparatorLines)")
            // 章节标题设计稿：模板 / 工程 / 画布高度任一项变了都要重建活页。
            parts.append("\(parent.titleHTMLTemplate.hashValue)")
            parts.append("\(parent.titleProjectJSON.hashValue)")
            parts.append("\(parent.titleCanvasHeight)")
            return parts.joined(separator: "|")
        }

        /// 跨章落地：只记页坐标，不动正文偏移。
        ///
        /// 落在相邻章那一拍，`view` 里的正文还是旧章的，`starts` 也是旧章的页首表，
        /// 拿它对齐只会把旧章偏移写进新章。这一拍真正要做的只有一件事：记下页坐标，
        /// 让外层在 `saveProgress` 里能存「第几章第几页」，而不是只有被写成 0 的字符偏移。
        private func reportSettled(location: ReaderDeckLocation) {
            publishCurlProgress(location: location, deferred: false)
        }

        private func publishCurlProgress(location: ReaderDeckLocation, deferred: Bool) {
            guard let position = deckStartCharacter(for: location),
                  let count = curlDeck?.pageCount(inChapter: location.chapterIndex),
                  count > 0, location.pageIndex >= 0, location.pageIndex < count else { return }
            let progress = ReaderPageProgress(
                chapterIndex: location.chapterIndex, pageIndex: location.pageIndex,
                pageCount: count, position: position
            )
            guard progress != settledCurlProgress else { return }
            settledCurlProgress = progress
            progressPublication &+= 1
            let publication = progressPublication
            let report: @MainActor @Sendable () -> Void = { [weak self] in
                guard let self, !self.isInvalidated, self.progressPublication == publication else { return }
                self.parent.onPageSettled(progress)
            }
            if deferred { DispatchQueue.main.async(execute: report) } else { report() }
        }

        /// 页序某一页的页首字符：本章读 `curlStartCharacters`，相邻章读侧表。
        ///
        /// 跨章落地要交给外层的不是「0」，而是新章那一页的首字符。写成 0 会让
        /// `readerPosition` 与卷页层当前页脱钩，此后所有「按偏移反查」的兜底都只能给首页。
        private func deckStartCharacter(for location: ReaderDeckLocation) -> Int? {
            if location.chapterIndex == parent.chapterIndex {
                guard curlStartCharacters.indices.contains(location.pageIndex) else { return nil }
                return curlStartCharacters[location.pageIndex]
            }
            guard let starts = curlAdjacentStarts[location.chapterIndex],
                  starts.indices.contains(location.pageIndex) else { return nil }
            return starts[location.pageIndex]
        }

        /// 仿真模式下「读者眼前这一页」的首字符：只认卷页层的页号。
        ///
        /// 隐藏的 `UITextView` 只是分页量尺，它的 `contentOffset` 会被布局重建 / 重排 /
        /// `scroll(to:)` 挪动，与读者实际所在页并非同一页。凡是「把当前位置交出去」的动作
        /// （边界到头、存档落点）一律走这里，不要读量尺的偏移。
        private func currentCurlCharacter(in view: UITextView) -> Int {
            if curlStartCharacters.indices.contains(curlCurrentIndex) {
                return curlStartCharacters[curlCurrentIndex]
            }
            return contentCharacter(at: view.contentOffset, in: view)
        }

        /// 卷页落地：把正文偏移对齐到新页首，页码与页范围跟着刷新。
        private func commitNativeCurl(index: Int, starts: [CGFloat], in view: UITextView) {
            guard starts.indices.contains(index) else { return }
            // 卷页层翻到哪一页，这一页就是本地的当前位置：后续同步一律沿用它，
            // 否则一次布局回调就会把读者按「上一章遗留的偏移」重新算一遍并拽走。
            curlCurrentIndex = index
            curlEntryIndex = index
            // 翻页完成回调在主线程，章/页/位置同步提交后才允许任何进度保存。
            layoutGeneration &+= 1
            publishCurlProgress(
                location: ReaderDeckLocation(chapterIndex: parent.chapterIndex, pageIndex: index),
                deferred: false
            )
            view.setContentOffset(CGPoint(x: 0, y: starts[index]), animated: false)
            reportPage(in: view)
            reportPageRanges(in: view)
        }

        private func tearDownNativeCurl() {
            guard nativeCurl != nil || nativeCurlHost != nil else { return }
            notifyCurlPublished(false)
            progressPublication &+= 1
            settledCurlProgress = nil
            nativeCurl?.onIndexChange = nil
            nativeCurl?.onDeckCommit = nil
            nativeCurl?.onTransitionEnd = nil
            nativeCurl?.onReachEnd = nil
            nativeCurl?.onReachStart = nil
            nativeCurl?.onTap = nil
            nativeCurl?.willMove(toParent: nil)
            nativeCurl?.view.removeFromSuperview()
            nativeCurl?.removeFromParent()
            nativeCurlHost?.removeFromSuperview()
            nativeCurl = nil
            nativeCurlHost = nil
            // 还原宿主容器的裁剪设置：放开它只是为了让纸铺满整屏。
            if let clipHost = nativeCurlClipHost, !clipHost.clipsToBounds {
                clipHost.clipsToBounds = nativeCurlClipHostOriginal
            }
            nativeCurlClipHost = nil
            // 还原被清空字色的正文视图：卷页层拆掉后，正文要重新由它显示。
            if let hidden = nativeCurlTextHiddenView, let color = nativeCurlTextHiddenColor {
                hidden.textColor = color
            }
            nativeCurlTextHiddenView = nil
            nativeCurlTextHiddenColor = nil
            nativeCurlPageCount = 0
            nativeCurlSignatureValue = ""
        }

        // MARK: - CoreText 排版内核（照 Juyue ReaderPaginator / CoreTextUIView）
        //
        // 仿真模式的正文不再交给 `UITextView` 排版，而是走 `ReaderCoreTextEngine`：
        // 折行 → 分页 → 逐行 `CTLineCreateJustifiedLine`。这样才拿得到 `UITextView`
        // 给不出的三样东西：两端对齐的逐行二次分配、页末匀空白、中文标点禁则。
        // 分页结果同时决定页数、页码、页范围与卷页落地偏移，四者不会再各算一套。

        /// 整章 CoreText 分页缓存（仿真正在用）。
        private var coreTextPageCache: [ReaderCoreTextPage] = []
        private var coreTextPageCacheKey = ""
        /// 每页首字符换算出的 contentOffset 缓存。
        private var coreTextStartsCache: [CGFloat] = []
        private var coreTextStartsCacheKey = ""

        /// 排版参数：从设置直读，与 `ReaderTypography` 同口径
        /// （字体、字距、行距、段距、缩进、对齐、下划线）。
        private func coreTextLayout(in view: UITextView) -> ReaderCoreTextLayout {
            let size = CGFloat(max(5, parent.fontSize))
            let base = ReaderFontStore.font(at: parent.fontPath, size: size, weight: parent.fontWeight)
                ?? UIFont.systemFont(ofSize: size)
            return ReaderCoreTextLayout(
                bodyFont: ReaderCoreTextFont.font(from: base),
                fontSize: size,
                lineSpacing: CGFloat(parent.lineSpacing),
                paragraphSpacing: CGFloat(parent.paragraphSpacing),
                letterSpacing: CGFloat(parent.letterSpacing),
                firstLineIndent: parent.paragraphIndent,
                alignment: parent.fullJustify ? .justify : .leading,
                underline: parent.underlineMode != 0,
                underlineStyle: ReaderUnderlinePattern.pattern(for: parent.underlinePattern).nsUnderlineStyle,
                paragraphSeparatorLines: max(0, parent.paragraphSeparatorLines),
                paragraphSeparatorColor: parent.paragraphSeparatorLines > 0
                    ? parent.foregroundColor.withAlphaComponent(0.35)
                    : nil,
                justifyLastPage: parent.justifyLastPage,
                punctuationKinsoku: parent.punctuationKinsoku,
                conversion: ReaderChineseConversion.conversion(for: parent.chineseConversion)
            )
        }

        /// 把已渲染的 attributedText 拆成段落：每段带自己的字体。
        ///
        /// 章节标题比正文大一号，行高必须按它自己的字号算，否则标题会被正文行高切掉一半；
        /// 标题同时不缩进、不参与两端对齐（`isHeading`）。
        private func coreTextParagraphs() -> [ReaderCoreTextParagraph] {
            guard let attributed = livePageText, attributed.length > 0 else { return [] }
            let ns = attributed.string as NSString
            let bodySize = CGFloat(max(5, parent.fontSize))
            var result: [ReaderCoreTextParagraph] = []
            var location = 0
            while location < ns.length {
                let range = ns.paragraphRange(for: NSRange(location: location, length: 0))
                var text = ns.substring(with: range)
                if text.hasSuffix("\n") { text = String(text.dropLast()) }
                if text.hasSuffix("\r") { text = String(text.dropLast()) }
                let font = (attributed.attribute(.font, at: range.location, effectiveRange: nil) as? UIFont)
                    ?? UIFont.systemFont(ofSize: bodySize)
                let isHeading = abs(font.pointSize - bodySize) > 0.5
                // 智能分段（Juyue `smartParagraphSplit`）：只拆「长且完全没有段落」的行。
                // 拆出来的每一段按 UTF-16 累计偏移记 charBase，字符偏移与原文一一对应，
                // 分页后的进度、页范围、字号定位都不会漂。
                // 有设计稿标题时，正文里那段纯文字标题不再参与排版：设计标题位图已经画在
                // 首页顶部，两份标题会同时出现（实测）。字符偏移仍按原文记，页首映射不受影响。
                let hiddenByDesign = isHeading && hasDesignTitle
                let pieces: [String]
                if hiddenByDesign {
                    pieces = []
                } else if parent.smartParagraphs && !isHeading {
                    pieces = ReaderTextTransform.smartParagraphSplit(text)
                } else {
                    pieces = [text]
                }
                var offset = 0
                for piece in pieces {
                    result.append(ReaderCoreTextParagraph(
                        text: piece,
                        font: ReaderCoreTextFont.font(from: font),
                        charBase: range.location + offset,
                        isHeading: isHeading
                    ))
                    offset += (piece as NSString).length
                }
                location = range.location + max(range.length, 1)
            }
            return result
        }

        /// 仿真模式的分页结果（带缓存）。其他模式返回空，分页继续走 TextKit。
        private func coreTextPagination(in view: UITextView) -> [ReaderCoreTextPage] {
            guard effectiveAnimation == 2, view.bounds.width > 1, view.bounds.height > 1 else { return [] }
            let insets = view.textContainerInset
            var keyParts: [String] = []
            keyParts.reserveCapacity(11)
            keyParts.append(styleKey)
            keyParts.append("\(view.bounds.width)")
            keyParts.append("\(view.bounds.height)")
            keyParts.append("\(insets.top)")
            keyParts.append("\(insets.bottom)")
            keyParts.append("\(insets.left)")
            keyParts.append("\(insets.right)")
            keyParts.append("\(view.text.utf16.count)")
            keyParts.append(parent.fontPath)
            keyParts.append(parent.paragraphIndent)
            keyParts.append("\(parent.fullJustify)")
            keyParts.append("\(parent.smartParagraphs)")
            keyParts.append("\(parent.chineseConversion)")
            keyParts.append("\(parent.titleHTMLTemplate.hashValue)")
            keyParts.append("\(parent.titleProjectJSON.hashValue)")
            keyParts.append("\(parent.titleCanvasHeight)")
            keyParts.append("\(parent.titleMode)")
            let key = keyParts.joined(separator: "|")
            if key == coreTextPageCacheKey, !coreTextPageCache.isEmpty { return coreTextPageCache }
            let paragraphs = coreTextParagraphs()
            guard !paragraphs.isEmpty else { return [] }
            let titleHeight = coreTextTitleHeight(in: view)
            var pages = ReaderCoreTextEngine.pages(
                for: paragraphs,
                containerSize: view.bounds.size,
                insets: insets,
                layout: coreTextLayout(in: view),
                firstPageTitleHeight: titleHeight
            )
            if titleHeight > 0, !pages.isEmpty {
                let usableWidth = max(120, view.bounds.width - insets.left - insets.right)
                let image = coreTextTitleImage(
                    in: view,
                    size: CGSize(width: usableWidth, height: titleHeight)
                )
                // 位图回填进首页：预留高度不变，所以页数、页首偏移都不动，只是这一页多画一张图。
                let first = pages[0]
                pages[0] = ReaderCoreTextPage(
                    lines: first.lines,
                    extraParagraphSpacing: first.extraParagraphSpacing,
                    titleHeight: titleHeight,
                    titleImage: image ?? first.titleImage
                )
            }
            coreTextPageCache = pages
            coreTextPageCacheKey = key
            return pages
        }

        /// 这一章是否用了设计稿标题：正文里那段纯文字标题要被它取代。
        private var hasDesignTitle: Bool {
            parent.titleMode != 2
                && !parent.titleHTMLTemplate.isEmpty
                && !parent.titleProjectJSON.isEmpty
        }

        /// 首页设计稿标题的预留高度：按画布等比算，图没回来也先占住。
        ///
        /// 只算高度、不碰行内排版：正文可用高度由 `ReaderCoreTextEngine` 首页扣掉这一段，
        /// 后续页回到满高，所以「有没有设计稿」只影响首页排多少行。
        private func coreTextTitleHeight(in view: UITextView) -> CGFloat {
            guard parent.titleMode != 2 else { return 0 }
            guard !parent.titleHTMLTemplate.isEmpty, !parent.titleProjectJSON.isEmpty else { return 0 }
            let insets = view.textContainerInset
            let width = effectiveAnimation == 2
                ? CGFloat(curlLayout(in: view).usableWidth)
                : max(120, view.bounds.width - insets.left - insets.right)
            return ChapterTitleRenderer.height(
                forWidth: width,
                projectJSON: parent.titleProjectJSON,
                canvasHeight: parent.titleCanvasHeight
            )
        }

        /// 首页标题位图：就绪就回填，没就绪先返回 nil 并安排一次离屏渲染。
        ///
        /// 渲染完成时清掉分页缓存并重建卷页层：位图属于页面内容，缓存页与已建好的
        /// 页面控制器都还是「无图」那一版，不重建就永远看不到标题。
        private func coreTextTitleImage(in view: UITextView, size: CGSize) -> UIImage? {
            guard parent.titleMode != 2,
                  !parent.titleHTMLTemplate.isEmpty,
                  !parent.titleProjectJSON.isEmpty,
                  size.width > 1, size.height > 1 else { return nil }
            return ReaderChapterTitleStore.shared.image(
                htmlTemplate: parent.titleHTMLTemplate,
                projectJSON: parent.titleProjectJSON,
                chapterTitle: parent.title,
                chapterNumber: "",
                size: size,
                isDark: false,
                window: view.window
            ) { [weak self] in
                guard let self else { return }
                self.coreTextPageCacheKey = ""
                self.coreTextStartsCacheKey = ""
                self.curlContentKey = ""
                // 标题回填不拆当前纸页；手势结束后统一更新。
                self.parent.onDeferredRender()
            }
        }

        /// 相邻章首页的设计标题位图。
        ///
        /// 高度与章标题无关（只由页宽与设计稿画布决定），所以 `titleHeight` 由调用方统一给；
        /// 这里只负责按**那一章的标题**渲染位图。位图没就绪时先返回 nil：预留高度已经占住，
        /// 页数与行数都不会变，等图回来后只重画那一页。
        private func designTitleImage(
            for chapterTitle: String,
            size: CGSize,
            in view: UITextView
        ) -> UIImage? {
            guard parent.titleMode != 2,
                  !parent.titleHTMLTemplate.isEmpty,
                  !parent.titleProjectJSON.isEmpty,
                  !chapterTitle.isEmpty,
                  size.width > 1, size.height > 1 else { return nil }
            return ReaderChapterTitleStore.shared.image(
                htmlTemplate: parent.titleHTMLTemplate,
                projectJSON: parent.titleProjectJSON,
                chapterTitle: chapterTitle,
                chapterNumber: "",
                size: size,
                isDark: false,
                window: view.window
            ) { [weak self] in
                guard let self else { return }
                // 位图只影响绘制、不影响分页（预留高度没变）：只作废页序缓存，
                // 下一帧按同一份页高重排。绝不在转场中拆卷页层。
                self.curlDeckCacheKey = ""
                self.curlDeckCache = nil
                // 页序缓存与相邻章页首表必须一起清：只清一份，下一次跨章落地会拿到
                // 与新页表不配套的旧页首字符，`readerPosition` 当场就被写偏。
                // 仍在显示的页序需要这份坐标表，等下一次构建整体替换。
                DispatchQueue.main.async { self.parent.onDeferredRender() }
            }
        }

        /// 每页首字符换成 contentOffset：卷页落地、页码、页范围共用这一份。
        ///
        /// 页首字符偏移由分页层给出（`ReaderCurlPageBuilder`），这里只做「字符 → 行顶」的
        /// 换算：页数与卷页层的页数天然一一对应，落地偏移不会错位。
        private func coreTextPageStarts(in view: UITextView) -> [CGFloat]? {
            guard effectiveAnimation == 2 else { return nil }
            let built = curlContent(in: view)
            guard !built.sheets.isEmpty else { return nil }
            let insets = view.textContainerInset
            var keyParts: [String] = []
            keyParts.reserveCapacity(9)
            keyParts.append(curlContentKey)
            keyParts.append("\(view.bounds.height)")
            keyParts.append("\(insets.top)")
            keyParts.append("\(insets.bottom)")
            keyParts.append("\(view.adjustedContentInset.top)")
            keyParts.append("\(view.adjustedContentInset.bottom)")
            keyParts.append("\(built.sheets.count)")
            let key = keyParts.joined(separator: "|")
            if key == coreTextStartsCacheKey, !coreTextStartsCache.isEmpty { return coreTextStartsCache }
            view.layoutManager.ensureLayout(for: view.textContainer)
            let glyphCount = view.layoutManager.numberOfGlyphs
            guard glyphCount > 0 else { return nil }
            let limits = scrollLimits(for: view)
            let renderedLength = max(view.text.utf16.count, 1)
            let bodyLength = max(parent.text.utf16.count, 1)
            var starts: [CGFloat] = []
            starts.reserveCapacity(built.sheets.count)
            for offset in built.startCharacters {
                let body = min(max(offset, 0), bodyLength - 1)
                let location = min(max(renderedPrefixLength + body, 0), renderedLength - 1)
                let glyph = min(view.layoutManager.glyphIndexForCharacter(at: location), glyphCount - 1)
                var y = view.layoutManager.boundingRect(
                    forGlyphRange: NSRange(location: glyph, length: 1),
                    in: view.textContainer
                ).minY + view.textContainerInset.top - view.adjustedContentInset.top
                y = min(max(y, limits.minimum), limits.maximum)
                // 页数必须与分页结果一一对应：重合时强行拉开半行，宁可略偏也不让下标错位。
                if let last = starts.last, y <= last { y = last + 0.5 }
                starts.append(y)
            }
            guard !starts.isEmpty else { return nil }
            coreTextStartsCache = starts
            coreTextStartsCacheKey = key
            return starts
        }

        private func resetAutoPage() {
            autoPageProgress = 0
            eInkElapsed = 0
            eInkPageInterval = secondsPerScreen
            autoPageTarget = nil
            autoPageOverlay?.removeFromSuperview()
            autoPageOverlay = nil
            lastTimestamp = 0
        }

        private func prepareAutoPage(in view: UITextView) -> Bool {
            guard let target = pageTarget(from: 1, in: view) else { return false }
            let originalOffset = view.contentOffset
            isRenderingAutoPage = true
            view.setContentOffset(CGPoint(x: 0, y: target), animated: false)
            view.layoutIfNeeded()
            let renderer = UIGraphicsImageRenderer(bounds: view.bounds)
            let image = renderer.image { context in view.layer.render(in: context.cgContext) }
            view.setContentOffset(originalOffset, animated: false)
            isRenderingAutoPage = false

            let overlay = UIImageView(image: image)
            overlay.isUserInteractionEnabled = false
            overlay.contentMode = .top
            overlay.clipsToBounds = true
            overlay.layer.borderColor = view.tintColor.cgColor
            overlay.layer.borderWidth = 0
            overlay.frame = CGRect(x: 0, y: originalOffset.y, width: view.bounds.width, height: 0)
            view.addSubview(overlay)
            autoPageOverlay = overlay
            autoPageTarget = target
            return true
        }

        private func advancePagedAutoRead(in view: UITextView, elapsed: CFTimeInterval) {
            // 仿真模式走原生卷页层：自动阅读必须让卷页层自己翻页。
            // 否则底层改 contentOffset 而覆盖层显示的是旧快照，画面会一动不动。
            if let nativeCurl {
                let pageHeight = readingViewportHeight(for: view)
                autoPageProgress += pageHeight / CGFloat(secondsPerScreen) * CGFloat(elapsed)
                guard autoPageProgress >= pageHeight else { return }
                autoPageProgress = 0
                guard !nativeCurl.isTurning else { return }
                if nativeCurl.turn(forward: true) {
                    didReachEnd = false
                }
                return
            }
            if autoPageOverlay == nil, !prepareAutoPage(in: view) {
                guard !didReachEnd else { return }
                didReachEnd = true
                parent.onReachedEnd(contentCharacter(at: view.contentOffset, in: view))
                return
            }
            didReachEnd = false
            let pageHeight = readingViewportHeight(for: view)
            autoPageProgress += pageHeight / CGFloat(secondsPerScreen) * CGFloat(elapsed)
            let revealedHeight = min(autoPageProgress, pageHeight)
            if let overlay = autoPageOverlay {
                overlay.frame = CGRect(
                    x: 0,
                    y: view.contentOffset.y,
                    width: view.bounds.width,
                    height: revealedHeight
                )
                overlay.layer.borderWidth = revealedHeight > 0 ? 0.5 : 0
            }
            guard autoPageProgress >= pageHeight, let target = autoPageTarget else { return }
            autoPageOverlay?.removeFromSuperview()
            autoPageOverlay = nil
            autoPageTarget = nil
            autoPageProgress = 0
            view.setContentOffset(CGPoint(x: 0, y: target), animated: false)
        }

        private func advanceEInkAutoRead(in view: UITextView, elapsed: CFTimeInterval) {
            eInkElapsed += elapsed
            guard eInkElapsed >= eInkPageInterval else { return }
            eInkElapsed = 0
            eInkPageInterval = secondsPerScreen
            guard let target = pageTarget(from: 1, in: view) else {
                guard !didReachEnd else { return }
                didReachEnd = true
                parent.onReachedEnd(contentCharacter(at: view.contentOffset, in: view))
                return
            }
            didReachEnd = false
            view.setContentOffset(CGPoint(x: 0, y: target), animated: false)
        }

        @objc private func step(_ link: CADisplayLink) {
            guard isAutoReading, !isAutoReadPaused, !isUserDragging, let view = textView else {
                lastTimestamp = link.timestamp
                return
            }
            guard lastTimestamp > 0 else {
                lastTimestamp = link.timestamp
                return
            }
            let elapsed = link.timestamp - lastTimestamp
            lastTimestamp = link.timestamp
            if parent.isEInkMode {
                advanceEInkAutoRead(in: view, elapsed: elapsed)
                return
            }
            if parent.pageAnimation != 3 {
                advancePagedAutoRead(in: view, elapsed: elapsed)
                return
            }
            let maximum = scrollLimits(for: view).maximum
            let next = view.contentOffset.y
                + readingViewportHeight(for: view) / CGFloat(secondsPerScreen) * CGFloat(elapsed)
            if next >= maximum - 0.5 {
                view.setContentOffset(CGPoint(x: 0, y: maximum), animated: false)
                guard !didReachEnd else { return }
                didReachEnd = true
                parent.onReachedEnd(contentCharacter(at: view.contentOffset, in: view))
            } else {
                didReachEnd = false
                view.setContentOffset(CGPoint(x: 0, y: next), animated: false)
            }
        }
    }
}
