@preconcurrency import AVFoundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ReaderView: View {
    private var usesEPUBLayout = true

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @EnvironmentObject private var library: BookLibraryModel
    @EnvironmentObject private var sourceLibrary: SourceLibraryModel
    @EnvironmentObject private var replaceRules: ReplaceRuleLibraryModel
    @EnvironmentObject private var activity: ReadingActivityModel
    @StateObject private var model: ReaderViewModel
    private var book: Book { model.book }
    @State private var sourceSwitchBook: Book?
    @StateObject private var speech = ReaderSpeechController()
    @State private var showsTableOfContents = false
    @State private var showsBookmarks = false
    @State private var illustrationChapter: BookChapter?
    @State private var showsAutoReadControls = false
    @State private var showsStyleControls = false
    @State private var isAutoReading = false
    @State private var showsReaderMenu = false
    @State private var followsSystemBrightness = true
    @State private var readerBrightness = Double(UIScreen.main.brightness)
    @State private var brightnessBeforeReading = Double(UIScreen.main.brightness)
    @State private var tocSearch = ""
    @State private var tocDescending = false
    @State private var showsContentSearch = false
    @State private var showsReplaceRules = false
    @State private var showsReaderSettings = false
    @State private var showsClickActionSettings = false
    @State private var showsContentEditor = false
    @State private var showsBookInfo = false
    @State private var showsTitleDesigner = false
    @State private var editedContent = ""
    @State private var contentEditError: String?
    @State private var backgroundImage: UIImage?
    /// 仿真模式：卷页层是否已经在屏上。
    ///
    /// 换章那一帧新章正文还没到，旧页必须继续留在屏上。这里若还是把界面换成
    /// 「正在打开本章」，SwiftUI 会把 ReaderTextView 连同卷页层一起拆掉重建 ——
    /// 观感就只剩闪一下加载，永远看不到卷页转场。
    @State private var curlPublishedPages = false
    /// 正在进行的跨章翻页：一次边界手势只许换一章。
    ///
    /// 章界同时挂着位移旁听、左右划兜底和程序化翻页到头三条通路，一次抬手可能
    /// 连续触发两三次回调，每回调一次就换一章 —— 实测「第 18 章往回一次退到第 15 章」
    /// 「第 15 章往回不是第 16 章」都是同一下手势换掉两三章的结果。
    @State private var backgroundError: String?
    @State private var showsBackgroundPicker = false
    @State private var showsFontImporter = false
    @State private var fontError: String?
    @State private var readerJumpPosition: Int?
    @State private var contentSearchQuery = ""
    @State private var readerPosition = 0
    @State private var readerPageRanges: [NSRange] = []
    @State private var speechPageIndex = 0
    @State private var currentPage = 1
    @State private var totalPages = 1
    @State private var readerRenderRevision = 0
    @State private var isWaitingForNextChapter = false
    @State private var isWaitingForPreviousChapter = false
    @State private var httpTTSEngines: [HttpTTS] = []
    @State private var resumesSpeechAfterChapterLoad = false
    @State private var speechTimerTask: Task<Void, Never>?
    @State private var progressSaveTask: Task<Void, Never>?
    @State private var progressSaveGeneration = 0
    @State private var speechStartGeneration = 0
    @State private var speechTimerRemaining = 0
    @State private var isSavingBookmark = false
    @ScaledMetric(relativeTo: .body) private var toolbarIconSize = 21
    @AppStorage("textSize") private var fontSize = 20.0
    @AppStorage("letterSpacing") private var letterSpacing = 0.1
    @AppStorage("lineSpacingExtra") private var lineSpacing = 12.0
    @AppStorage("paragraphSpacing") private var paragraphSpacing = 2.0
    @AppStorage("paragraphIndent") private var paragraphIndent = "　　"
    @AppStorage("paddingLeft") private var paddingLeft = 16.0
    @AppStorage("paddingRight") private var paddingRight = 16.0
    @AppStorage("paddingTop") private var paddingTop = 6.0
    @AppStorage("paddingBottom") private var paddingBottom = 6.0
    @AppStorage("textBold") private var fontWeight = 0
    @AppStorage("textFont") private var fontPath = ""

    /// 目录里已注册的字体（含手动放进「文件」App 的）。
    private var installedFontFaces: [ReaderFontStore.Face] { ReaderFontStore.installedFaces() }
    @AppStorage("titleMode") private var titleMode = 0
    @AppStorage("titleSize") private var titleSize = 0.0
    @AppStorage("titleTopSpacing") private var titleTopSpacing = 0.0
    @AppStorage("titleBottomSpacing") private var titleBottomSpacing = 0.0
    @AppStorage("underlineMode") private var underlineMode = 0
    /// 下划线线型：0 实线 / 1 点线 / 2 虚线 / 3 点划线（Juyue `reader_underline_pattern`）。
    @AppStorage("underlinePattern") private var underlinePattern = 0
    /// 段末分隔线根数：0 关闭（Juyue `paragraph_separator_lines`）。
    @AppStorage("paragraphSeparatorLines") private var paragraphSeparatorLines = 0
    /// 页末匀空白（Juyue `reader_justify_last_page`）。
    @AppStorage("justifyLastPage") private var justifyLastPage = true
    /// 中文标点禁则（Juyue `reader_punctuation_kinsoku`）。
    @AppStorage("punctuationKinsoku") private var punctuationKinsoku = true
    /// 智能分段（Juyue `reader_smart_paragraphs`）：只拆「长且完全没有段落」的行。
    @AppStorage("smartParagraphs") private var smartParagraphs = true
    /// 简繁转换：0 原文 / 1 转简 / 2 转繁（Juyue `chinese_conversion`）。
    @AppStorage("chineseConversion") private var chineseConversion = 0
    /// 章节标题设计稿：HTML 模板 + 工程 JSON + 画布高度（Juyue `chapterTitleHTMLTemplate` 那一组）。
    @AppStorage("chapterTitleHTMLTemplate") private var chapterTitleHTMLTemplate = ""
    @AppStorage("chapterTitleProjectJSON") private var chapterTitleProjectJSON = ""
    @AppStorage("chapterTitleCanvasHeight") private var chapterTitleCanvasHeight = 0.0
    @AppStorage("headerPaddingBottom") private var headerPaddingBottom = 0.0
    @AppStorage("headerPaddingLeft") private var headerPaddingLeft = 16.0
    @AppStorage("headerPaddingRight") private var headerPaddingRight = 16.0
    @AppStorage("headerPaddingTop") private var headerPaddingTop = 0.0
    @AppStorage("footerPaddingBottom") private var footerPaddingBottom = 6.0
    @AppStorage("footerPaddingLeft") private var footerPaddingLeft = 16.0
    @AppStorage("footerPaddingRight") private var footerPaddingRight = 16.0
    @AppStorage("footerPaddingTop") private var footerPaddingTop = 6.0
    @AppStorage("showHeaderLine") private var showHeaderLine = false
    @AppStorage("showFooterLine") private var showFooterLine = true
    /// 页眉页脚六栏的条目：存成 `|` 连接的 `ReaderBarContent` rawValue，一栏可填多个。
    /// 旧版的六个整数码在 `migrateBarSettingsIfNeeded()` 里一次性搬过来，老配置不失效。
    @AppStorage("readerBarHeaderLeft") private var barHeaderLeft = "时间"
    @AppStorage("readerBarHeaderMiddle") private var barHeaderMiddle = ""
    @AppStorage("readerBarHeaderRight") private var barHeaderRight = "电量图标"
    @AppStorage("readerBarFooterLeft") private var barFooterLeft = "标题"
    @AppStorage("readerBarFooterMiddle") private var barFooterMiddle = ""
    @AppStorage("readerBarFooterRight") private var barFooterRight = "页码|进度(%)"
    /// 页栏配套参数（Juyue `shortTitleLength` / `customDatePattern` / `customBarText`）。
    @AppStorage("readerBarShortTitleLength") private var barShortTitleLength = 6
    @AppStorage("readerBarCustomDatePattern") private var barCustomDatePattern = "M月d日"
    @AppStorage("readerBarCustomText") private var barCustomText = ""
    /// 阅读会话起点：页栏的「阅读时长 / 剩余时间」靠它算。
    @State private var barSessionStart = Date()
    @AppStorage("headerMode") private var headerMode = 0
    @AppStorage("footerMode") private var footerMode = 0
    @AppStorage("readerTheme") private var theme = "wechat"
    @AppStorage("readerPreviousDayTheme") private var previousDayTheme = "wechat"
    /// 自动夜间（Juyue `reader_auto_night`）：22:00–07:00 自动切夜间，白天还原成进入夜间前的那套主题。
    @AppStorage("readerAutoNight") private var autoNight = false
    @AppStorage("autoReadSpeed") private var autoReadSpeed = 10
    @AppStorage("ttsFollowSys") private var ttsFollowSystem = true
    @AppStorage("ttsSpeechRate") private var ttsSpeechRate = 5
    @AppStorage("appTtsEngine") private var appTTSEngine = ""
    @AppStorage("systemTtsVoice") private var systemTTSVoice = ""
    @AppStorage("readAloudByPage") private var readAloudByPage = false
    @AppStorage("streamReadAloudAudio") private var streamReadAloudAudio = true
    @AppStorage("readAloudWakeLock") private var readAloudWakeLock = false
    @AppStorage("ignoreAudioFocus") private var ignoreAudioFocus = false
    @AppStorage("pauseReadAloudWhilePhoneCalls") private var pauseReadAloudWhilePhoneCalls = false
    @AppStorage("mediaButtonPerNext") private var mediaButtonPerNext = false
    @AppStorage("ttsTimer") private var ttsTimer = 0
    @AppStorage("readerFullJustify") private var fullJustify = true
    @AppStorage("readerKeepScreenOn") private var keepScreenOn = false
    @AppStorage("readerHideHomeIndicator") private var hideHomeIndicator = false
    @AppStorage("readerHideStatusBar") private var hideStatusBar = false
    @AppStorage("readerShowBrightness") private var showBrightness = true
    @AppStorage("readerBrightness") private var storedReaderBrightness = 0.0
    @AppStorage("readerUseBackgroundImage") private var useBackgroundImage = false
    @AppStorage("themeMode") private var themeMode = "0"
    @AppStorage("enableReadRecord") private var enableReadRecord = true
    @State private var pageAnimation: Int
    @AppStorage("screenOrientation") private var screenOrientation = "0"
    @AppStorage("clickActionTopLeft") private var clickActionTL = 2
    @AppStorage("clickActionTopCenter") private var clickActionTC = 2
    @AppStorage("clickActionTopRight") private var clickActionTR = 1
    @AppStorage("clickActionMiddleLeft") private var clickActionML = 2
    @AppStorage("clickActionMiddleRight") private var clickActionMR = 1
    @AppStorage("clickActionBottomLeft") private var clickActionBL = 2
    @AppStorage("clickActionBottomCenter") private var clickActionBC = 1
    @AppStorage("clickActionBottomRight") private var clickActionBR = 1


    init(book: Book, chapters: [BookChapter], initialIndex: Int, source: BookSource) {
        // 旧版六个整数码 → 新的条目数组，只在第一次进阅读页时搬一次。
        Self.migrateBarSettingsIfNeeded()
        _pageAnimation = State(initialValue: book.readConfig?.pageAnim.flatMap { $0 >= 0 ? $0 : nil }
            ?? Self.globalPageAnimation())
        _model = StateObject(wrappedValue: ReaderViewModel(
            book: book,
            chapters: chapters,
            initialIndex: initialIndex,
            source: source
        ))
    }

    init(book: Book, chapters: [BookChapter], initialIndex: Int, usesEPUBLayout: Bool = true) {
        self.usesEPUBLayout = usesEPUBLayout
        _pageAnimation = State(initialValue: book.readConfig?.pageAnim.flatMap { $0 >= 0 ? $0 : nil }
            ?? Self.globalPageAnimation())
        _model = StateObject(wrappedValue: ReaderViewModel(
            book: book,
            chapters: chapters,
            initialIndex: initialIndex
        ))
    }

    init(demoBook book: Book, chapters: [BookChapter], initialIndex: Int, content: String) {
        var readerChapters = chapters
        var readerInitialIndex = initialIndex
        var readerContent = content
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-uiScrollRegression") {
            readerChapters = (0..<80).map {
                BookChapter(url: "demo://scroll/\($0)", title: "第\($0 + 1)章 · 连续阅读", bookUrl: book.bookUrl, index: $0)
            }
            readerInitialIndex = 20
            if arguments.contains("-uiShortChapters") { readerContent = "短章正文，继续向下可以自然读到下一章。" }
        }
        #endif
        _pageAnimation = State(initialValue: book.readConfig?.pageAnim.flatMap { $0 >= 0 ? $0 : nil }
            ?? Self.globalPageAnimation())
        #if DEBUG
        if arguments.contains("-uiReaderFailure") {
            _model = StateObject(wrappedValue: ReaderViewModel(
                book: book, chapters: readerChapters, initialIndex: readerInitialIndex,
                source: BookSource(bookSourceUrl: "https://reader-failure.invalid", bookSourceName: "正文失败测试源"),
                service: ReaderFailureTestLoader()
            ))
            return
        }
        #endif
        _model = StateObject(wrappedValue: ReaderViewModel(
            demoBook: book,
            chapters: readerChapters,
            initialIndex: readerInitialIndex,
            content: readerContent
        ))
    }


    var body: some View {
        if usesEPUBLayout, book.origin == "local", URL(string: book.bookUrl)?.pathExtension.lowercased() == "epub" {
            EPUBReaderView(book: book, chapters: model.chapters, initialIndex: model.currentIndex)
        } else {
            textReaderBody
        }
    }

    private var textReaderBody: some View {
        readerCanvas
        .preferredColorScheme(resolvedStyle.id == "night" ? .dark : .light)
        .readingTabBarHidden()
        .navigationBarBackButtonHidden(true)
        .background {
            ReaderInteractivePopEnabler()
                .frame(width: 0, height: 0)
        }
        .statusBarHidden(hideStatusBar)
        .readingHomeIndicatorHidden(hideHomeIndicator)
        .overlay(alignment: .top) {
            if showsReaderMenu {
                readerTopChrome
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.22), value: showsReaderMenu)
        .onAppear {
            activity.beginReading(book)
            speech.onNextChapter = { moveSpeechToChapter(direction: 1) }
            speech.onPreviousChapter = { moveSpeechToChapter(direction: -1) }
            speech.onRemoteStop = {
                speechTimerTask?.cancel()
                speechTimerRemaining = 0
                resumesSpeechAfterChapterLoad = false
            }
            UIDevice.current.isBatteryMonitoringEnabled = true
            brightnessBeforeReading = Double(UIScreen.main.brightness)
            if storedReaderBrightness > 0.05 {
                followsSystemBrightness = false
                readerBrightness = storedReaderBrightness
                UIScreen.main.brightness = CGFloat(storedReaderBrightness)
            } else {
                readerBrightness = brightnessBeforeReading
            }
            backgroundImage = ReaderBackgroundStore.load()
            ReaderScreenOrientation.apply(screenOrientation)
            // 进阅读页先按时间点判断一次：晚上打开直接是夜间，白天打开不会被上次的夜间主题粘住。
            applyAutoNightIfNeeded()
            Task { await loadHTTPEngines() }
            if ProcessInfo.processInfo.arguments.contains("-uiDemoBookmarks") {
                showsBookmarks = true
            }
            if ProcessInfo.processInfo.arguments.contains("-uiDemoReaderMenu") {
                showsReaderMenu = true
            }
            if ProcessInfo.processInfo.arguments.contains("-uiDemoReaderStyle") {
                DispatchQueue.main.async { showsStyleControls = true }
            }
        }
        .onDisappear {
            isAutoReading = false
            UIApplication.shared.isIdleTimerDisabled = false
            if speech.isSpeaking || speech.isPaused { speech.toggle(text: "") }
            saveProgress(immediate: true)
            ReaderScreenOrientation.restoreApplicationDefault()
            activity.cancelReading(book)
            UIDevice.current.isBatteryMonitoringEnabled = false
            if !followsSystemBrightness {
                UIScreen.main.brightness = CGFloat(brightnessBeforeReading)
            }
            speechTimerTask?.cancel()
            speechTimerRemaining = 0
            speech.onNextChapter = nil
            speech.onPreviousChapter = nil
            speech.onRemoteStop = nil
        }
        .overlay(alignment: .bottom) {
            if showsReaderMenu {
                readerBottomChrome
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(isPresented: $showsTableOfContents) { tableOfContents }
        .sheet(isPresented: $showsBookmarks) { bookmarksSheet }
        .sheet(item: $illustrationChapter) { chapter in
            EPUBIllustrationsView(book: book, chapter: chapter)
        }
        .sheet(isPresented: $showsAutoReadControls) { autoReadControls }
        .sheet(isPresented: $showsStyleControls) { styleControls }
        .sheet(isPresented: $showsContentSearch) { contentSearchSheet }
        .sheet(item: $sourceSwitchBook) { currentBook in
            ReadingNavigationStack {
                SourceSwitchView(book: currentBook, sources: sourceLibrary.sources) { report, source in
                    Task {
                        await progressSaveTask?.value
                        await activity.endReading(book)
                        await library.replace(oldBookURL: book.bookUrl, with: report.book)
                        model.applySourceSwitch(report, source: source)
                        readerPosition = report.book.durChapterPos
                        readerJumpPosition = nil
                        readerPageRanges = []
                        readerRenderRevision &+= 1
                        activity.beginReading(report.book)
                    }
                }
            }
        }
        .sheet(isPresented: $showsReplaceRules) {
            ReadingNavigationStack { ReplaceRuleManagementView() }
        }
        .sheet(isPresented: $showsReaderSettings) { readerSettings }
        .sheet(isPresented: $showsClickActionSettings) { clickActionSettings }
        .sheet(isPresented: $showsContentEditor) { contentEditor }
        .sheet(isPresented: $showsBookInfo) { bookInfoSheet }
        .sheet(isPresented: $showsTitleDesigner) { titleDesignerSheet }
        .task(id: model.chapterLoadGeneration) {
            isWaitingForNextChapter = false
            isWaitingForPreviousChapter = false
            let needsInitialPosition = !model.hasLoadedCurrentChapter
            if let pending = progressSaveTask {
                let pendingGeneration = progressSaveGeneration
                await pending.value
                // A newer page callback may have scheduled another save while
                // this chapter task was waiting. Never erase that newer task's
                // handle, or a subsequent chapter transition could skip it.
                if progressSaveGeneration == pendingGeneration {
                    progressSaveTask = nil
                }
            }
            readerJumpPosition = nil
            readerPageRanges = []
            if needsInitialPosition { readerPosition = model.requestedPosition }
            await model.load(rules: model.usesReplaceRules ? replaceRules.rules : [], prefetchNextChapter: pageAnimation != 3)
            guard !Task.isCancelled else { return }
            if needsInitialPosition {
                readerPosition = pageAnimation == 3
                    ? continuousPosition(model.requestedPosition, content: model.content)
                    : min(model.requestedPosition, max(model.content.utf16.count - 1, 0))
            }
            if let chapter = model.currentChapter {
                await library.updateProgress(for: book, chapter: chapter, position: readerPosition)
            }
            if resumesSpeechAfterChapterLoad, !model.content.isEmpty {
                resumesSpeechAfterChapterLoad = false
                startConfiguredSpeech()
            }
        }
        .task(id: "\(model.chapterLoadGeneration):\(pageAnimation):\(model.hasLoadedCurrentChapter):\(model.scrollRevision)") {
            if pageAnimation == 3 {
                await model.prepareContinuousReading(rules: model.usesReplaceRules ? replaceRules.rules : [])
                return
            }
            // 仿真翻页也要先备好相邻章：章界要退化成一次普通拖拽卷页，「上一章末页 +
            // 本章各页 + 下一章首页」就得在同一份页序里排好，正文必须已经在手。
            // 以前只有滚动模式预取，仿真到章界才发请求 —— 那正是「章界只能程序化转场」
            // 的物理原因，也是落页 / 方向 / 重投一类问题的总源头。
            if pageAnimation == 2 {
                await model.loadAdjacentChapters(rules: model.usesReplaceRules ? replaceRules.rules : [])
            }
        }
        .onAppear { updateIdleTimer() }
        .onChange(of: keepScreenOn) { _ in
            updateIdleTimer()
        }
        .onChange(of: adjacentReadiness) { _ in
            if model.isContinuationWindowReady, isWaitingForNextChapter {
                isWaitingForNextChapter = false
                readerRenderRevision &+= 1
            }
            if model.isPreviousWindowReady, isWaitingForPreviousChapter {
                advanceToPreparedPreviousChapter()
            }
        }
        .onChange(of: isAutoReading) { _ in
            updateIdleTimer()
        }
        .onChange(of: speech.isSpeaking) { _ in
            updateIdleTimer()
        }
        .onChange(of: speech.completionCount) { _ in
            if readAloudByPage {
                continueSpeechToNextPage()
            } else {
                continueSpeechToNextChapter()
            }
        }
        .onChange(of: speech.currentSegmentIndex) { index in
            guard model.paragraphs.indices.contains(index), !readAloudByPage else { return }
            readerJumpPosition = nil
            DispatchQueue.main.async { readerJumpPosition = model.paragraphs[index].id }
        }
        .onChange(of: readAloudByPage) { _ in
            restartSpeechAfterReaderLayoutChange()
        }
        .onChange(of: readAloudWakeLock) { _ in
            updateIdleTimer()
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active {
                // 回到前台再判断一次：阅读页可能在后台挂了整晚。
                applyAutoNightIfNeeded()
                if !followsSystemBrightness {
                    UIScreen.main.brightness = CGFloat(readerBrightness)
                }
                activity.beginReading(book)
            } else {
                isAutoReading = false
                if !followsSystemBrightness {
                    UIScreen.main.brightness = CGFloat(brightnessBeforeReading)
                }
                saveProgress(immediate: true)
                activity.cancelReading(book)
            }
        }
        .onChange(of: screenOrientation) { value in
            ReaderScreenOrientation.apply(value)
        }
        .onChange(of: themeMode) { _ in
            isAutoReading = false
            readerJumpPosition = nil
            currentPage = 1
            totalPages = 1
        }
        .onChange(of: pageAnimation) { value in
            isAutoReading = false
            saveProgress(immediate: true)
            readerJumpPosition = readerPosition
            currentPage = 1
            totalPages = 1
            UserDefaults.standard.set(value, forKey: "pageAnim")
            let updatedBook = model.useGlobalPageAnimation()
            Task { await library.addOrUpdate(updatedBook) }
        }
    }


    private var readerCanvas: some View {
        ZStack {
            readerContent
            readerMenuDismissOverlay
        }
        .background {
            ZStack {
                backgroundColor
                if let backgroundImage = activeBackgroundImage {
                    Image(uiImage: backgroundImage)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipped()
            .ignoresSafeArea()
        }
    }

    @ViewBuilder private var readerContent: some View {
        if pageAnimation != 3,
           !showsCurlPages,
           (model.isLoading && model.content.isEmpty) || (model.content.isEmpty && !model.hasLoadedCurrentChapter) {
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.regular)
                Text("正在打开本章")
                    .font(.subheadline.weight(.medium))
                Text(model.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(foregroundColor)
            .background(backgroundColor.ignoresSafeArea())
            .contentShape(Rectangle())
            .onTapGesture { showsReaderMenu.toggle() }
            .transition(.opacity)
        } else if pageAnimation != 3, model.content.isEmpty && model.hasLoadedCurrentChapter {
            VStack(spacing: 18) {
                Image(systemName: "text.page.slash").font(.largeTitle)
                Text(model.currentChapterError == nil ? "正文为空" : "本章加载失败").font(.title3.weight(.semibold))
                Text(model.currentChapterError ?? "本章暂无正文。")
                    .font(.subheadline).multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                readerRecoveryActions
                Button("打开阅读菜单") { showsReaderMenu = true }
                    .accessibilityIdentifier("reader.failureMenu")
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(foregroundColor)
            .background(backgroundColor.ignoresSafeArea())
        } else {
            VStack(spacing: 0) {
                // 仿真翻页的页眉页脚画在每一页里（跟着纸页一起卷），
                // 外层这两条停画，否则同一屏会出现两份。
                if headerVisible, pageAnimation != 2 { readerTipBar(isHeader: true) }
                readerSurface
                if footerVisible, pageAnimation != 2 { readerTipBar(isHeader: false) }
            }
            .frame(maxWidth: readingColumnMaxWidth)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .bottom) {
                if let error = model.currentChapterError, !showsReaderMenu {
                    VStack(spacing: 10) {
                        Text(model.content.isEmpty ? "本章加载失败" : "本章加载不完整").font(.subheadline.weight(.semibold))
                        Text(error).font(.caption).lineLimit(2).multilineTextAlignment(.center)
                        readerRecoveryActions
                        Button("打开阅读菜单") { showsReaderMenu = true }
                            .accessibilityIdentifier("reader.failureMenu")
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(foregroundColor)
                    .background(backgroundColor)
                }
            }
        }
    }

    private var readerRecoveryActions: some View {
        HStack(spacing: 16) {
            Button {
                Task {
                    if pageAnimation == 3, model.scrollChapters.contains(where: { $0.id == model.currentIndex }) {
                        await model.retryContinuousChapter(index: model.currentIndex, rules: model.usesReplaceRules ? replaceRules.rules : [])
                    } else {
                        await model.load(rules: model.usesReplaceRules ? replaceRules.rules : [], forceRefresh: true)
                    }
                }
            } label: {
                Label(model.scrollRetries.contains(model.currentIndex) ? "重试中…" : "重试本章", systemImage: "arrow.clockwise")
            }
            .disabled(model.isLoading || model.scrollRetries.contains(model.currentIndex))
            .accessibilityIdentifier("reader.retryChapter")
            if model.canEditContent {
                Button(action: openSourceSwitch) {
                    Label("换源", systemImage: "arrow.triangle.2.circlepath")
                }
                .accessibilityIdentifier("reader.failureChangeSource")
            }
        }
        .readingSecondaryButtonStyle()
    }

    private func openSourceSwitch() {
        stopSpeechIfNeeded()
        isAutoReading = false
        saveProgress(immediate: true)
        showsReaderMenu = false
        sourceSwitchBook = model.bookForSourceSwitch(position: readerPosition)
    }

    @ViewBuilder private var readerSurface: some View {
        if pageAnimation == 3 {
            ReaderScrollView(
                configuration: readerTextConfiguration,
                chapters: model.scrollChapters,
                resetID: model.scrollRevision,
                activeIndex: model.currentIndex,
                loadingAhead: model.isLoadingScrollAhead,
                loadingBehind: model.isLoadingScrollBehind,
                onNeedChapters: { direction in
                    Task { await model.extendContinuousReading(direction: direction, rules: model.usesReplaceRules ? replaceRules.rules : []) }
                },
                onPositionChanged: { index, position in
                    if index != model.currentIndex {
                        saveProgress(immediate: true)
                        model.updateContinuousPosition(chapter: index)
                        readerJumpPosition = nil
                    }
                    let resolved = min(max(position, 0), model.content.utf16.count)
                    if readerPosition != resolved { readerPosition = resolved }
                },
                onRetainChapters: { model.retainContinuousChapters($0) }
            )
        } else {
            readerTextConfiguration
        }
    }

    /// 相邻章正文要不要交给正文层。
    ///
    /// 以前只有滚动模式（`pageAnimation == 3`）拿得到，仿真模式一律给空串 —— 于是仿真
    /// 的章界只能是「本章翻到头 → 发起换章 → 等正文 → 程序化转场」，那是所有落页 /
    /// 方向 / 重投问题的总源头。仿真要根治，就必须和滚动一样先把相邻章正文握在手里，
    /// 才能把「上一章末页 + 本章各页 + 下一章首页」拼进同一份扁平页序。
    private var usesAdjacentWindows: Bool { pageAnimation == 2 || pageAnimation == 3 }

    private var readerTextConfiguration: ReaderTextView {
        ReaderTextView(
            text: readerDisplayText,
            title: model.title,
            previousTitle: usesAdjacentWindows ? model.previousTitle : nil,
            previousText: usesAdjacentWindows ? model.previousContent : "",
            isPreviousReady: usesAdjacentWindows && model.isPreviousWindowReady,
            continuationTitle: usesAdjacentWindows ? model.continuationTitle : nil,
            continuationText: usesAdjacentWindows ? model.continuationContent : "",
            isContinuationReady: usesAdjacentWindows && model.isContinuationWindowReady,
            chapterIndex: model.currentIndex,
            isVolume: model.currentChapter?.isVolume == true,
            fontSize: fontSize,
            fontPath: fontPath,
            letterSpacing: letterSpacing,
            lineSpacing: lineSpacing,
            paragraphSpacing: paragraphSpacing,
            paragraphIndent: paragraphIndent,
            paddingLeft: paddingLeft,
            paddingRight: paddingRight,
            paddingTop: paddingTop,
            paddingBottom: paddingBottom,
            headerInset: simulationHeaderInset,
            footerInset: simulationFooterInset,
            headerBar: simulationHeaderBar,
            footerBar: simulationFooterBar,
            fontWeight: fontWeight,
            titleMode: titleMode,
            titleSize: titleSize,
            titleTopSpacing: titleTopSpacing,
            titleBottomSpacing: titleBottomSpacing,
            underlineMode: underlineMode,
            justifyLastPage: justifyLastPage,
            punctuationKinsoku: punctuationKinsoku,
            smartParagraphs: smartParagraphs,
            chineseConversion: chineseConversion,
            underlinePattern: underlinePattern,
            paragraphSeparatorLines: paragraphSeparatorLines,
            titleHTMLTemplate: chapterTitleHTMLTemplate,
            titleProjectJSON: chapterTitleProjectJSON,
            titleCanvasHeight: chapterTitleCanvasHeight,
            isSelectable: false,
            fullJustify: fullJustify,
            pageAnimation: pageAnimation,
            isEInkMode: themeMode == "3",
            clickActions: clickActions,
            backgroundColor: activeBackgroundImage == nil ? resolvedStyle.background : .clear,
            backgroundImage: activeBackgroundImage,
            foregroundColor: resolvedStyle.foreground,
            requestedPosition: pageAnimation == 3 ? readerPosition : model.requestedPosition,
            jumpPosition: readerJumpPosition,
            renderRevision: readerRenderRevision,
            readerPosition: $readerPosition,
            pageRanges: $readerPageRanges,
            currentPage: $currentPage,
            totalPages: $totalPages,
            isAutoReading: isAutoReading,
            isAutoReadPaused: pausesAutoReading,
            isLoadingNextChapter: isWaitingForNextChapter,
            secondsPerScreen: Double(autoReadSpeed),
            onReachedEnd: { boundaryPosition in
                if pageAnimation == 3 {
                    requestNextChapter()
                    return
                }
                // 仿真模式：页序走到头只意味着「下一段正文还没拼进来」，不是换章信号。
                // 换章由页序里的下一页承担（读者继续拖过去），这里只补预取 ——
                // 旧的「闸门 + goNext」是一次程序化换章，正是「落页靠猜」那条老路的
                // 残留，已整段删除，不再兜底。
                readerPosition = boundaryPosition
                saveProgress(immediate: true)
                readerJumpPosition = nil
                if model.canGoNext {
                    Task {
                        await model.loadAdjacentChapters(rules: model.usesReplaceRules ? replaceRules.rules : [])
                    }
                } else {
                    isAutoReading = false
                }
            },
            onReachedStart: { boundaryPosition in
                if pageAnimation == 3 {
                    requestPreviousChapter()
                    return
                }
                guard model.canGoPrevious else { return }
                readerPosition = boundaryPosition
                saveProgress(immediate: true)
                readerJumpPosition = nil
                Task {
                    await model.loadAdjacentChapters(rules: model.usesReplaceRules ? replaceRules.rules : [])
                }
            },
            onEnteredPrevious: { position in
                guard model.canGoPrevious, model.hasPreviousWindow else { return }
                saveProgress(immediate: true)
                readerJumpPosition = nil
                // 仿真模式：读者是把上一章的某一页「继续拖」过来的，章内页号由正文层
                // 记着并在下一帧按它落位；这里只把进度存档点交出去。
                readerPosition = pageAnimation == 3
                    ? continuousPosition(position, content: model.previousContent)
                    : 0
                model.promotePrevious(position: readerPosition)
            },
            onEnteredContinuation: { position in
                guard model.canGoNext, model.hasContinuationWindow else { return }
                saveProgress(immediate: true)
                readerJumpPosition = nil
                readerPosition = pageAnimation == 3
                    ? continuousPosition(position, content: model.continuationContent)
                    : 0
                model.promoteContinuation(position: readerPosition)
            },
            onDeferredRender: { readerRenderRevision &+= 1 },
            onCancelNextLoading: { isWaitingForNextChapter = false },
            onPageChanged: pageDidChange,
            onTapAction: handleTapAction,
            onCurlPublished: { curlPublishedPages = $0 }
        )
    }

    @ViewBuilder private var readerMenuDismissOverlay: some View {
        if showsReaderMenu {
            Color.black
                .opacity(resolvedStyle.id == "night" ? 0.08 : 0.03)
                .ignoresSafeArea()
                .contentShape(ReaderMenuDismissShape())
                .onTapGesture { showsReaderMenu = false }
                .accessibilityHidden(true)
        }
    }

    private var readingColumnMaxWidth: CGFloat {
        UIDevice.current.userInterfaceIdiom == .pad ? 760 : .greatestFiniteMagnitude
    }

    private var adjacentReadiness: Int {
        (model.isPreviousWindowReady ? 1 : 0) | (model.isContinuationWindowReady ? 2 : 0)
    }

    /// 仿真模式下卷页层已在屏上：换章那一帧不盖加载提示，旧页继续留在屏上，
    /// 新章分页就绪后由卷页层按方向卷过去。
    private var showsCurlPages: Bool {
        pageAnimation == 2 && curlPublishedPages
    }

    private var readerDisplayText: String {
        if !model.content.isEmpty { return model.content }
        if pageAnimation == 3 {
            return String(repeating: "\n", count: 80)
        }
        // 仿真翻页：换章那一帧新章正文还没到，旧页要继续留在屏上。
        //
        // 这里若递进「正文正在后台加载…」那句占位串，卷页层会拿它换一次页面集合 ——
        // 观感就是「章末翻到下一章时整屏刷新重载了一下」，而不是卷过去。真正文到达时
        // 再换一次页面集合，那一次才是带方向的卷页动画。
        if pageAnimation == 2 {
            return ""
        }
        if model.isLoading || !model.hasLoadedCurrentChapter {
            return "正文正在后台加载…\n\n你可以继续向下滚动，下一章已经提前生成。"
        }
        let reason = model.diagnostics.first?.message ?? "当前书源没有返回正文。"
        return "本章加载失败\n\n\(reason)\n\n本章位置会保留，请继续向下进入下一章。"
    }

    private func continuousPosition(_ position: Int, content: String) -> Int {
        let length = content.isEmpty ? 80 : content.utf16.count
        return min(max(position, 0), max(length - 1, 0))
    }

    private var activeBackgroundImage: UIImage? {
        themeMode != "3" && useBackgroundImage ? backgroundImage : nil
    }

    private var backgroundColor: Color {
        Color(uiColor: resolvedStyle.background)
    }

    private var foregroundColor: Color {
        Color(uiColor: resolvedStyle.foreground)
    }

    private var resolvedStyle: ReaderStylePreset {
        themeMode == "3" ? .eInk : ReaderStylePreset.resolve(theme)
    }

    /// 仿真翻页把页眉页脚画进每一页里（跟着纸页一起卷），所以两栏高度要作为
    /// 正文内边距预留出来，否则栏会压住首行 / 末行。
    private var simulationHeaderInset: Double {
        guard let bar = simulationHeaderBar else { return 0 }
        return Double(bar.gap + ReaderCurlBarSpec.height)
    }

    private var simulationFooterInset: Double {
        guard let bar = simulationFooterBar else { return 0 }
        return Double(bar.gap + ReaderCurlBarSpec.height)
    }

    /// 页内页眉：口径与设置里的页眉一致（左 / 中 / 右三栏、分隔线、边距）。
    private var simulationHeaderBar: ReaderCurlBarSpec? {
        guard pageAnimation == 2, headerVisible else { return nil }
        let now = Date()
        return ReaderCurlBarSpec(
            left: barTemplate(barHeaderLeft, date: now),
            middle: barTemplate(barHeaderMiddle, date: now),
            right: barTemplate(barHeaderRight, date: now),
            textColor: resolvedStyle.foreground,
            gap: headerPaddingTop,
            leftInset: headerPaddingLeft,
            rightInset: headerPaddingRight,
            showsDivider: showHeaderLine,
            dividerOnBottom: true
        )
    }

    /// 页内页脚：同上，分隔线贴正文在上沿。
    private var simulationFooterBar: ReaderCurlBarSpec? {
        guard pageAnimation == 2, footerVisible else { return nil }
        let now = Date()
        return ReaderCurlBarSpec(
            left: barTemplate(barFooterLeft, date: now),
            middle: barTemplate(barFooterMiddle, date: now),
            right: barTemplate(barFooterRight, date: now),
            textColor: resolvedStyle.foreground,
            gap: footerPaddingBottom,
            leftInset: footerPaddingLeft,
            rightInset: footerPaddingRight,
            showsDivider: showFooterLine,
            dividerOnBottom: false
        )
    }

    /// 页内栏的一栏文案：一栏可填多个条目，按顺序拼起来。
    private func barTemplate(_ raw: String, date: Date) -> String {
        let items = ReaderBarContent.decode(raw)
        guard !items.isEmpty else { return "" }
        return items.map { barTemplate($0) }.joined(separator: "  ")
    }

    /// 单个条目的页内文案：页码类用 `{page}` / `{pages}` 占位（活页按页盖章），
    /// 图形类退成文字（页内栏画不了图形）。
    private func barTemplate(_ content: ReaderBarContent) -> String {
        switch content {
        case .pageInfo, .pagePercent:
            return "{page}/{pages}"
        case .pageNumberLabel:
            return "第 {page} 页"
        case .none:
            return ""
        default:
            return content.plainText(readerBarContext)
        }
    }

    private var headerVisible: Bool {
        switch headerMode {
        case 1: true
        case 2: false
        default: hideStatusBar
        }
    }

    private var footerVisible: Bool { footerMode == 0 }

    private var pausesAutoReading: Bool {
        isWaitingForNextChapter
            || isWaitingForPreviousChapter
            || showsReaderMenu
            || showsTableOfContents
            || showsBookmarks
            || illustrationChapter != nil
            || showsAutoReadControls
            || showsStyleControls
            || showsContentSearch
            || showsReplaceRules
            || showsReaderSettings
            || showsClickActionSettings
            || showsContentEditor
    }


    private func readerTipBar(isHeader: Bool) -> some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            readerTipRow(
                isHeader
                    ? [barHeaderLeft, barHeaderMiddle, barHeaderRight]
                    : [barFooterLeft, barFooterMiddle, barFooterRight],
                date: context.date,
                showDivider: isHeader ? showHeaderLine : showFooterLine,
                isHeader: isHeader
            )
            .padding(.top, isHeader ? headerPaddingTop : footerPaddingTop)
            .padding(.bottom, isHeader ? headerPaddingBottom : footerPaddingBottom)
        }
        .allowsHitTesting(false)
    }

    private func readerTipRow(_ slots: [String], date: Date, showDivider: Bool, isHeader: Bool) -> some View {
        HStack(spacing: 8) {
            barSlot(ReaderBarContent.decode(slots[0]), alignment: .leading)
            barSlot(ReaderBarContent.decode(slots[1]), alignment: .center)
            barSlot(ReaderBarContent.decode(slots[2]), alignment: .trailing)
        }
        .font(.system(size: 12))
        .foregroundStyle(foregroundColor)
        .lineLimit(1)
        .padding(.leading, isHeader ? headerPaddingLeft : footerPaddingLeft)
        .padding(.trailing, isHeader ? headerPaddingRight : footerPaddingRight)
        .overlay(alignment: .bottom) {
            if showDivider { Divider().overlay(foregroundColor.opacity(0.35)) }
        }
    }

    /// 一栏可以有多个条目：按顺序排，图形项单独画。
    @ViewBuilder
    private func barSlot(_ items: [ReaderBarContent], alignment: Alignment) -> some View {
        let visible = items.filter { $0 != .none }
        if visible.isEmpty {
            Color.clear.frame(maxWidth: .infinity)
        } else {
            HStack(spacing: 6) {
                ForEach(Array(visible.enumerated()), id: \.offset) { _, item in
                    barSlotView(item)
                }
            }
            .frame(maxWidth: .infinity, alignment: alignment)
        }
    }

    /// 单个条目：电量图标 / 电量条 / 总进度条画图形，其余照 `readerBarText` 出文字。
    @ViewBuilder
    private func barSlotView(_ content: ReaderBarContent) -> some View {
        switch content {
        case .bookPercentBar:
            barCapacitor(fraction: chapterProgress)
        case .batteryBar:
            barCapacitor(fraction: ReaderBarBattery.level() ?? 0)
        case .batteryIcon:
            Image(systemName: ReaderBarBattery.symbolName(for: ReaderBarBattery.level()))
                .font(.system(size: 11))
        case .batteryGlyphWithPercent:
            HStack(spacing: 3) {
                Image(systemName: ReaderBarBattery.symbolName(for: ReaderBarBattery.level()))
                    .font(.system(size: 11))
                Text(readerBarText(content, readerBarContext))
            }
        default:
            Text(readerBarText(content, readerBarContext))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    /// 电量条 / 总进度条：固定 44×3，太长会把一栏整个占满。
    private func barCapacitor(fraction: Double) -> some View {
        ZStack(alignment: .leading) {
            Capsule().fill(foregroundColor.opacity(0.18))
            GeometryReader { geo in
                Capsule()
                    .fill(foregroundColor.opacity(0.65))
                    .frame(width: geo.size.width * CGFloat(max(0, min(1, fraction))), height: 3)
            }
        }
        .frame(width: 44, height: 3)
    }

    /// 页栏取值的输入：格式化交给共用的 `readerBarText`，滚动 / 分页 / 仿真三条路径同一套。
    private var readerBarContext: ReaderBarContext {
        var ctx = ReaderBarContext()
        ctx.bookName = book.name
        ctx.chapterTitle = model.title
        ctx.chapterIndex = readableChapterIndex
        ctx.chapterCount = max(readableChapterCount, 1)
        ctx.pageIndex = max(currentPage - 1, 0)
        ctx.pageCount = max(totalPages, 1)
        ctx.isPaged = pageAnimation != 3
        ctx.bookProgress = chapterProgress
        ctx.sessionStart = barSessionStart
        ctx.shortTitleLength = barShortTitleLength
        ctx.customDatePattern = barCustomDatePattern
        ctx.customBarText = barCustomText
        return ctx
    }

    /// 可读章总数（不含卷）：页栏的「共 N 章」「N 章」都用它。
    private var readableChapterCount: Int {
        model.chapters.filter { !$0.isVolume }.count
    }

    /// 已读到的非卷章序号（0 基）：只用前缀，避免把后面所有章都数进来。
    private var readableChapterIndex: Int {
        let count = model.chapters.prefix(model.currentIndex + 1).filter { !$0.isVolume }.count
        return max(count - 1, 0)
    }

    /// 旧版六个整数码 → 新的条目数组，只在第一次进阅读页时搬一次。
    /// 老用户存的是 `tipHeaderLeft = 2` 这类整数；没有对应项就映射成空栏，不去猜他想要什么。
    private static func migrateBarSettingsIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "readerBarMigrated") == nil else { return }
        defaults.set(true, forKey: "readerBarMigrated")
        let pairs: [(key: String, legacy: String, fallback: Int)] = [
            ("readerBarHeaderLeft", "tipHeaderLeft", 2),
            ("readerBarHeaderMiddle", "tipHeaderMiddle", 0),
            ("readerBarHeaderRight", "tipHeaderRight", 3),
            ("readerBarFooterLeft", "tipFooterLeft", 1),
            ("readerBarFooterMiddle", "tipFooterMiddle", 0),
            ("readerBarFooterRight", "tipFooterRight", 6)
        ]
        for pair in pairs where defaults.string(forKey: pair.key) == nil {
            let code = defaults.object(forKey: pair.legacy) != nil
                ? defaults.integer(forKey: pair.legacy)
                : pair.fallback
            defaults.set(ReaderBarContent.encode(ReaderBarContent.legacy(code)), forKey: pair.key)
        }
    }

    private var readerChromeTint: Color {
        .primary
    }

    @ViewBuilder private var readerChromeBackground: some View {
        if resolvedStyle.id == "night" {
            Color(uiColor: .secondarySystemBackground)
        } else {
            Color(uiColor: .systemBackground)
        }
    }

    private var chapterProgress: Double {
        let chapter = max(model.chapters.filter { !$0.isVolume }.count, 1)
        let readable = model.chapters.prefix(model.currentIndex + 1).filter { !$0.isVolume }.count
        let pagePart = chapterPageFraction
        return min(max((Double(max(readable - 1, 0)) + pagePart) / Double(chapter), 0), 1)
    }

    private var chapterPageFraction: Double {
        guard totalPages > 1 else { return 1 }
        return min(max(Double(max(currentPage - 1, 0)) / Double(totalPages - 1), 0), 1)
    }


    private var readerTopChrome: some View {
        HStack(spacing: 4) {
            readerChromeIconButton("chevron.backward", label: "返回") { dismiss() }
            VStack(alignment: .leading, spacing: 3) {
                Text(book.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(model.title).lineLimit(1)
                    if model.loadedFromCache {
                        Image(systemName: "arrow.down.circle")
                            .accessibilityLabel("已缓存")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            readerChromeIconButton(bookmarkSaved ? "bookmark.fill" : "bookmark", label: "书签") {
                addBookmark()
            }
            .accessibilityValue(bookmarkSaved ? "已添加" : "添加当前位置")
            .disabled(isSavingBookmark)
            readerMoreMenu
        }
        .foregroundStyle(readerChromeTint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .background { readerChromeBackground.ignoresSafeArea(edges: .top) }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(uiColor: .separator).opacity(0.35)).frame(height: 0.5)
        }
    }

    private var readerMoreMenu: some View {
        Menu {
            Button("搜索正文", systemImage: "magnifyingglass") {
                showsReaderMenu = false
                showsContentSearch = true
            }
            if book.origin == "local", URL(string: book.bookUrl)?.pathExtension.lowercased() == "epub" {
                Button("本章插图", systemImage: "photo.on.rectangle") {
                    showsReaderMenu = false
                    illustrationChapter = model.currentChapter
                }
            }
            Button("书签列表", systemImage: "bookmark") {
                showsReaderMenu = false
                showsBookmarks = true
            }
            Button("书籍信息", systemImage: "info.circle") {
                showsReaderMenu = false
                showsBookInfo = true
            }
            Button(isAutoReading ? "停止自动阅读" : "自动阅读", systemImage: isAutoReading ? "stop" : "play") {
                if isAutoReading {
                    isAutoReading = false
                } else {
                    showsReaderMenu = false
                    showsAutoReadControls = true
                }
            }
            Divider()
            Button(resolvedStyle.id == "night" ? "切换为日间" : "切换为夜间", systemImage: resolvedStyle.id == "night" ? "sun.max" : "moon") {
                toggleNightTheme()
            }
            .disabled(themeMode == "3")
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 20, weight: .regular))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("更多")
    }

    private var readerBottomChrome: some View {
        VStack(spacing: 12) {
            readerChapterControls
            Rectangle().fill(Color(uiColor: .separator).opacity(0.35)).frame(height: 0.5)
            LazyVGrid(columns: readerToolbarColumns, spacing: 12) {
                readerChromeAction("list.bullet", "目录") {
                    showsReaderMenu = false
                    showsTableOfContents = true
                }
                if model.canEditContent {
                    readerChromeAction("arrow.triangle.2.circlepath", "换源", action: openSourceSwitch)
                    .accessibilityIdentifier("reader.changeSource")
                    .accessibilityValue(book.originName)
                }
                readerChromeAction(speech.isSpeaking ? "stop" : "headphones", speech.isSpeaking ? "停止" : "朗读", isActive: speech.isSpeaking) { toggleSpeech() }
                readerChromeAction("textformat.size", "外观") {
                    showsReaderMenu = false
                    showsStyleControls = true
                }
                readerChromeAction("gearshape", "设置") {
                    showsReaderMenu = false
                    showsReaderSettings = true
                }
            }
        }
        .foregroundStyle(readerChromeTint)
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .background { readerChromeBackground.ignoresSafeArea(edges: .bottom) }
        .overlay(alignment: .top) {
            Rectangle().fill(Color(uiColor: .separator).opacity(0.35)).frame(height: 0.5)
        }
    }

    private var readerToolbarColumns: [GridItem] {
        let count = dynamicTypeSize.isAccessibilitySize ? (model.canEditContent ? 3 : 2) : (model.canEditContent ? 5 : 4)
        return Array(repeating: GridItem(.flexible(), spacing: 0), count: count)
    }

    private var readerChapterControls: some View {
        HStack(spacing: 16) {
            readerChromeIconButton("chevron.left", label: "上一章") { moveChapter(-1) }
                .disabled(!model.canGoPrevious)
                .opacity(model.canGoPrevious ? 1 : 0.25)
            VStack(spacing: 8) {
                HStack {
                    let chapterCount = model.chapters.filter { !$0.isVolume }.count
                    let chapterNumber = model.chapters.prefix(model.currentIndex + 1).filter { !$0.isVolume }.count
                    if #available(iOS 16.0, *) {
                        ViewThatFits(in: .horizontal) {
                            Text("第 \(chapterNumber) 章 / 共 \(chapterCount) 章").fixedSize()
                            Text("\(chapterNumber) / \(chapterCount) 章").fixedSize()
                        }
                    } else {
                        Text("\(chapterNumber) / \(chapterCount) 章").fixedSize()
                    }
                    Spacer(minLength: 8)
                    Text(chapterProgress, format: .percent.precision(.fractionLength(0)))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                ProgressView(value: chapterProgress)
                    .tint(readerChromeTint)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("阅读进度")
            .accessibilityValue(chapterProgress.formatted(.percent.precision(.fractionLength(0))))
            readerChromeIconButton("chevron.right", label: "下一章") { moveChapter(1) }
                .disabled(!model.canGoNext)
                .opacity(model.canGoNext ? 1 : 0.25)
        }
    }

    private func readerChromeIconButton(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .regular))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private func readerChromeAction(_ icon: String, _ title: String, isActive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: min(toolbarIconSize, 28), weight: .regular))
                    .frame(height: 28)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(isActive ? Color.primary : .secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private var readerBrightnessBinding: Binding<Double> {
        Binding(
            get: { readerBrightness },
            set: { value in
                followsSystemBrightness = false
                readerBrightness = value
                storedReaderBrightness = value
                UIScreen.main.brightness = CGFloat(value)
            }
        )
    }

    private func toggleNightTheme() {
        if resolvedStyle.id == "night" {
            theme = previousDayTheme == "night" ? "wechat" : previousDayTheme
        } else {
            previousDayTheme = resolvedStyle.id
            theme = "night"
        }
    }

    /// 自动夜间（Juyue `autoNight`）：22:00–07:00 用夜间主题，其余时段还原成进入夜间前的那套主题。
    ///
    /// 切之前先记到 `previousDayTheme`，所以「先手动切夜间、再叠自动夜间」也不会把白天的
    /// 主题弄丢；E-Ink 模式（`themeMode == "3"`）不参与，它有自己的黑白纸面。
    private func applyAutoNightIfNeeded() {
        guard autoNight, themeMode != "3" else { return }
        let hour = Calendar.current.component(.hour, from: Date())
        let shouldBeNight = hour >= 22 || hour < 7
        if shouldBeNight, resolvedStyle.id != "night" {
            previousDayTheme = resolvedStyle.id
            theme = "night"
        } else if !shouldBeNight, resolvedStyle.id == "night" {
            theme = previousDayTheme == "night" ? "wechat" : previousDayTheme
        }
    }

    /// 书籍信息：书目元数据 + 阅读进度。字段与排版照本项目 `BookDetailView.hero`，
    /// 只读展示，不放「换源 / 缓存」这类动作 —— 那些在详情页里做，阅读页不该有第二个入口。
    private var bookInfoSheet: some View {
        ReadingNavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(alignment: .top, spacing: 16) {
                        BookCoverArtwork(
                            title: book.name,
                            author: book.author,
                            remoteURL: book.customCoverUrl ?? book.coverUrl,
                            width: 88,
                            height: 126
                        )
                        VStack(alignment: .leading, spacing: 8) {
                            Text(book.name)
                                .font(.title3.weight(.semibold))
                                .lineLimit(3)
                            Text(book.author.isEmpty ? "未知作者" : book.author)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            if let kind = book.kind, !kind.isEmpty {
                                Text(kind).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(book.originName.isEmpty ? book.origin : book.originName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }

                    Divider()

                    VStack(spacing: 10) {
                        bookInfoRow("阅读进度", "第 \(readableChapterIndex + 1) 章 / 共 \(max(readableChapterCount, 1)) 章")
                        bookInfoRow("当前章", model.title)
                        if let dur = book.durChapterTitle, !dur.isEmpty {
                            bookInfoRow("上次读到", dur)
                        }
                        bookInfoRow("总章数", "\(book.totalChapterNum) 章")
                        bookInfoRow("本章页数", "\(currentPage)/\(totalPages)")
                        if let words = book.wordCount, !words.isEmpty {
                            bookInfoRow("字数", words)
                        }
                        if let latest = book.latestChapterTitle, !latest.isEmpty {
                            bookInfoRow("最近更新", latest)
                        }
                        if let charset = book.charset, !charset.isEmpty {
                            bookInfoRow("编码", charset)
                        }
                        bookInfoRow("允许更新", book.canUpdate ? "是" : "否")
                    }

                    if let intro = MetadataTextSanitizer().clean(book.customIntro ?? book.intro), !intro.isEmpty {
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            Text("简介").font(.headline)
                            Text(intro)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineSpacing(5)
                        }
                    }
                }
                .padding(20)
            }
            .navigationTitle("书籍信息")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showsBookInfo = false }
                }
            }
        }
        .readingPresentationDetents([.medium, .large])
    }

    private func bookInfoRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.subheadline)
                .multilineTextAlignment(.trailing)
        }
    }

    /// 章节标题设计器：没有静态资源时给可读提示，而不是一张白页。
    @ViewBuilder private var titleDesignerSheet: some View {
        if ChapterTitleDesignerBundle.isAvailable {
            ChapterTitleDesignerView(
                initialProjectJSON: chapterTitleProjectJSON,
                isDark: resolvedStyle.id == "night"
            ) { export in
                chapterTitleHTMLTemplate = export.htmlTemplate
                chapterTitleProjectJSON = export.projectJSON
                chapterTitleCanvasHeight = export.canvasHeight
                // 换了设计稿：丢掉旧位图，否则会继续用上一版标题图。
                ReaderChapterTitleStore.shared.clear()
                readerRenderRevision &+= 1
            }
        } else {
            ReadingNavigationStack {
                VStack(spacing: 14) {
                    Image(systemName: "paintbrush").font(.largeTitle).foregroundStyle(.secondary)
                    Text("设计器页面没有打进 App 包")
                        .font(.headline)
                    Text("缺少 Resources/ChapterTitleDesigner/index.html。检查工程里的 ChapterTitleDesigner folder reference 是否进了 Resources 阶段。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                .navigationTitle("章节标题设计器")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { showsTitleDesigner = false }
                    }
                }
            }
            .readingPresentationDetents([.medium])
        }
    }

    private func moveChapter(_ direction: Int) {
        stopSpeechIfNeeded()
        showsReaderMenu = false
        saveProgress(immediate: true)
        readerJumpPosition = nil
        if direction < 0 { model.goPrevious() } else { model.goNext() }
        readerPosition = model.requestedPosition
    }

    private func requestNextChapter() {
        if pageAnimation == 3 {
            guard model.canGoNext else { isAutoReading = false; return }
            Task { await model.extendContinuousReading(direction: 1, rules: model.usesReplaceRules ? replaceRules.rules : []) }
            return
        }
        guard model.canGoNext, model.hasContinuationWindow else {
            isAutoReading = false
            return
        }
        if model.isContinuationWindowReady {
            isWaitingForNextChapter = false
            readerRenderRevision &+= 1
        } else {
            isWaitingForNextChapter = true
        }
    }

    private func requestPreviousChapter() {
        guard model.canGoPrevious, model.hasPreviousWindow else { return }
        if model.isPreviousWindowReady {
            advanceToPreparedPreviousChapter()
        } else {
            isWaitingForPreviousChapter = true
        }
    }

    private func advanceToPreparedPreviousChapter() {
        guard model.canGoPrevious, model.hasPreviousWindow, model.isPreviousWindowReady else { return }
        isWaitingForPreviousChapter = false
        saveProgress(immediate: true)
        readerJumpPosition = nil
        let position = max(model.previousContent.utf16.count - 1, 0)
        readerPosition = position
        model.promotePrevious(position: position)
    }

    private func startAutoReading() {
        stopSpeechIfNeeded()
        showsReaderMenu = false
        isAutoReading = true
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = keepScreenOn || isAutoReading
            || (readAloudWakeLock && speech.isSpeaking)
    }

    private func pageDidChange() {
        saveProgress()
        guard enableReadRecord else { return }
        Task { await activity.checkpoint(book) }
    }


    private var autoReadControls: some View {
        ReadingNavigationStack {
            Form {
                Section {
                    HStack {
                        Text("自动翻页速度")
                        Spacer()
                        Text("\(autoReadSpeed)s").monospacedDigit().foregroundStyle(.secondary)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(autoReadSpeed) },
                            set: { autoReadSpeed = max(1, min(Int($0.rounded()), 120)) }
                        ),
                        in: 1...120,
                        step: 1
                    )
                } footer: {
                    Text("数值表示自动阅读一屏所用的秒数，范围 1–120 秒。")
                }
                Section {
                    Button("目录", systemImage: "list.bullet") {
                        showsAutoReadControls = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { showsTableOfContents = true }
                    }
                    Button("开始自动阅读", systemImage: "play.fill") {
                        showsAutoReadControls = false
                        startAutoReading()
                    }
                    Button("主菜单", systemImage: "menubar.rectangle") {
                        showsAutoReadControls = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { showsReaderMenu = true }
                    }
                    Button("停止自动阅读", systemImage: "stop.fill", role: .destructive) {
                        isAutoReading = false
                        showsAutoReadControls = false
                    }
                    Button("设置", systemImage: "gearshape") {
                        showsAutoReadControls = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { showsStyleControls = true }
                    }
                }
            }
            .navigationTitle("自动阅读")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("继续阅读") { showsAutoReadControls = false }
                }
            }
        }
        .readingPresentationDetents([.medium])
    }


    private var styleControls: some View {
        ReadingNavigationStack {
            Form {
                Section("快速排版") {
                    HStack(spacing: 12) {
                        Button {
                            fontSize = max(5, fontSize - 1)
                        } label: {
                            Image(systemName: "textformat.size.smaller")
                                .frame(width: 38, height: 32)
                        }
                        .readingSecondaryButtonStyle()

                        VStack(spacing: 2) {
                            Text("字号")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("\(Int(fontSize))")
                                .font(.headline.monospacedDigit())
                        }
                        .frame(maxWidth: .infinity)

                        Button {
                            fontSize = min(50, fontSize + 1)
                        } label: {
                            Image(systemName: "textformat.size.larger")
                                .frame(width: 38, height: 32)
                        }
                        .readingSecondaryButtonStyle()
                    }

                    HStack(spacing: 8) {
                        Text("行距")
                            .font(.subheadline)
                        Spacer(minLength: 8)
                        readerChoiceChip("紧凑", selected: lineSpacing <= 7) { lineSpacing = 6 }
                        readerChoiceChip("标准", selected: lineSpacing > 7 && lineSpacing < 18) { lineSpacing = 12 }
                        readerChoiceChip("宽松", selected: lineSpacing >= 18) { lineSpacing = 22 }
                    }
                    Toggle("两端对齐", isOn: $fullJustify)
                }

                Section("阅读背景") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(ReaderStylePreset.legadoDefaults) { preset in
                                let isSelected = resolvedStyle.id == preset.id && activeBackgroundImage == nil
                                Button {
                                    useBackgroundImage = false
                                    theme = preset.id
                                } label: {
                                    VStack(spacing: 6) {
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .fill(Color(uiColor: preset.background))
                                            .frame(width: 54, height: 72)
                                            .overlay {
                                                Text("文字")
                                                    .font(.caption)
                                                    .foregroundStyle(Color(uiColor: preset.foreground))
                                            }
                                            .overlay {
                                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                                    .strokeBorder(
                                                        Color(uiColor: preset.foreground).opacity(isSelected ? 0.4 : 0.12),
                                                        lineWidth: isSelected ? 1.25 : 0.75
                                                    )
                                            }
                                            .overlay(alignment: .topTrailing) {
                                                if isSelected {
                                                    Image(systemName: "checkmark")
                                                        .font(.system(size: 10, weight: .semibold))
                                                        .foregroundStyle(Color(uiColor: preset.foreground))
                                                        .padding(6)
                                                }
                                            }
                                        Text(preset.name)
                                            .font(.caption2)
                                            .foregroundStyle(isSelected ? .primary : .secondary)
                                    }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(preset.name)
                                .accessibilityAddTraits(isSelected ? .isSelected : [])
                            }
                        }
                    }
                    Button("选择背景图片", systemImage: "photo") {
                        backgroundError = nil
                        showsBackgroundPicker = true
                    }
                    if backgroundImage != nil {
                        HStack(spacing: 0) {
                            Text("使用背景图片")
                                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                .contentShape(Rectangle())
                                .onTapGesture { useBackgroundImage.toggle() }
                                .accessibilityHidden(true)
                            Toggle("使用背景图片", isOn: $useBackgroundImage)
                                .labelsHidden()
                                .fixedSize()
                        }
                        Button("删除背景图片", systemImage: "trash", role: .destructive) {
                            ReaderBackgroundStore.remove()
                            backgroundImage = nil
                            useBackgroundImage = false
                        }
                    }
                    if let backgroundError {
                        Text(backgroundError).font(.footnote).foregroundStyle(.red)
                    }
                }

                Section("文字") {
                    valueSlider("字号", value: $fontSize, range: 5...50, format: { "\(Int($0))" })
                    valueSlider("字间距", value: $letterSpacing, range: -0.5...0.5, step: 0.01, format: { String(format: "%.2f", $0) })
                    valueSlider("行间距", value: $lineSpacing, range: 0...50, format: { "\(Int($0))" })
                    valueSlider("段距", value: $paragraphSpacing, range: 0...50, format: { String(format: "%.1f", $0) })
                    ReadingMenuPickerRow(
                        title: "字重",
                        selection: $fontWeight,
                        options: [ReadingMenuOption(0, "正常"), ReadingMenuOption(1, "粗体"), ReadingMenuOption(2, "细体")],
                        identifier: "reader.fontWeight"
                    )
                    VStack(alignment: .leading, spacing: 6) {
                        Text("段落缩进")
                        TextField("请输入缩进字符", text: $paragraphIndent)
                            .textInputAutocapitalization(.never)
                            .accessibilityLabel("段落缩进字符")
                        Text("控制每段开头的缩进，默认两个全角空格；清空后不缩进。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button(fontPath.isEmpty ? "选择字体文件" : "更换字体文件", systemImage: "textformat") {
                        showsFontImporter = true
                    }
                    if !fontPath.isEmpty {
                        HStack {
                            Text("当前字体")
                            Spacer()
                            Text(URL(fileURLWithPath: fontPath).lastPathComponent)
                                .foregroundStyle(.secondary)
                        }
                        Button("恢复默认字体", role: .destructive) { fontPath = "" }
                    }
                    if !installedFontFaces.isEmpty {
                        Menu {
                            ForEach(installedFontFaces, id: \.path) { face in
                                Button(face.displayName) { fontPath = face.path }
                            }
                        } label: {
                            Label("已安装字体（\(installedFontFaces.count)）", systemImage: "list.bullet")
                        }
                        .accessibilityIdentifier("reader.fontList")
                    } else {
                        Text("把 .ttf/.otf/.ttc 放进「文件 › 我的 iPhone › 小浣熊阅读 › fonts」，重启后回到这里选择。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let fontError {
                        Text(fontError).font(.footnote).foregroundStyle(.red)
                    }
                    ReadingMenuPickerRow(
                        title: "下划线",
                        selection: $underlineMode,
                        options: [ReadingMenuOption(0, "关闭"), ReadingMenuOption(1, "实线"), ReadingMenuOption(2, "虚线")],
                        identifier: "reader.underline"
                    )
                    ReadingMenuPickerRow(
                        title: "下划线线型",
                        selection: $underlinePattern,
                        options: [
                            ReadingMenuOption(0, "实线"),
                            ReadingMenuOption(1, "点线"),
                            ReadingMenuOption(2, "虚线"),
                            ReadingMenuOption(3, "点划线")
                        ],
                        identifier: "reader.underlinePattern"
                    )
                    Stepper("段末分隔线：\(paragraphSeparatorLines) 根", value: $paragraphSeparatorLines, in: 0...3)
                    ReadingMenuPickerRow(
                        title: "简繁转换",
                        selection: $chineseConversion,
                        options: [
                            ReadingMenuOption(0, "原文"),
                            ReadingMenuOption(1, "转简体"),
                            ReadingMenuOption(2, "转繁体")
                        ],
                        identifier: "reader.chineseConversion"
                    )
                    Toggle("智能分段", isOn: $smartParagraphs)
                    Toggle("中文标点禁则", isOn: $punctuationKinsoku)
                    Toggle("页末匀空白", isOn: $justifyLastPage)
                }

                Section("章节标题") {
                    Picker("标题模式", selection: $titleMode) {
                        Text("左对齐").tag(0)
                        Text("居中").tag(1)
                        Text("隐藏").tag(2)
                    }
                    .pickerStyle(.segmented)
                    valueSlider("标题字号增量", value: $titleSize, range: -10...30, format: { String(format: "%+.0f", $0) })
                    valueSlider("标题上间距", value: $titleTopSpacing, range: 0...100, format: { "\(Int($0))" })
                    valueSlider("标题下间距", value: $titleBottomSpacing, range: 0...100, format: { "\(Int($0))" })
                    Button("设计章节标题", systemImage: "paintbrush") {
                        showsReaderMenu = false
                        showsStyleControls = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { showsTitleDesigner = true }
                    }
                    .disabled(!ChapterTitleDesignerBundle.isAvailable)
                    if !chapterTitleHTMLTemplate.isEmpty {
                        Button("清除标题设计稿", systemImage: "trash", role: .destructive) {
                            chapterTitleHTMLTemplate = ""
                            chapterTitleProjectJSON = ""
                            chapterTitleCanvasHeight = 0
                            ReaderChapterTitleStore.shared.clear()
                            readerRenderRevision &+= 1
                        }
                    }
                    if !ChapterTitleDesignerBundle.isAvailable {
                        Text("设计器资源没有进 App 包（Resources/ChapterTitleDesigner），这一项暂时不可用。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("翻页动画") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(Self.pageAnimationChoices, id: \.0) { choice in
                                Button {
                                    pageAnimation = choice.value
                                } label: {
                                    VStack(spacing: 6) {
                                        Image(systemName: choice.icon)
                                            .font(.headline)
                                        Text(choice.title)
                                            .font(.caption2)
                                    }
                                    .foregroundStyle(pageAnimation == choice.value ? ReadingTheme.onAccent : Color.primary)
                                    .frame(width: 58, height: 54)
                                    .background(
                                        pageAnimation == choice.value ? ReadingTheme.accentFill : Color.secondary.opacity(0.1),
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    )
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .strokeBorder(pageAnimation == choice.value ? ReadingTheme.selectionBorder : .clear, lineWidth: 1)
                                    }
                                }
                                .buttonStyle(.plain)
                                .accessibilityAddTraits(pageAnimation == choice.value ? .isSelected : [])
                            }
                        }
                    }
                    Text(pageAnimation == 3
                         ? "滚动模式连续滚动；其余模式按整屏翻页。左右滑动或点击左右三分之一区域翻页，点击中间区域打开菜单。"
                         : "当前模式按整屏翻页；左右滑动或点击左右三分之一区域翻页，点击中间区域打开菜单。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("正文边距") {
                    valueSlider("左边距", value: $paddingLeft, range: 0...100, format: { "\(Int($0))" })
                    valueSlider("右边距", value: $paddingRight, range: 0...100, format: { "\(Int($0))" })
                    valueSlider("上边距", value: $paddingTop, range: 0...100, format: { "\(Int($0))" })
                    valueSlider("下边距", value: $paddingBottom, range: 0...100, format: { "\(Int($0))" })
                }

                Section("页眉页脚") {
                    ReadingMenuPickerRow(
                        title: "页眉显示",
                        selection: $headerMode,
                        options: [
                            ReadingMenuOption(0, "状态栏显示时隐藏"),
                            ReadingMenuOption(1, "显示"),
                            ReadingMenuOption(2, "隐藏")
                        ],
                        identifier: "reader.headerMode"
                    )
                    ReadingMenuPickerRow(
                        title: "页脚显示",
                        selection: $footerMode,
                        options: [ReadingMenuOption(0, "显示"), ReadingMenuOption(1, "隐藏")],
                        identifier: "reader.footerMode"
                    )
                    barContentPicker("页眉左", selection: $barHeaderLeft)
                    barContentPicker("页眉中", selection: $barHeaderMiddle)
                    barContentPicker("页眉右", selection: $barHeaderRight)
                    barContentPicker("页脚左", selection: $barFooterLeft)
                    barContentPicker("页脚中", selection: $barFooterMiddle)
                    barContentPicker("页脚右", selection: $barFooterRight)
                    Stepper("短标题字数：\(barShortTitleLength)", value: $barShortTitleLength, in: 2...20)
                    TextField("自定义日期格式（如 M月d日）", text: $barCustomDatePattern)
                    TextField("自定义栏内容", text: $barCustomText)
                    Toggle("页眉分隔线", isOn: $showHeaderLine)
                    Toggle("页脚分隔线", isOn: $showFooterLine)
                }

                Section("页眉边距") {
                    valueSlider("左边距", value: $headerPaddingLeft, range: 0...100, format: { "\(Int($0))" })
                    valueSlider("右边距", value: $headerPaddingRight, range: 0...100, format: { "\(Int($0))" })
                    valueSlider("上边距", value: $headerPaddingTop, range: 0...100, format: { "\(Int($0))" })
                    valueSlider("下边距", value: $headerPaddingBottom, range: 0...100, format: { "\(Int($0))" })
                }

                Section("页脚边距") {
                    valueSlider("左边距", value: $footerPaddingLeft, range: 0...100, format: { "\(Int($0))" })
                    valueSlider("右边距", value: $footerPaddingRight, range: 0...100, format: { "\(Int($0))" })
                    valueSlider("上边距", value: $footerPaddingTop, range: 0...100, format: { "\(Int($0))" })
                    valueSlider("下边距", value: $footerPaddingBottom, range: 0...100, format: { "\(Int($0))" })
                }
            }
            .navigationTitle("阅读样式")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showsStyleControls = false }
                }
            }
        }
        .readingPhotoPicker(isPresented: $showsBackgroundPicker) { data in
            backgroundError = nil
            do {
                backgroundImage = try ReaderBackgroundStore.save(data)
                useBackgroundImage = true
            } catch {
                backgroundError = error.localizedDescription
            }
        } onError: { error in
            backgroundError = error.localizedDescription
        }
        .fileImporter(
            isPresented: $showsFontImporter,
            allowedContentTypes: ReaderFontStore.importableContentTypes,
            allowsMultipleSelection: false
        ) { result in
            fontError = nil
            do {
                guard let source = try result.get().first else { return }
                fontPath = try ReaderFontStore.install(from: source)
            } catch {
                fontError = error.localizedDescription
            }
        }
        .readingPresentationDetents([.medium])
        .readingPresentationDragIndicator()
    }

    private static let pageAnimationChoices: [(value: Int, title: String, icon: String)] = [
        (0, "覆盖", "rectangle.on.rectangle"),
        (1, "滑动", "rectangle.portrait.and.arrow.right"),
        (2, "仿真", "book.pages"),
        (3, "滚动", "arrow.up.and.down"),
        (4, "无动画", "rectangle")
    ]

    private func readerChoiceChip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(selected ? ReadingTheme.onAccent : Color.primary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(selected ? ReadingTheme.accentFill : Color.secondary.opacity(0.1), in: Capsule())
                .overlay {
                    Capsule().strokeBorder(selected ? ReadingTheme.selectionBorder : .clear, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func valueSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double = 1,
        format: @escaping (Double) -> String
    ) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value.wrappedValue)).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
        }
    }

    /// 一栏可填多个条目：点一下加进去，再点一下拿出来。
    private func barContentPicker(_ title: String, selection: Binding<String>) -> some View {
        let selected = ReaderBarContent.decode(selection.wrappedValue)
        return Menu {
            ForEach(ReaderBarContent.allCases) { item in
                Button {
                    var items = ReaderBarContent.decode(selection.wrappedValue)
                    if let index = items.firstIndex(of: item) {
                        items.remove(at: index)
                    } else if item != .none {
                        items.append(item)
                    }
                    selection.wrappedValue = ReaderBarContent.encode(items)
                } label: {
                    Label(item.rawValue, systemImage: selected.contains(item) ? "checkmark" : "square")
                }
            }
            Divider()
            Button("清空", role: .destructive) { selection.wrappedValue = "" }
        } label: {
            HStack {
                Text(title)
                Spacer()
                Text(selected.isEmpty ? "无" : selected.map(\.rawValue).joined(separator: " + "))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }


    private var clickActions: [Int] {
        // Keep persisted action IDs stable; the removed sync action becomes a no-op.
        [clickActionTL, clickActionTC, clickActionTR, clickActionML, 0, clickActionMR, clickActionBL, clickActionBC, clickActionBR]
            .map { $0 == 12 ? -1 : $0 }
    }

    private static let tapActionChoices: [(Int, String)] = [
        (-1, "无动作"), (0, "菜单"), (1, "下一页"), (2, "上一页"),
        (3, "下一章"), (4, "上一章"), (5, "朗读上一段"), (6, "朗读下一段"),
        (7, "添加书签"), (8, "编辑正文"), (9, "替换(启用/禁用)"), (10, "目录"),
        (11, "搜索正文"), (13, "暂停/继续朗读")
    ]

    private var clickActionSettings: some View {
        ReadingNavigationStack {
            VStack(spacing: 8) {
                ForEach(0..<3, id: \.self) { row in
                    HStack(spacing: 8) {
                        ForEach(0..<3, id: \.self) { column in
                            let index = row * 3 + column
                            VStack(spacing: 8) {
                                Text(["左上", "上中", "右上", "左中", "中央", "右中", "左下", "下中", "右下"][index])
                                    .font(.caption).foregroundStyle(.secondary)
                                if index == 4 {
                                    Text("固定：菜单")
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(ReadingTheme.accent)
                                        .frame(maxWidth: .infinity, minHeight: 32)
                                } else {
                                    Picker("动作", selection: clickActionBinding(at: index)) {
                                        ForEach(Self.tapActionChoices, id: \.0) { action in
                                            Text(action.1).tag(action.0)
                                        }
                                    }
                                    .labelsHidden()
                                    .frame(maxWidth: .infinity)
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(6)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
            }
            .padding(10)
            .navigationTitle("点击区域设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showsClickActionSettings = false }
                }
            }
        }
    }

    private func clickActionBinding(at index: Int) -> Binding<Int> {
        let binding: Binding<Int> = switch index {
        case 0: $clickActionTL
        case 1: $clickActionTC
        case 2: $clickActionTR
        case 3: $clickActionML
        case 5: $clickActionMR
        case 6: $clickActionBL
        case 7: $clickActionBC
        default: $clickActionBR
        }
        return Binding(
            get: { binding.wrappedValue == 12 ? -1 : binding.wrappedValue },
            set: { binding.wrappedValue = $0 }
        )
    }

    private func handleTapAction(_ action: Int) {
        switch action {
        case 0: showsReaderMenu.toggle()
        case 3: if model.canGoNext { moveChapter(1) }
        case 4: if model.canGoPrevious { moveChapter(-1) }
        case 5: speech.previousSegment()
        case 6: speech.nextSegment()
        case 7: addBookmark()
        case 8:
            guard model.canEditContent else { return }
            showsReaderMenu = false
            editedContent = model.content
            contentEditError = nil
            showsContentEditor = true
        case 9:
            showsReaderMenu = false
            let updatedBook = model.toggleReplaceRules(position: readerPosition)
            Task {
                await library.addOrUpdate(updatedBook)
            }
        case 10:
            showsReaderMenu = false
            showsTableOfContents = true
        case 11:
            showsReaderMenu = false
            showsContentSearch = true
        case 13:
            isAutoReading = false
            configureSpeech()
            if let engine = selectedHTTPEngine {
                speech.pauseOrResumeHTTP(engine: engine, text: model.content, continuesAcrossChapters: true)
            } else {
                speech.pauseOrResume(text: model.content, continuesAcrossChapters: true)
            }
        default: break
        }
    }


    private var readerSettings: some View {
        ReadingNavigationStack {
            Form {
                Section {
                    Toggle("两端对齐", isOn: $fullJustify)
                    Button("编辑本章正文", systemImage: "square.and.pencil") {
                        editedContent = model.content
                        contentEditError = nil
                        showsReaderSettings = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { showsContentEditor = true }
                    }
                    .disabled(!model.canEditContent || model.content.isEmpty)
                    Button("重新获取本章", systemImage: "arrow.clockwise") {
                        showsReaderSettings = false
                        refreshCurrentChapter()
                    }
                    .disabled(model.isLoading || !model.canEditContent)
                } header: {
                    Text("正文")
                } footer: {
                    if !model.canEditContent {
                        Text("本地 TXT / EPUB 直接读取原文件。本章编辑与网络刷新仅对网络书籍开放。")
                    }
                }

                Section("屏幕") {
                    ReadingMenuPickerRow(
                        title: "屏幕方向",
                        selection: $screenOrientation,
                        options: [
                            ReadingMenuOption("0", "跟随系统"),
                            ReadingMenuOption("1", "竖向"),
                            ReadingMenuOption("2", "横向"),
                            ReadingMenuOption("3", "跟随传感器"),
                            ReadingMenuOption("4", "反向竖屏"),
                            ReadingMenuOption("5", "反向横屏")
                        ],
                        identifier: "reader.screenOrientation"
                    )
                    Toggle("阅读时不自动锁屏", isOn: $keepScreenOn)
                    if #available(iOS 16.0, *) {
                        Toggle("阅读时隐藏小横条", isOn: $hideHomeIndicator)
                    }
                    Toggle("隐藏状态栏", isOn: $hideStatusBar)
                    Toggle("自动夜间（22:00–07:00）", isOn: $autoNight)
                    Toggle("显示亮度调节", isOn: $showBrightness)
                    Button("跟随系统亮度", systemImage: "sun.max") {
                        followsSystemBrightness = true
                        storedReaderBrightness = 0
                        UIScreen.main.brightness = CGFloat(brightnessBeforeReading)
                        readerBrightness = brightnessBeforeReading
                    }
                }

                Section("朗读") {
                    ReadingMenuPickerRow(
                        title: "全局朗读引擎",
                        selection: $appTTSEngine,
                        options: [ReadingMenuOption("", "系统 TTS")]
                            + httpTTSEngines.map { ReadingMenuOption(String($0.id), $0.name) },
                        identifier: "reader.ttsEngine"
                    )
                    ReadingMenuPickerRow(
                        title: "本书朗读引擎",
                        selection: bookTTSEngineBinding,
                        options: [ReadingMenuOption("__global__", "跟随全局"), ReadingMenuOption("", "系统 TTS")]
                            + httpTTSEngines.map { ReadingMenuOption(String($0.id), $0.name) },
                        identifier: "reader.bookTTSEngine"
                    )
                    ReadingMenuPickerRow(
                        title: "系统声音",
                        selection: $systemTTSVoice,
                        options: [ReadingMenuOption("", "系统默认中文声音")]
                            + systemTTSVoices.map { ReadingMenuOption($0.identifier, "\($0.name)（\($0.language)）") },
                        identifier: "reader.systemVoice"
                    )
                    Toggle("跟随系统语速", isOn: $ttsFollowSystem)
                    Stepper("朗读语速：\(ttsSpeechRate)", value: $ttsSpeechRate, in: 0...45)
                        .disabled(ttsFollowSystem)
                    Toggle("按页朗读", isOn: $readAloudByPage)
                    Toggle("流式播放在线音频", isOn: $streamReadAloudAudio)
                    Toggle("朗读时保持亮屏", isOn: $readAloudWakeLock)
                    Toggle("忽略音频焦点", isOn: $ignoreAudioFocus)
                    Toggle("忽略焦点时仍在来电时暂停", isOn: $pauseReadAloudWhilePhoneCalls)
                        .disabled(!ignoreAudioFocus)
                    Toggle("媒体上一首/下一首切换章节", isOn: $mediaButtonPerNext)
                    Stepper("默认定时：\(ttsTimer) 分钟", value: $ttsTimer, in: 0...180)
                    if speechTimerRemaining > 0 {
                        Text("本次朗读还剩 \(speechTimerRemaining) 分钟")
                            .font(.footnote.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if let error = speech.errorMessage {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }

                Section("操作") {
                    Button("自动阅读设置", systemImage: "play.circle") {
                        showsReaderSettings = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { showsAutoReadControls = true }
                    }
                    Button("点击区域设置", systemImage: "square.grid.3x3") {
                        showsReaderSettings = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { showsClickActionSettings = true }
                    }
                }
            }
            .navigationTitle("阅读设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showsReaderSettings = false }
                }
            }
        }
        .readingPresentationDetents([.medium, .large])
    }


    private var contentEditor: some View {
        ReadingNavigationStack {
            VStack(spacing: 0) {
                TextEditor(text: $editedContent)
                    .font(.body.monospaced())
                    .padding(8)
                if let contentEditError {
                    Text(contentEditError)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal)
                        .padding(.bottom, 8)
                }
            }
            .navigationTitle(model.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showsContentEditor = false }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button("重置") { refreshEditorFromSource() }
                    Button("保存") { saveEditedContent() }
                        .disabled(editedContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func refreshCurrentChapter() {
        stopSpeechIfNeeded()
        Task {
            await model.load(rules: replaceRules.rules, forceRefresh: true, prefetchNextChapter: pageAnimation != 3)
            readerPosition = min(readerPosition, model.content.utf16.count)
        }
    }

    private func refreshEditorFromSource() {
        contentEditError = nil
        Task {
            await model.load(rules: replaceRules.rules, forceRefresh: true, prefetchNextChapter: pageAnimation != 3)
            editedContent = model.content
            if let error = model.diagnostics.first(where: { $0.severity == .error }) {
                contentEditError = error.message
            }
        }
    }

    private func saveEditedContent() {
        contentEditError = nil
        Task {
            do {
                try await model.saveEditedContent(editedContent)
                readerPosition = min(readerPosition, editedContent.utf16.count)
                showsContentEditor = false
            } catch {
                contentEditError = error.localizedDescription
            }
        }
    }


    private var tableOfContents: some View {
        ReadingNavigationStack {
            List {
                Section {
                    ForEach(tocChapters) { chapter in
                        if chapter.isVolume {
                            HStack(spacing: 10) {
                                Image(systemName: "books.vertical.fill")
                                Text(chapter.title).font(.headline)
                                Spacer()
                            }
                            .foregroundStyle(ReadingTheme.accent)
                            .padding(.vertical, 4)
                            .listRowBackground(ReadingTheme.accent.opacity(0.07))
                        } else {
                            let isCurrent = chapter.id == model.currentChapter?.id
                            Button {
                                guard let index = model.chapters.firstIndex(where: { $0.id == chapter.id }) else { return }
                                stopSpeechIfNeeded()
                                saveProgress(immediate: true)
                                readerJumpPosition = nil
                                model.select(index: index)
                                readerPosition = 0
                                showsTableOfContents = false
                            } label: {
                                HStack(spacing: 12) {
                                    Text(tocChapterNumber(chapter))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(isCurrent ? ReadingTheme.accent : .secondary)
                                        .frame(width: 30, alignment: .trailing)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(chapter.title)
                                            .foregroundStyle(.primary)
                                            .lineLimit(2)
                                        if isCurrent {
                                            HStack(spacing: 6) {
                                                Text("正在阅读")
                                                ProgressView(value: chapterProgress)
                                                    .tint(ReadingTheme.accent)
                                            }
                                            .font(.caption2)
                                            .foregroundStyle(ReadingTheme.accent)
                                        }
                                    }
                                    Spacer(minLength: 8)
                                    if isCurrent {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(ReadingTheme.accent)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(isCurrent ? ReadingTheme.accent.opacity(0.08) : Color.clear)
                        }
                    }
                } header: {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(book.name).font(.headline).lineLimit(1)
                            Spacer()
                            Text("\(tocReadableChapterCount) 章")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        ProgressView(value: chapterProgress)
                            .tint(ReadingTheme.accent)
                        Text("第 \(max(model.currentIndex + 1, 1)) 章 · \(Int(chapterProgress * 100))%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .textCase(nil)
                    .padding(.vertical, 4)
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("目录")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $tocSearch, prompt: "搜索章节")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { showsTableOfContents = false } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(tocDescending ? "正序" : "倒序", systemImage: "arrow.up.arrow.down") {
                        tocDescending.toggle()
                    }
                }
            }
        }
        .readingPresentationDetents([.medium, .large])
        .readingPresentationDragIndicator()
    }

    private var tocReadableChapterCount: Int {
        model.chapters.filter { !$0.isVolume }.count
    }

    private func tocChapterNumber(_ chapter: BookChapter) -> String {
        guard let index = model.chapters.firstIndex(where: { $0.id == chapter.id }) else { return "—" }
        let number = model.chapters.prefix(index + 1).filter { !$0.isVolume }.count
        return number > 0 ? "\(number)" : "—"
    }


    private var contentSearchSheet: some View {
        ReadingNavigationStack {
            Group {
                if contentSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ReadingUnavailableView("搜索正文", systemImage: "magnifyingglass", description: Text("输入本章正文关键字"))
                } else if contentSearchResults.isEmpty {
                    ReadingUnavailableView.search(text: contentSearchQuery)
                } else {
                    List(contentSearchResults) { paragraph in
                        Button {
                            readerPosition = paragraph.id
                            readerJumpPosition = nil
                            DispatchQueue.main.async { readerJumpPosition = paragraph.id }
                            showsContentSearch = false
                        } label: {
                            Text(paragraph.text)
                                .foregroundStyle(.primary)
                                .lineLimit(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .navigationTitle("正文搜索")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $contentSearchQuery, prompt: "搜索本章")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { showsContentSearch = false }
                }
            }
        }
    }

    private var contentSearchResults: [ReaderParagraph] {
        let query = contentSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return model.paragraphs.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    private var tocChapters: [BookChapter] {
        let query = tocSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let filtered = query.isEmpty ? model.chapters : model.chapters.filter {
            $0.title.localizedCaseInsensitiveContains(query)
        }
        return tocDescending ? Array(filtered.reversed()) : filtered
    }


    private var bookmarksSheet: some View {
        ReadingNavigationStack {
            Group {
                let bookmarks = activity.bookmarks(for: book)
                if bookmarks.isEmpty {
                    ReadingUnavailableView(
                        "本书还没有书签",
                        systemImage: "bookmark",
                        description: Text("阅读时点击顶部书签按钮即可记录当前位置。")
                    )
                } else {
                    List(bookmarks) { bookmark in
                        Button {
                            jump(to: bookmark)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(bookmark.chapterName).font(.headline).foregroundStyle(.primary)
                                if !bookmark.bookText.isEmpty {
                                    Text(bookmark.bookText).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
                                }
                                Text("位置 \(bookmark.chapterPosition)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .swipeActions {
                            Button("删除", role: .destructive) { Task { await activity.removeBookmark(bookmark) } }
                        }
                    }
                }
            }
            .navigationTitle("书签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { showsBookmarks = false } } }
        }
    }

    private var bookmarkSaved: Bool {
        let page = currentPage - 1
        let range = pageAnimation != 3 && readerPageRanges.indices.contains(page) ? readerPageRanges[page] : nil
        return !model.bookmarks(at: readerPosition, in: activity.bookmarks, pageRange: range).isEmpty
    }

    private func addBookmark() {
        guard !isSavingBookmark, !bookmarkSaved, let chapter = model.currentChapter else { return }
        let currentBook = book
        let position = readerPosition
        let content = model.content
        isSavingBookmark = true
        Task {
            defer { isSavingBookmark = false }
            await activity.addBookmark(
                book: currentBook,
                chapter: chapter,
                position: position,
                content: content
            )
        }
    }

    private func jump(to bookmark: Bookmark) {
        guard let index = bookmark.resolvedChapterIndex(in: model.chapters) else { return }
        stopSpeechIfNeeded()
        saveProgress(immediate: true)
        model.select(index: index, position: bookmark.chapterPosition)
        readerPosition = bookmark.chapterPosition
        readerJumpPosition = nil
        showsBookmarks = false
    }


    private func saveProgress(immediate: Bool = false) {
        guard let chapter = model.currentChapter else { return }
        let position = readerPosition
        let currentBook = book
        progressSaveGeneration &+= 1
        progressSaveTask?.cancel()
        progressSaveTask = Task { @MainActor [weak library] in
            if !immediate { try? await Task.sleep(nanoseconds: 100_000_000) }
            guard !Task.isCancelled, let library else { return }
            await library.updateProgress(for: currentBook, chapter: chapter, position: position)
        }
    }


    private func stopSpeechIfNeeded() {
        speechStartGeneration &+= 1
        if speech.isSpeaking || speech.isPaused { speech.toggle(text: "") }
    }

    private func restartSpeechAfterReaderLayoutChange() {
        readerPageRanges = []
        guard speech.isSpeaking || speech.isPaused else { return }
        speechStartGeneration &+= 1
        speech.stop()
        configureSpeech()
        startConfiguredSpeech()
    }

    private func toggleSpeech() {
        isAutoReading = false
        configureSpeech()
        if speech.isSpeaking || speech.isPaused {
            speechStartGeneration &+= 1
            speech.stop()
            speechTimerTask?.cancel()
            speechTimerRemaining = 0
            return
        }
        scheduleSpeechTimer()
        startConfiguredSpeech()
    }

    private func startConfiguredSpeech() {
        if readAloudByPage {
            guard !readerPageRanges.isEmpty else {
                guard !model.content.isEmpty else { return }
                let generation = speechStartGeneration
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    guard generation == speechStartGeneration,
                          readAloudByPage,
                          !speech.isSpeaking,
                          !speech.isPaused else { return }
                    startConfiguredSpeech()
                }
                return
            }
            let pageIndex = readerPageRanges.firstIndex { readerPosition < NSMaxRange($0) }
                ?? max(readerPageRanges.count - 1, 0)
            speechPageIndex = pageIndex
            speakPage(at: pageIndex, from: readerPosition)
            return
        }
        let start = model.paragraphs.lastIndex(where: { $0.id <= readerPosition }) ?? 0
        let text = model.paragraphs.indices.contains(start)
            ? model.paragraphs[start...].map(\.text).joined(separator: "\n")
            : model.content
        if let engine = selectedHTTPEngine {
            speech.speakHTTP(
                engine: engine,
                text: text,
                continuesAcrossChapters: true,
                segmentIndexOffset: start
            )
            prefetchNextChapterSpeech(engine: engine)
        } else {
            speech.speak(text, continuesAcrossChapters: true, segmentIndexOffset: start)
        }
    }

    private func speakPage(at index: Int, from position: Int? = nil) {
        guard readerPageRanges.indices.contains(index) else {
            continueSpeechToNextChapter()
            return
        }
        let range = readerPageRanges[index]
        let start = min(max(position ?? range.location, range.location), NSMaxRange(range))
        let pageRange = NSRange(location: start, length: max(NSMaxRange(range) - start, 0))
        guard pageRange.length > 0 else {
            continueSpeechToNextPage()
            return
        }
        let pageText = (model.content as NSString).substring(with: pageRange)
        if let engine = selectedHTTPEngine {
            speech.speakHTTP(
                engine: engine,
                text: pageText,
                continuesAcrossChapters: true,
                segmentIndexOffset: 0
            )
        } else {
            speech.speak(pageText, continuesAcrossChapters: true, segmentIndexOffset: 0)
        }
    }

    private func continueSpeechToNextPage() {
        guard readAloudByPage, readerPageRanges.indices.contains(speechPageIndex) else {
            continueSpeechToNextChapter()
            return
        }
        readerPosition = NSMaxRange(readerPageRanges[speechPageIndex])
        guard readerPageRanges.indices.contains(speechPageIndex + 1) else {
            continueSpeechToNextChapter()
            return
        }
        speechPageIndex += 1
        let nextPosition = readerPageRanges[speechPageIndex].location
        readerPosition = nextPosition
        readerJumpPosition = nextPosition
        speakPage(at: speechPageIndex)
    }

    private func prefetchNextChapterSpeech(engine: HttpTTS) {
        Task {
            guard let content = await model.nextSpeechContent(
                rules: model.usesReplaceRules ? replaceRules.rules : []
            ), selectedHTTPEngine?.id == engine.id else { return }
            speech.prefetchHTTP(engine: engine, text: content, limit: 10)
        }
    }

    private func continueSpeechToNextChapter() {
        guard model.canGoNext else {
            speechTimerTask?.cancel()
            speechTimerRemaining = 0
            return
        }
        saveProgress(immediate: true)
        resumesSpeechAfterChapterLoad = true
        readerJumpPosition = nil
        model.goNext()
        readerPosition = model.requestedPosition
    }

    private func moveSpeechToChapter(direction: Int) {
        let canMove = direction < 0 ? model.canGoPrevious : model.canGoNext
        guard canMove else { return }
        speech.stop()
        saveProgress(immediate: true)
        resumesSpeechAfterChapterLoad = true
        readerJumpPosition = nil
        if direction < 0 { model.goPrevious() } else { model.goNext() }
        readerPosition = model.requestedPosition
    }

    private func scheduleSpeechTimer() {
        speechTimerTask?.cancel()
        speechTimerRemaining = ttsTimer
        guard speechTimerRemaining > 0 else { return }
        speechTimerTask = Task { @MainActor in
            do {
                while speechTimerRemaining > 0 {
                    try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                    if !speech.isSpeaking && !speech.isPaused && !resumesSpeechAfterChapterLoad {
                        speechTimerRemaining = 0
                        break
                    }
                    if !speech.isPaused { speechTimerRemaining -= 1 }
                    if speechTimerRemaining == 0 {
                        speech.stop()
                        resumesSpeechAfterChapterLoad = false
                    }
                }
            } catch { }
        }
    }

    private func configureSpeech() {
        speech.configure(
            followsSystemRate: ttsFollowSystem,
            speechRate: ttsSpeechRate,
            readByPage: readAloudByPage,
            streamsHTTPAudio: streamReadAloudAudio,
            voiceIdentifier: systemTTSVoice,
            ignoresAudioFocus: ignoreAudioFocus,
            pausesForPhoneCalls: pauseReadAloudWhilePhoneCalls,
            mediaButtonPerNext: mediaButtonPerNext,
            bookName: model.book.name,
            chapterTitle: model.title,
            author: model.book.author
        )
    }

    private static func globalPageAnimation() -> Int {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "pageAnim") == nil,
           let legacy = defaults.object(forKey: "readerPageAnimation") as? NSNumber {
            defaults.set(legacy.intValue, forKey: "pageAnim")
        }
        return defaults.integer(forKey: "pageAnim")
    }

    private var selectedHTTPEngine: HttpTTS? {
        let value = model.book.readConfig?.ttsEngine ?? appTTSEngine
        guard let id = Int64(value) else { return nil }
        return httpTTSEngines.first { $0.id == id }
    }

    private var systemTTSVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("zh") }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private var bookTTSEngineBinding: Binding<String> {
        Binding(
            get: { model.book.readConfig?.ttsEngine ?? "__global__" },
            set: { value in
                let updated = model.setTTSEngine(value == "__global__" ? nil : value)
                Task { await library.addOrUpdate(updated) }
            }
        )
    }

    private func loadHTTPEngines() async {
        guard let database = try? LegadoDatabase(url: LegadoDatabase.defaultURL()) else { return }
        let repository = SQLiteConfigurationRepository(database: database)
        var values = (try? await repository.loadHttpTTS()) ?? []
        if values.isEmpty,
           let url = Bundle.main.url(forResource: "httpTTS", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let defaults = try? JSONDecoder().decode([HttpTTS].self, from: data) {
            values = defaults
            try? await repository.saveHttpTTS(values)
        }
        httpTTSEngines = values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if !appTTSEngine.isEmpty, selectedHTTPEngine == nil { appTTSEngine = "" }
    }
}

#if DEBUG
private struct ReaderFailureTestLoader: ChapterContentLoading {
    func loadContent(book: Book, chapter: BookChapter, source: BookSource, nextChapterURL: String?, maxPages: Int) async -> ChapterContentReport {
        .init(content: ProcessInfo.processInfo.arguments.contains("-uiReaderPartialFailure") ? "本章只加载了第一页正文。" : "",
              diagnostics: [.init(severity: .error, code: "content.request", message: "测试书源正文请求失败", rule: chapter.url)])
    }
}
#endif
