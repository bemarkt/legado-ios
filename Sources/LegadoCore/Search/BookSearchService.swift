import Foundation

public struct SourceSearchOutcome: Sendable {
    public var sourceID: String
    public var books: [SearchBook]
    public var diagnostics: [RuleDiagnostic]

    public init(sourceID: String, books: [SearchBook], diagnostics: [RuleDiagnostic]) {
        self.sourceID = sourceID
        self.books = books
        self.diagnostics = diagnostics
    }
}

public struct BookSearchReport: Sendable {
    public var books: [SearchBook]
    public var outcomes: [SourceSearchOutcome]

    public init(books: [SearchBook], outcomes: [SourceSearchOutcome]) {
        self.books = books
        self.outcomes = outcomes
    }
}

public actor BookSearchHistory {
    public static let shared = BookSearchHistory(defaults: .standard)
    private struct Entry: Codable, Sendable {
        var success: Date?
        var failure: Date?
        var failures = 0
    }
    private var entries: [String: Entry]
    private let defaults: UserDefaults?
    private static let key = "legado.searchSourceHistory.v1"
    private var saveTask: Task<Void, Never>?

    public init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
        entries = defaults?.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
    }

    public func ordered(_ sources: [BookSource], preferred: Set<String>, now: Date = Date()) -> [BookSource] {
        func rank(_ source: BookSource) -> Int {
            if preferred.contains(source.id) { return 0 }
            guard let entry = entries[source.id] else { return 2 }
            if let failure = entry.failure, now.timeIntervalSince(failure) < 300, entry.failures > 0 { return 3 }
            if let success = entry.success, now.timeIntervalSince(success) < 7 * 86_400 { return 1 }
            return 2
        }
        return sources.enumerated().sorted {
            let lhs = rank($0.element), rhs = rank($1.element)
            if lhs != rhs { return lhs < rhs }
            return $0.offset < $1.offset
        }.map(\.element)
    }

    public func record(_ outcome: SourceSearchOutcome, now: Date = Date()) {
        guard !outcome.diagnostics.contains(where: { $0.code == "search.cancelled" }) else { return }
        var entry = entries[outcome.sourceID] ?? Entry()
        if !outcome.books.isEmpty {
            entry.success = now
            entry.failures = 0
        } else if outcome.diagnostics.contains(where: { $0.severity == .error }) {
            entry.failure = now
            entry.failures += 1
        } else { return }
        entries[outcome.sourceID] = entry
        guard defaults != nil, saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    public func flush() {
        saveTask?.cancel()
        saveTask = nil
        guard let defaults else { return }
        let retained = entries.sorted {
            if ($0.value.success != nil) != ($1.value.success != nil) { return $0.value.success != nil }
            return ($0.value.success ?? $0.value.failure ?? .distantPast) > ($1.value.success ?? $1.value.failure ?? .distantPast)
        }.prefix(512)
        entries = Dictionary(uniqueKeysWithValues: retained.map { ($0.key, $0.value) })
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: Self.key) }
    }
}

public struct BookSearchAccumulator: Sendable {
    private var books: [SearchBook] = []
    private var indices: [String: Int] = [:]
    public init() {}

    public mutating func add(_ incoming: [SearchBook], replacingExisting: Bool = false) {
        for book in incoming {
            let identity = BookSearchService.mergeIdentity(for: book)
            if let index = indices[identity] {
                let origins = books[index].origins.union(book.origins)
                if replacingExisting { books[index] = book }
                books[index].origins = origins
            } else {
                indices[identity] = books.count
                books.append(book)
            }
        }
    }

    public func results(keyword: String) -> [SearchBook] {
        var buckets = Array(repeating: [SearchBook](), count: 4)
        for book in books {
            let rank: Int
            if book.name == keyword || book.author == keyword { rank = 0 }
            else if book.kind?.contains(keyword) == true { rank = 1 }
            else if book.name.contains(keyword) || book.author.contains(keyword) { rank = 2 }
            else { rank = 3 }
            buckets[rank].append(book)
        }
        return buckets.flatMap { $0 }
    }
}

public struct BookSearchService: Sendable {
    private let transport: any HTTPTransport
    private let urlBuilder: LegadoURLBuilder
    private let engine: RuleEngine
    private let networkPolicy: SourceNetworkPolicy
    private let webViewExecutor: (any SourceWebViewRequestExecuting)?
    private let snapshotRecorder: (any DifferentialSnapshotRecording)?
    private let history: BookSearchHistory

