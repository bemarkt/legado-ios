import Foundation
import CryptoKit

/// P1 candidate data only. No Legado rules or engine objects cross this boundary.
struct SourceFailure: Error, Codable, Sendable, LocalizedError {
    let code: String
    let message: String
    var line: Int? = nil
    var column: Int? = nil
    var retryAfterMs: Int? = nil
    var errorDescription: String? {
        "\(code): \(message)" + (line.map { " (\($0):\(column ?? 1))" } ?? "")
    }
}

enum SourceOperation: String, CaseIterable, Sendable {
    case search, book, chapters, content
    var inputContract: String {
        switch self {
        case .search: "SearchInput"
        case .book: "BookInput"
        case .chapters: "ChaptersInput"
        case .content: "ContentInput"
        }
    }
    var outputContract: String {
        switch self {
        case .search: "SearchPage"
        case .book: "BookDetails"
        case .chapters: "ChapterPage"
        case .content: "ChapterContent"
        }
    }
}

enum SourceSettingValue: Codable, Sendable {
    case text(String), number(Double), flag(Bool)
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let flag = try? value.decode(Bool.self) { self = .flag(flag) }
        else if let text = try? value.decode(String.self) { self = .text(text) }
        else { self = .number(try value.decode(Double.self)) }
    }
    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .text(let text): try value.encode(text)
        case .number(let number): try value.encode(number)
        case .flag(let flag): try value.encode(flag)
        }
    }
}

struct SourceInspection: Decodable, Sendable {
    struct Metadata: Decodable, Sendable {
        let id: String
        let name: String
        let version: String
        let origins: [String]
        struct Setting: Decodable, Sendable { let `default`: SourceSettingValue }
        let settings: [String: Setting]?
    }
    let metadata: Metadata
    let operations: [String]
    let unsupportedRequirements: [String]
    let astNodes: Int
}

/// Created only after static inspection. Each operation holds this immutable UTF-8 snapshot.
struct SourceSnapshot: Sendable {
    let source: String
    let sha256: String
    let inspection: SourceInspection
    fileprivate init(source: String, inspection: SourceInspection) {
        self.source = source
        self.inspection = inspection
        sha256 = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct SourceProfile: Decodable, Sendable {
    struct Limits: Decodable, Sendable {
        let sourceBytes: Int
        let outputBytes: Int
        let httpResponseBytes: Int
        let operationHTTPRequests: Int
    }
    struct Parser: Decodable, Sendable { let timeoutMs: Int }
    struct Budgets: Decodable, Sendable {
        let moduleInitializationMs: Int
        let operationMs: Int
        let maxRedirects: Int
    }
    let limits: Limits
    let parser: Parser
    let experimentalRuntimeBudgets: Budgets

    static func load() throws -> Self {
        try JSONDecoder().decode(Self.self, from: SourceAssets.data("profile", extension: "json"))
    }
}

enum SourceAssets {
    static func data(_ name: String, extension suffix: String) throws -> Data {
        guard let url = Bundle.main.url(forResource: name, withExtension: suffix, subdirectory: "SourceRuntime") else {
            throw SourceFailure(code: "HOST_ERROR", message: "Missing source runtime resource: \(name)")
        }
        return try Data(contentsOf: url)
    }
    static func script(_ name: String) throws -> String {
        guard let value = String(data: try data(name, extension: "js"), encoding: .utf8) else {
            throw SourceFailure(code: "HOST_ERROR", message: "Invalid runtime resource encoding")
        }
        return value
    }
}

@MainActor
final class SourceInspector {
    private struct Envelope<T: Decodable>: Decodable {
        let value: T?
        let error: SourceFailure?
    }
    private let profile: SourceProfile
    init() throws { profile = try .load() }

    func inspect(_ data: Data) async throws -> SourceSnapshot {
        guard data.count <= profile.limits.sourceBytes else {
            throw SourceFailure(code: "RESOURCE_LIMIT", message: "Source byte budget exceeded")
        }
        guard let source = String(data: data, encoding: .utf8) else {
            throw SourceFailure(code: "INVALID_ENCODING", message: "Source must be UTF-8")
        }
        let result: SourceInspection = try await evaluate(
            "return JSON.stringify(SourceInspector.inspect(source));", arguments: ["source": source])
        return SourceSnapshot(source: source, inspection: result)
    }

    func validate(_ contract: String, json: String) async throws {
        guard json.utf8.count <= profile.limits.outputBytes else {
            throw SourceFailure(code: "RESOURCE_LIMIT", message: "JSON byte budget exceeded")
        }
        let _: Bool = try await evaluate(
            "return JSON.stringify(SourceInspector.validate(contract, json));",
            arguments: ["contract": contract, "json": json])
    }

    private func evaluate<T: Decodable>(_ body: String, arguments: [String: Any]) async throws -> T {
        // This trusted page receives source as a string; it never evaluates that source.
        let page = try SourceWebPage(script: SourceAssets.script("SourceInspector"))
        let json = try await page.perform(body, arguments: arguments,
                                          timeoutMs: profile.parser.timeoutMs, timeoutCode: "PARSER_TIMEOUT")
        let result = try JSONDecoder().decode(Envelope<T>.self, from: Data(json.utf8))
        if let error = result.error { throw error }
        guard let value = result.value else { throw SourceFailure(code: "HOST_ERROR", message: "Empty inspector result") }
        return value
    }
}
