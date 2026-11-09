import Foundation

/// Legacy rules end at this boundary. The reader receives only the native SourceWire contract.
/// The host creates a fresh environment for each operation, pinned to this descriptor's scope.
public struct LegadoSourceProvider: SourceProvider {
    public typealias EnvironmentFactory = @Sendable (JavaScriptExecutionControl) async throws -> JavaScriptHostEnvironment
    public let descriptor: SourceProviderDescriptor
    private let source: BookSource
    private let environment: EnvironmentFactory
    public init(source: BookSource, descriptor: SourceProviderDescriptor, environment: @escaping EnvironmentFactory) throws {
        guard source.bookSourceType == 0, let url = URL(string: source.bookSourceUrl),
              ["https", "http"].contains(url.scheme ?? ""), url.host != nil else {
            throw RuleEngineError.unsupportedRule(rule: source.bookSourceUrl, feature: "Only HTTP text-book sources are supported")
        }
        self.source = source; self.descriptor = descriptor; self.environment = environment
    }

    public func search(_ input: SourceWire.SearchInput) async throws -> SourceWire.SearchPage {
        try await run { operation in var operation = operation; return try await operation.search(input) }
    }
    public func book(_ input: SourceWire.BookInput) async throws -> SourceWire.BookDetails {
        try await run { operation in var operation = operation; return try await operation.book(input) }
    }
    public func chapters(_ input: SourceWire.ChaptersInput) async throws -> SourceWire.ChapterPage {
        try await run { operation in var operation = operation; return try await operation.chapters(input) }
    }
    public func content(_ input: SourceWire.ContentInput) async throws -> SourceWire.ChapterContent {
        try await run { operation in var operation = operation; return try await operation.content(input) }
    }