    public init(
        transport: any HTTPTransport = URLSessionHTTPTransport(),
        urlBuilder: LegadoURLBuilder = .init(),
        engine: RuleEngine = .init(),
        networkPolicy: SourceNetworkPolicy = .shared,
        webViewExecutor: (any SourceWebViewRequestExecuting)? = nil,
        snapshotRecorder: (any DifferentialSnapshotRecording)? = nil,
        history: BookSearchHistory = .shared
    ) {
        self.transport = transport
        self.urlBuilder = urlBuilder
        self.engine = engine
        self.networkPolicy = networkPolicy
        self.webViewExecutor = webViewExecutor
        self.snapshotRecorder = snapshotRecorder
        self.history = history
    }

    public func search(
        keyword: String,
        page: Int = 1,
        sources: [BookSource]
    ) async -> BookSearchReport {
        let enabled = sources.filter { $0.enabled && $0.searchUrl?.isEmpty == false }
        let sourceOrder = Dictionary(enabled.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        var outcomes: [SourceSearchOutcome] = []
        for await outcome in searchOutcomes(keyword: keyword, page: page, sources: enabled) {
            outcomes.append(outcome)
        }
        outcomes.sort { (sourceOrder[$0.sourceID] ?? .max) < (sourceOrder[$1.sourceID] ?? .max) }
        return .init(books: merge(outcomes: outcomes, keyword: keyword), outcomes: outcomes)
    }

    public func searchOutcomes(
        keyword: String,
        page: Int = 1,
        sources: [BookSource],
        maximumConcurrentSources: Int = ApplicationSettingsStore.shared.settings.concurrentSources,
        includeDisabled: Bool = false,
        preferredSourceIDs: Set<String> = []
    ) -> AsyncStream<SourceSearchOutcome> {
        var seen = Set<String>()
        let enabled = sources.filter { (includeDisabled || $0.enabled) && $0.searchUrl?.isEmpty == false && seen.insert($0.id).inserted }
        let concurrency = min(max(maximumConcurrentSources, 1), enabled.count)
        guard concurrency > 0 else {
            return AsyncStream { $0.finish() }
        }

        return AsyncStream { continuation in
            let task = Task {
                let ordered = await history.ordered(enabled, preferred: preferredSourceIDs)
                await withTaskGroup(of: SourceSearchOutcome.self) { group in
                    var complexRunning = 0
                    let complexLimit = min(concurrency, 4)
                    func isComplex(_ source: BookSource) -> Bool {
                        let template = (source.searchUrl ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                        return template.hasPrefix("@js:") || template.hasPrefix("<js>") || template.contains("webview") || template.contains("webjs")
                    }
                    let complexIDs = Set(ordered.filter(isComplex).map(\.id))
                    let normal = ordered.enumerated().filter { !complexIDs.contains($0.element.id) }.map(\.offset)
                    let complex = ordered.enumerated().filter { complexIDs.contains($0.element.id) }.map(\.offset)
                    var normalIndex = 0
                    var complexIndex = 0
                    func enqueue() -> Bool {
                        guard !Task.isCancelled else { return false }
                        let nextNormal = normalIndex < normal.count ? normal[normalIndex] : Int.max
                        let nextComplex = complexIndex < complex.count && complexRunning < complexLimit ? complex[complexIndex] : Int.max
                        guard min(nextNormal, nextComplex) != Int.max else { return false }
                        let source: BookSource
                        if nextComplex < nextNormal {
                            source = ordered[nextComplex]
                            complexIndex += 1
                            complexRunning += 1
                        } else {
                            source = ordered[nextNormal]
                            normalIndex += 1
                        }
                        group.addTask {
                            await search(keyword: keyword, page: page, source: source,
                                         timeoutLimit: enabled.count > 1 ? 8 : 30)
                        }
                        return true
                    }
                    for _ in 0..<concurrency { if !enqueue() { break } }
                    while let outcome = await group.next() {
                        if complexIDs.contains(outcome.sourceID) { complexRunning -= 1 }
                        guard !Task.isCancelled else {
                            group.cancelAll()
                            break
                        }
                        await history.record(outcome)
                        continuation.yield(outcome)
                        _ = enqueue()
                    }
                }
                await history.flush()
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
                Task { await history.flush() }
            }
        }
    }

    public func search(keyword: String, page: Int, source: BookSource) async -> SourceSearchOutcome {
        await search(keyword: keyword, page: page, source: source, timeoutLimit: 30)
    }

    private func search(keyword: String, page: Int, source: BookSource, timeoutLimit: TimeInterval) async -> SourceSearchOutcome {
        guard let template = source.searchUrl, let rules = source.ruleSearch else {
            return failure(source, code: "search.configuration", message: "书源缺少搜索地址或规则")
        }
        do {
            var prepared = try await RuleExecutionWorker.run {
                let headers = try BookSourceHeaderResolver().resolve(source)
                return try urlBuilder.prepare(template, context: .init(key: keyword, page: page, source: source),
                                              baseURL: URL(string: source.bookSourceUrl), defaultHeaders: headers)
            }
            if timeoutLimit < 30 { prepared.retry = min(prepared.retry, 1) }
            let timeout = min(max(Double(source.respondTime) / 1_000, 5), timeoutLimit)
            let response = try await networkPolicy.execute(
                prepared,
                source: source,
                transport: transport,
                timeout: timeout,
                webViewExecutor: webViewExecutor,
                snapshotRecorder: snapshotRecorder,
                snapshotStage: .search
            )
            guard let listRule = rules.bookList, !listRule.isEmpty else {
                return failure(source, code: "search.book_list_rule", message: "搜索列表规则为空")
            }
            let root = response.decodedJSON
            let body = response.decodedText
            // webView / webJs 只作为「解析为空」时的上下文，不单独产生诊断。
            //
            // 搜索成功时书源调试必须保持零诊断（BookSearchServiceTests 对此有断言）：
            // 无条件挂 warning 会把 306 条正常用例里的一条打成回归。而这条信息只在
            // 失败时才有诊断价值——「返回 200 但解析为空」十次有八次就是这里被
            // webView 选项换掉了执行路径，所以拼进 search.empty_list 的 message。
            //
            // 执行器是否真的可用必须单独判一次：SourceNetworkPolicy 在缺执行器时
            // 已降级为普通 HTTP，此时 prepared.useWebView 仍为 true，直接写
            // 「经 WKWebView 渲染后解析」就是一条假日志——用户会据此去查渲染问题，
            // 而真正的原因是「本端没有执行器，拿的是原始 HTML」。
            let webViewAvailable = webViewExecutor != nil
                || SourceWebViewExecutorRegistry.shared.executor() != nil
            var executionNotes: [String] = []
            if prepared.useWebView {
                executionNotes.append(webViewAvailable
                    ? "请求经 WKWebView 渲染后解析"
                    : "书源声明 webView，但本端未注册执行器，已降级为普通 HTTP（拿到的是原始 HTML）")
            }
            if let webJs = prepared.webJavaScript, !webJs.isEmpty {
                executionNotes.append("webJs 注入 \(webJs.count) 字符"
                    + (webViewAvailable ? "" : "，未执行"))
            }
            var diagnostics: [RuleDiagnostic] = []
            let listEvaluation = if let root {
                await engine.evaluate(
                    listRule.trimmingListPrefix,
                    in: root,
                    listMode: true,
                    context: .init(variables: response.requestVariables, baseURL: response.finalURL.absoluteString, key: keyword, page: page, source: source)
                )
            } else {
                await engine.evaluate(
                    listRule.trimmingListPrefix,
                    inText: body,
                    baseURL: response.finalURL.absoluteString,
                    listMode: true,
                    context: .init(variables: response.requestVariables, key: keyword, page: page, source: source)
                )
            }
            diagnostics += listEvaluation.diagnostics
            let listItems = listEvaluation.listItems(rule: listRule.trimmingListPrefix)
            if listItems.isEmpty, !diagnostics.contains(where: { $0.severity == .error }) {
                diagnostics.append(.init(
                    severity: .error,
                    code: "search.empty_list",
                    message: "列表规则未命中任何节点：\(prepared.method.rawValue) \(response.finalURL.absoluteString) → HTTP \(response.statusCode)，正文 \(body.count) 字符，开头：\(String(body.prefix(120)).replacingOccurrences(of: "\n", with: " "))…，列表规则 \(listRule)\(executionNotes.isEmpty ? "" : "；执行路径：" + executionNotes.joined(separator: "，"))",
                    rule: listRule
                ))
                // 空列表最常见的原因是选择器写错：少个前导点、少一个下划线、
                // class 名被前端改名。只报「没命中」，用户无法区分「页面结构变了」
                // 和「自己少打一个字符」。这里把页面里真实存在的 class 列出来，
                // 把「猜选择器」变成「对照选择器」。
                if let hints = Self.cssClassHints(in: body) {
                    diagnostics.append(.init(
                        severity: .warning,
                        code: "search.empty_list_hint",
                        message: "页面里真实存在的 class（前 24 个）：\(hints)",
                        rule: listRule
                    ))
                }
            }
            var books: [SearchBook] = []
            for item in listItems {
                try Task.checkCancellation()
                let fields = await evaluateFields(
                    rules,
                    item: item,
                    isHTML: root == nil,
                    baseURL: response.finalURL.absoluteString,
                    source: source,
                    variables: listEvaluation.variables,
                    keyword: keyword,
                    page: page
                )
                diagnostics += fields.diagnostics
                guard let name = fields.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { continue }
                let bookURLValue = fields.bookURL?.nilIfEmpty ?? response.finalURL.absoluteString
                let bookURL = resolve(bookURLValue, against: response.finalURL)
                var book = SearchBook(
                    bookURL: bookURL,
                    origin: source.bookSourceUrl,
                    originName: source.bookSourceName,
                    type: source.bookSourceType,
                    name: name,
                    author: fields.author ?? ""
                )
                book.kind = fields.kind
                book.coverURL = fields.coverURL.map { resolve($0, against: response.finalURL) }
                book.intro = MetadataTextSanitizer().clean(fields.intro)
                book.wordCount = fields.wordCount
                book.latestChapterTitle = fields.lastChapter
                book.originOrder = source.customOrder
                book.variables = fields.variables
                books.append(book)
            }
            if books.isEmpty, !listItems.isEmpty, !diagnostics.contains(where: { $0.severity == .error }) {
                diagnostics.append(.init(
                    severity: .error,
                    code: "search.empty_name",
                    message: "列表命中 \(listItems.count) 个节点，但书名规则没有取到值：\(rules.name ?? "未配置")",
                    rule: rules.name ?? listRule
                ))
            }
            if listRule.hasPrefix("-") { books.reverse() }
            var seenURLs = Set<String>()
            let unique = books.filter { seenURLs.insert($0.bookURL).inserted }
            return .init(sourceID: source.id, books: unique, diagnostics: diagnostics)
        } catch is CancellationError {
            return failure(source, code: "search.cancelled", message: "搜索已取消")
        } catch let error as RuleEngineError {
            return .init(sourceID: source.id, books: [], diagnostics: [error.diagnostic])
        } catch {
            return failure(source, code: "search.request", message: error.localizedDescription)
        }
    }

    private func evaluateFields(
        _ rules: SearchRule,
        item: JSONValue,
        isHTML: Bool,
        baseURL: String,
        source: BookSource,
        variables: [String: String],
        keyword: String,
        page: Int
    ) async -> FieldEvaluation {
        var result = FieldEvaluation()
        let currentBook = Book(bookUrl: baseURL, name: "", origin: source.bookSourceUrl)
        var context = RuleExecutionContext(variables: variables, baseURL: baseURL, key: keyword, page: page, source: source, book: currentBook, isHTMLFragment: true)
        let name = await evaluate(rules.name, item: item, isHTML: isHTML, baseURL: baseURL, context: context)
        context.variables = name.variables
        context.book?.name = name.joinedString ?? ""
        let author = await evaluate(rules.author, item: item, isHTML: isHTML, baseURL: baseURL, context: context)
        context.variables = author.variables
        context.book?.author = author.joinedString ?? ""
        let kind = await evaluate(rules.kind, item: item, isHTML: isHTML, baseURL: baseURL, context: context)
        context.variables = kind.variables
        let bookURL = await evaluate(rules.bookUrl, item: item, isHTML: isHTML, baseURL: baseURL, context: context)
        context.variables = bookURL.variables
        context.book?.bookUrl = bookURL.leadingString ?? baseURL
        let coverURL = await evaluate(rules.coverUrl, item: item, isHTML: isHTML, baseURL: baseURL, context: context)
        context.variables = coverURL.variables
        let intro = await evaluate(rules.intro, item: item, isHTML: isHTML, baseURL: baseURL, context: context)
        context.variables = intro.variables
        let wordCount = await evaluate(rules.wordCount, item: item, isHTML: isHTML, baseURL: baseURL, context: context)
        context.variables = wordCount.variables
        let lastChapter = await evaluate(rules.lastChapter, item: item, isHTML: isHTML, baseURL: baseURL, context: context)
        context.variables = lastChapter.variables
        let values = (name, author, kind, bookURL, coverURL, intro, wordCount, lastChapter)
        result.name = values.0.joinedString
        result.author = values.1.joinedString
        result.kind = values.2.strings.filter { !$0.isEmpty }.joined(separator: ",").nilIfEmpty
        result.bookURL = isHTML ? values.3.leadingString : values.3.joinedString
        result.coverURL = values.4.joinedString
        result.intro = MetadataTextSanitizer().clean(values.5.joinedString)
        result.wordCount = values.6.joinedString
        result.lastChapter = values.7.joinedString
        result.diagnostics = [values.0, values.1, values.2, values.3, values.4, values.5, values.6, values.7]
            .flatMap(\.diagnostics)
        result.variables = context.variables
        return result
    }

    private func evaluate(
        _ rule: String?,
        item: JSONValue,
        isHTML: Bool,
        baseURL: String,
        context: RuleExecutionContext = .init()
    ) async -> RuleEvaluation {
        guard let rule, !rule.isEmpty else { return .init(variables: context.variables) }
        if case .string(let text) = item {
            return await engine.evaluate(rule, inText: text, baseURL: baseURL, context: context)
        }
        return await engine.evaluate(rule, in: item, context: context)
    }

    private func resolve(_ value: String, against baseURL: URL) -> String {
        LegadoURLBuilder.resolve(value, against: baseURL)
    }

    /// 从响应正文里抽取真实存在的 class 名，用于对照列表规则。
    ///
    /// CSS 选择器没命中时，引擎侧只能知道「0 节点」；但用户真正需要的是
    /// 「页面里到底有什么」。把 class 值原样列出来（含 CSS Modules 的 hash 名），
    /// 一眼就能看出是拼错还是站点改版。
    static func cssClassHints(in html: String, limit: Int = 24) -> String? {
        guard let expression = try? NSRegularExpression(pattern: #"class\s*=\s*"([^"]{1,400})""#) else {
            return nil
        }
        let matches = expression.matches(in: html, range: NSRange(html.startIndex..., in: html))
        var seen = Set<String>()
        var names: [String] = []
        for match in matches {
            guard let range = Range(match.range(at: 1), in: html) else { continue }
            for token in html[range].split(whereSeparator: { $0.isWhitespace }) {
                let name = String(token)
                guard !name.isEmpty, name.count <= 60, seen.insert(name).inserted else { continue }
                names.append(name)
                if names.count >= limit { return names.joined(separator: " ") }
            }
        }
        return names.isEmpty ? nil : names.joined(separator: " ")
    }

    private func failure(_ source: BookSource, code: String, message: String) -> SourceSearchOutcome {
        .init(
            sourceID: source.id,
            books: [],
            diagnostics: [.init(severity: .error, code: code, message: message, rule: source.searchUrl ?? "")]
        )
    }

    public func merge(outcomes: [SourceSearchOutcome], keyword: String) -> [SearchBook] {
        merge(outcomes.flatMap(\.books), keyword: keyword)
    }

    private func merge(_ books: [SearchBook], keyword: String) -> [SearchBook] {
        var accumulator = BookSearchAccumulator()
        accumulator.add(books)
        return accumulator.results(keyword: keyword)
    }

    public static func mergeIdentity(for book: SearchBook) -> String {
        "\(normalizedIdentityText(book.name))\u{0}\(normalizedAuthor(book.author))"
    }

    private static func normalizedIdentityText(_ value: String) -> String {
        String(value.unicodeScalars.filter {
            !CharacterSet.whitespacesAndNewlines.contains($0)
                && !CharacterSet.punctuationCharacters.contains($0)
                && !CharacterSet.symbols.contains($0)
        }).lowercased()
    }

    private static func normalizedAuthor(_ value: String) -> String {
        var value = normalizedIdentityText(value)
        for prefix in ["作者", "author", "著者"] where value.hasPrefix(prefix) {
            value.removeFirst(prefix.count)
        }
        for suffix in ["著", "撰"] where value.hasSuffix(suffix) {
            value.removeLast(suffix.count)
        }
        return value
    }

    private struct FieldEvaluation {
        var name: String?
        var author: String?
        var kind: String?
        var bookURL: String?
        var coverURL: String?
        var intro: String?
        var wordCount: String?
        var lastChapter: String?
        var diagnostics: [RuleDiagnostic] = []
        var variables: [String: String] = [:]
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