    private func run<Value: Sendable>(_ body: @Sendable (Operation) async throws -> Value) async throws -> Value {
        let control = JavaScriptExecutionControl(gate: descriptor.commitGate)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation(); try control.check()
            defer { control.cancel() }
            let host = try await environment(control)
            guard host.control === control else { throw SourceDomainError(.invalidInput, "Host returned another operation control") }
            try control.check()
            let result = try await body(Operation(source: source, descriptor: descriptor, host: host))
            try Task.checkCancellation(); try control.check()
            return result
        } onCancel: { control.cancel() }
    }

    /// Only rule-local variables are retained. source/login/Cookie host state is never copied here.
    private struct Reference: Codable, Sendable {
        var scope: SourceScope
        var kind: String
        var request: String
        var bookRequest: String
        var toc: String?
        var title: String
        var author: String?
        var variables: [String: String]
        var index: Int?
        var nextChapter: String?
        var id: String { "legado." + kind + "." + SourceCoding.digest(Data((bookRequest + "\n" + request).utf8)) }
        func wire() throws -> SourceWire.SourceRef {
            .init(id: id, url: Operation.address(request), state: try Operation.json(self))
        }
        func legacyBook(source: BookSource) -> Book {
            var book = Book(bookUrl: bookRequest, name: kind == "book" ? title : "", author: author ?? "", origin: source.id)
            book.tocUrl = toc ?? bookRequest
            book.variable = String(data: (try? SourceCoding.encode(variables)) ?? Data(), encoding: .utf8)
            return book
        }
    }
    private struct Cursor: Codable, Sendable {
        let identity: SourceExecutionIdentity
        let binding: String
        var page: Int = 1
        var pending: [String] = []
        var visited: [String] = []
        var variables: [String: String] = [:]
        var offset: Int = 0
        var volume: SourceWire.Volume?
    }
    private struct Document: Sendable {
        var value: JSONValue
        var base: String
        var fragment = false
    }
    private struct Operation: Sendable {
        let source: BookSource
        let descriptor: SourceProviderDescriptor
        let host: JavaScriptHostEnvironment
        let engine = RuleEngine()
        let javascript = JavaScriptRuleEvaluator()
        var context: RuleExecutionContext
        init(source: BookSource, descriptor: SourceProviderDescriptor, host: JavaScriptHostEnvironment) {
            self.source = source; self.descriptor = descriptor; self.host = host
            context = .init(baseURL: source.bookSourceUrl, source: source, environment: host)
        }
        static func json<Value: Encodable>(_ value: Value) throws -> SourceJSON {
            let json = try SourceCoding.decode(SourceJSON.self, from: SourceCoding.encode(value))
            _ = try json.validatedData()
            return json
        }
        static func address(_ request: String) -> String {
            guard let range = request.range(of: #",\s*(?=\{)"#, options: .regularExpression) else { return request }
            return String(request[..<range.lowerBound])
        }
        func reference(_ wire: SourceWire.SourceRef, kind: String) throws -> Reference {
            guard let state = wire.state else { throw SourceDomainError(.invalidInput, "Missing compatibility reference context") }
            let ref = try SourceCoding.decode(Reference.self, from: state.validatedData())
            guard ref.scope == descriptor.identity.scope, ref.kind == kind, ref.id == wire.id,
                  wire.url == Self.address(ref.request) else { throw SourceDomainError(.stale, "Reference belongs to another source/account or was changed") }
            return ref
        }
        func cursor(_ value: SourceJSON?, binding: String) throws -> Cursor {
            guard let value, value != .null else { return Cursor(identity: descriptor.identity, binding: binding) }
            let cursor = try SourceCoding.decode(Cursor.self, from: value.validatedData())
            guard cursor.identity == descriptor.identity, cursor.binding == binding else { throw SourceDomainError(.stale, "Cursor belongs to another operation snapshot") }
            guard (1...100).contains(cursor.page), cursor.pending.count <= 100, cursor.visited.count <= 100,
                  (0...100_000).contains(cursor.offset) else { throw SourceDomainError(.resourceLimit, "Pagination limit exceeded") }
            return cursor
        }
        func resolve(_ value: String, base: String) throws -> String {
            guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let baseURL = URL(string: base) else {
                throw SourceDomainError(.invalidData, "Rule produced an empty request URL")
            }
            let result = LegadoURLBuilder.resolve(value, against: baseURL)
            guard result.utf8.count <= 8192, let url = URL(string: Self.address(result)),
                  ["https", "http"].contains(url.scheme ?? ""), url.host != nil, url.user == nil, url.password == nil else {
                throw SourceDomainError(.invalidData, "Rule produced an invalid HTTP URL")
            }
            return result
        }
        mutating func fetch(_ request: String) async throws -> Document {
            try host.control.check()
            let response = try await javascript.request(request, context: context)
            context.variables.merge(response.requestVariables) { _, value in value }
            context.baseURL = response.finalURL.absoluteString
            return Document(value: response.decodedJSON ?? .string(response.decodedText), base: context.baseURL)
        }
        mutating func evaluate(_ rule: String?, _ document: Document, mode: RuleEvaluationMode = .string) async throws -> RuleEvaluation {
            try Task.checkCancellation(); try host.control.check()
            guard let rule, !rule.isEmpty else { return .init(variables: context.variables) }
            context.baseURL = document.base; context.content = document.value; context.isHTMLFragment = document.fragment
            let result: RuleEvaluation
            if case .string(let text) = document.value {
                result = await engine.evaluate(rule, inText: text, baseURL: document.base, mode: mode, context: context)
            } else { result = await engine.evaluate(rule, in: document.value, mode: mode, context: context) }
            try Task.checkCancellation(); try host.control.check()
            if let diagnostic = result.diagnostics.first(where: { $0.severity == .error }) {
                if diagnostic.code == "rule.unsupported" { throw RuleEngineError.unsupportedRule(rule: rule, feature: diagnostic.message) }
                throw RuleEngineError.malformedRule(rule: rule, detail: diagnostic.message)
            }
            context.variables = result.variables
            return result
        }
        mutating func string(_ rule: String?, _ document: Document) async throws -> String? {
            try await evaluate(rule, document).joinedString?.trimmingCharacters(in: .whitespacesAndNewlines).nonempty
        }
        mutating func list(_ rule: String, _ document: Document) async throws -> [JSONValue] {
            let result = try await evaluate(rule, document, mode: .elements)
            let values = result.listItems(rule: rule)
            guard values.count <= 5000 else { throw SourceDomainError(.resourceLimit, "Rule list exceeds page limit") }
            return values
        }
        mutating func links(_ rule: String?, _ document: Document) async throws -> [String] {
            let values = try await evaluate(rule, document, mode: .stringList).strings.filter { !$0.isEmpty }
            guard values.count <= 100 else { throw SourceDomainError(.resourceLimit, "Too many pagination links") }
            return try values.map { try resolve($0, base: document.base) }
        }
        func reject(_ values: [(String, String?)]) throws {
            if let unsupported = values.first(where: { $0.1?.isEmpty == false }) {
                throw RuleEngineError.unsupportedRule(rule: unsupported.1!, feature: unsupported.0)
            }
        }
        mutating func search(_ input: SourceWire.SearchInput) async throws -> SourceWire.SearchPage {
            guard descriptor.supportsSearch, let template = source.searchUrl?.nonempty, let rules = source.ruleSearch,
                  let listRule = rules.bookList?.nonempty, !input.query.isEmpty, input.query.utf8.count <= 4096 else {
                throw SourceDomainError(.invalidInput, "Search needs a query and configured search rules")
            }
            var cursor = try cursor(input.cursor, binding: "search:" + input.query)
            context.key = input.query; context.page = cursor.page; context.variables = cursor.variables
            let document = try await fetch(template)
            let values = try await list(listRule, document)
            let sharedVariables = context.variables
            var items: [SourceWire.BookSummary] = []
            for value in values {
                context.variables = sharedVariables
                let fragment = Document(value: value, base: document.base, fragment: true)
                guard let title = try await string(rules.name, fragment), let link = try await string(rules.bookUrl, fragment) else {
                    throw SourceDomainError(.invalidData, "Search item lacks title or book URL")
                }
                let author = try await string(rules.author, fragment)
                let cover = try await string(rules.coverUrl, fragment)
                let request = try resolve(link, base: document.base)
                let ref = Reference(scope: descriptor.identity.scope, kind: "book", request: request, bookRequest: request,
                                    title: title, author: author, variables: context.variables)
                items.append(.init(ref: try ref.wire(), title: title, author: author,
                                   cover: try cover.map { .init(url: try resolve($0, base: document.base)) }))
            }
            cursor.page += 1; cursor.variables = sharedVariables
            return .init(items: items, nextCursor: items.isEmpty ? .null : try Self.json(cursor))
        }
        mutating func book(_ input: SourceWire.BookInput) async throws -> SourceWire.BookDetails {
            var ref = try reference(input.ref, kind: "book")
            guard let rules = source.ruleBookInfo else { throw SourceDomainError(.invalidInput, "Source has no book detail rules") }
            try reject([("Direct-download books", rules.downloadUrls)])
            context.variables = ref.variables; context.book = ref.legacyBook(source: source)
            var document = try await fetch(ref.request)
            if let initial = rules.`init`?.nonempty {
                guard let value = try await list(initial, document).first else { throw SourceDomainError(.invalidData, "Book init rule returned no document") }
                document = Document(value: value, base: document.base, fragment: true)
            }
            if let title = try await string(rules.name, document) { ref.title = title }
            if let author = try await string(rules.author, document) { ref.author = author }
            let description = try await string(rules.intro, document)
            let cover = try await string(rules.coverUrl, document)
            let toc = try await string(rules.tocUrl, document)
            ref.toc = try resolve(toc ?? document.base, base: document.base)
            ref.variables = context.variables
            return .init(ref: try ref.wire(), title: ref.title, author: ref.author,
                         cover: try cover.map { .init(url: try resolve($0, base: document.base)) }, description: description)
        }
        mutating func chapters(_ input: SourceWire.ChaptersInput) async throws -> SourceWire.ChapterPage {
            let book = try reference(input.book, kind: "book")
            guard let rules = source.ruleToc, var listRule = rules.chapterList?.nonempty else {
                throw SourceDomainError(.invalidInput, "Source has no catalog rules")
            }
            try reject([("Catalog pre-update JS", rules.preUpdateJs), ("Paid chapter actions", rules.isPay)])
            let reverse = listRule.hasPrefix("-")
            if reverse || listRule.hasPrefix("+") { listRule.removeFirst() }
            var cursor = try cursor(input.cursor, binding: "chapters:" + input.book.id)
            if cursor.pending.isEmpty { cursor.pending = [book.toc ?? book.request] }
            let request = cursor.pending.removeFirst()
            let fingerprint = SourceCoding.digest(Data(request.utf8))
            guard !cursor.visited.contains(fingerprint) else { throw SourceDomainError(.invalidData, "Catalog pagination loop") }
            cursor.visited.append(fingerprint)
            context.variables = cursor.page == 1 ? book.variables : cursor.variables
            context.page = cursor.page; context.book = book.legacyBook(source: source)
            let document = try await fetch(request)
            let values = try await list(listRule, document)
            let pageVariables = context.variables
            var items: [SourceWire.Chapter] = []
            var references: [Reference] = []
            var volumes: [SourceWire.Volume?] = []
            for value in values {
                context.variables = pageVariables
                let fragment = Document(value: value, base: document.base, fragment: true)
                guard var title = try await string(rules.chapterName, fragment) else { throw SourceDomainError(.invalidData, "Chapter lacks a title") }
                let url = try await string(rules.chapterUrl, fragment)
                let volume = try await string(rules.isVolume, fragment)
                if ["true", "1"].contains(volume ?? "") {
                    cursor.volume = .init(id: "legado.volume." + SourceCoding.digest(Data((book.bookRequest + title).utf8)), title: title)
                    continue
                }
                guard let url else { throw SourceDomainError(.invalidData, "Chapter lacks a URL") }
                let request = try resolve(url, base: document.base)
                context.chapter = .init(url: request, title: title, bookUrl: book.bookRequest, index: cursor.offset + references.count)
                if let format = rules.formatJs?.nonempty {
                    title = try await string("@js:" + format, Document(value: .string(title), base: document.base)) ?? title
                }
                references.append(Reference(scope: descriptor.identity.scope, kind: "chapter", request: request,
                                            bookRequest: book.bookRequest, title: title, variables: context.variables,
                                            index: cursor.offset + references.count))
                volumes.append(cursor.volume)
            }
            context.variables = pageVariables
            let next = try await links(rules.nextTocUrl, document)
            for link in next {
                let digest = SourceCoding.digest(Data(link.utf8))
                guard !cursor.visited.contains(digest) else { throw SourceDomainError(.invalidData, "Catalog pagination loop") }
                if !cursor.pending.contains(link) { cursor.pending.append(link) }
            }
            if reverse && !cursor.pending.isEmpty { throw RuleEngineError.unsupportedRule(rule: listRule, feature: "Reversed multipage catalog") }
            if reverse { references.reverse(); volumes.reverse() }
            for index in references.indices {
                if index + 1 < references.count { references[index].nextChapter = references[index + 1].request }
                items.append(.init(ref: try references[index].wire(), title: references[index].title, volume: volumes[index]))
            }
            cursor.offset += items.count; cursor.page += 1; cursor.variables = context.variables
            return .init(items: items, nextCursor: cursor.pending.isEmpty ? .null : try Self.json(cursor))
        }
        mutating func content(_ input: SourceWire.ContentInput) async throws -> SourceWire.ChapterContent {
            let book = try reference(input.book, kind: "book"), chapter = try reference(input.chapter, kind: "chapter")
            guard chapter.bookRequest == book.bookRequest else { throw SourceDomainError(.invalidInput, "Chapter belongs to another book") }
            guard let rules = source.ruleContent, let rule = rules.content?.nonempty else { throw SourceDomainError(.invalidInput, "Source has no content rule") }
            try reject([("Content WebView JS", rules.webJs), ("Content source switching", rules.sourceRegex),
                        ("Supplemental content", rules.subContent), ("Content image decoding", rules.imageDecode),
                        ("Paid content", rules.payAction), ("Content callback JS", rules.callBackJs)])
            context.variables = book.variables.merging(chapter.variables) { _, new in new }
            context.book = book.legacyBook(source: source)
            context.chapter = .init(url: chapter.request, title: chapter.title, bookUrl: book.bookRequest, index: chapter.index ?? 0)
            var queue = [chapter.request], visited = Set<String>(), parts: [String] = [], bytes = 0
            var title: String?
            while !queue.isEmpty {
                guard visited.count < 32 else { throw SourceDomainError(.resourceLimit, "Content pagination limit exceeded") }
                let request = queue.removeFirst()
                guard visited.insert(request).inserted else { throw SourceDomainError(.invalidData, "Content pagination loop") }
                let document = try await fetch(request)
                if title == nil { title = try await string(rules.title, document) }
                guard let text = try await string(rule, document) else { throw SourceDomainError(.invalidData, "Content rule returned an empty page") }
                bytes += text.utf8.count
                guard bytes <= 8_388_608 else { throw SourceDomainError(.resourceLimit, "Chapter content exceeds byte budget") }
                parts.append(text)
                for link in try await links(rules.nextContentUrl, document) where link != chapter.nextChapter {
                    guard !visited.contains(link) else { throw SourceDomainError(.invalidData, "Content pagination loop") }
                    if !queue.contains(link) { queue.append(link) }
                }
            }
            var text = parts.joined(separator: "\n")
            if let replacement = rules.replaceRegex?.nonempty {
                text = try await string(replacement, Document(value: .string(text), base: chapter.request)) ?? ""
            }
            guard !text.isEmpty, text.utf8.count <= 8_388_608 else { throw SourceDomainError(.invalidData, "Invalid final chapter content") }
            return .init(title: title ?? chapter.title, body: .text(.init(text: text)))
        }
    }
}

private extension String { var nonempty: String? { isEmpty ? nil : self } }
