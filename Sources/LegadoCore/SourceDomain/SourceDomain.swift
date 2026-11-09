import Foundation
import CryptoKit

/// JSON values cross the provider boundary; no engine or legacy rule objects do.
public indirect enum SourceJSON: Codable, Sendable, Equatable, Hashable {
    case null, bool(Bool), number(Double), string(String), array([SourceJSON]), object([String: SourceJSON])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode(Double.self) {
            guard value.isFinite, abs(value) <= 9_007_199_254_740_991 else {
                throw SourceDomainError(.invalidData, "JSON number exceeds the supported finite range")
            }
            self = .number(value)
        } else if let value = try? container.decode([SourceJSON].self) { self = .array(value) }
        else { self = .object(try container.decode([String: SourceJSON].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value):
            guard value.isFinite, abs(value) <= 9_007_199_254_740_991 else {
                throw SourceDomainError(.invalidData, "JSON number exceeds the supported finite range")
            }
            try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public func validatedData(maximumBytes: Int = 16_384) throws -> Data {
        var nodes = 0
        func visit(_ value: SourceJSON, depth: Int) throws {
            nodes += 1
            guard depth <= 32, nodes <= 100_000 else { throw SourceDomainError(.resourceLimit, "JSON structure budget exceeded") }
            switch value {
            case .array(let values): for child in values { try visit(child, depth: depth + 1) }
            case .object(let values):
                guard !values.keys.contains(where: { ["__proto__", "prototype", "constructor"].contains($0) }) else {
                    throw SourceDomainError(.invalidData, "Reserved JSON key")
                }
                for child in values.values { try visit(child, depth: depth + 1) }
            default: break
            }
        }
        try visit(self, depth: 0)
        let data = try SourceCoding.encode(self)
        guard data.count <= maximumBytes else { throw SourceDomainError(.resourceLimit, "JSON byte budget exceeded") }
        return data
    }
}

public enum SourceCoding {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
    static func fileDigest(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var digest = SHA256()
        while let chunk = try file.read(upToCount: 1_048_576), !chunk.isEmpty {
            try Task.checkCancellation(); digest.update(data: chunk)
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public struct SourceDomainError: Error, Sendable, LocalizedError, Equatable {
    public enum Code: String, Codable, Sendable {
        case invalidInput = "INVALID_INPUT", invalidData = "INVALID_DATA", resourceLimit = "RESOURCE_LIMIT"
        case cancelled = "CANCELLED", timeout = "TIMEOUT", stale = "STALE_SNAPSHOT", catalogChanged = "CATALOG_CHANGED"
        case storageConflict = "STORAGE_CONFLICT", notDownloaded = "NOT_DOWNLOADED", unavailable = "UNAVAILABLE"
    }
    public let code: Code
    public let message: String
    public init(_ code: Code, _ message: String) { self.code = code; self.message = message }
    public var errorDescription: String? { "\(code.rawValue): \(message)" }
}

extension SourceWire {
    public enum Body: Codable, Sendable, Equatable {
        case text(TextBody), html(HTMLBody)
        private enum Keys: String, CodingKey { case kind }
        public init(from decoder: Decoder) throws {
            let kind = try decoder.container(keyedBy: Keys.self).decode(String.self, forKey: .kind)
            switch kind {
            case "text": self = .text(try TextBody(from: decoder))
            case "html": self = .html(try HTMLBody(from: decoder))
            default: throw SourceDomainError(.invalidData, "Unknown chapter body kind")
            }
        }
        public func encode(to encoder: Encoder) throws {
            switch self {
            case .text(let value): try value.encode(to: encoder)
            case .html(let value): try value.encode(to: encoder)
            }
        }
    }
}

/// Installation identity is host-issued. "guest" is the backward-compatible default website session key.
/// SourceExecutionIdentity.libraryScope determines local book storage independently of this session.
public struct SourceScope: Codable, Hashable, Sendable {
    public let installationID: UUID
    public let accountID: String
    public init(installationID: UUID, accountID: String = "guest") throws {
        guard !accountID.isEmpty, accountID.utf8.count <= 128, !accountID.contains("\0") else {
            throw SourceDomainError(.invalidInput, "Invalid account scope")
        }
        self.installationID = installationID; self.accountID = accountID
    }
}

public struct SourceExecutionIdentity: Codable, Hashable, Sendable {
    public let scope: SourceScope
    /// The local shelf namespace is independent of the selected website session.
    /// Old records keep their original namespace, so downloads, notes and anchors need no destructive rewrite.
    private let libraryNamespace: SourceScope?
    public var libraryScope: SourceScope { libraryNamespace ?? scope }
    public let sourceDigest: String
    public let configurationDigest: String
    public let credentialRevision: String?
    public let permissionDigest: String?
    public init(scope: SourceScope, sourceDigest: String, configuration: SourceJSON, credentialRevision: String? = nil, approvedOrigins: [String]? = nil, libraryScope: SourceScope? = nil) throws {
        guard sourceDigest.count == 64, sourceDigest.allSatisfy({ $0.isHexDigit }) else {
            throw SourceDomainError(.invalidInput, "Invalid source digest")
        }
        self.scope = scope
        guard libraryScope == nil || libraryScope?.installationID == scope.installationID else {
            throw SourceDomainError(.invalidInput, "Library and website session belong to different installations")
        }
        libraryNamespace = libraryScope == scope ? nil : libraryScope
        self.sourceDigest = sourceDigest
        self.credentialRevision = credentialRevision
        permissionDigest = try approvedOrigins.map { SourceCoding.digest(try SourceCoding.encode(Array(Set($0)).sorted())) }
        configurationDigest = SourceCoding.digest(try configuration.validatedData(maximumBytes: 65_536))
    }
}

public struct SourceBookKey: Codable, Hashable, Sendable {
    public let scope: SourceScope
    public let bookID: String
    public init(scope: SourceScope, bookID: String) throws {
        try Self.validateID(bookID)
        self.scope = scope; self.bookID = bookID
    }
    static func validateID(_ value: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.unicodeScalars.count <= 1024, !value.contains("\0") else {
            throw SourceDomainError(.invalidInput, "Invalid stable identity")
        }
    }
}

public struct SourceChapterKey: Codable, Hashable, Sendable {
    public let book: SourceBookKey
    public let chapterID: String
    public init(book: SourceBookKey, chapterID: String) throws {
        try SourceBookKey.validateID(chapterID)
        self.book = book; self.chapterID = chapterID
    }
}

public struct SourceProviderDescriptor: Sendable {
    public let identity: SourceExecutionIdentity
    public let name: String
    public let supportsSearch: Bool
    /// A host-selected profile bound. Native modules retain the schema limit of 1,000.
    public let maximumChapterPageItems: Int
    public let commitGate: SourceCommitGate?
    public init(identity: SourceExecutionIdentity, name: String, supportsSearch: Bool = true, commitGate: SourceCommitGate? = nil, maximumChapterPageItems: Int = 1000) {
        self.identity = identity; self.name = name; self.supportsSearch = supportsSearch; self.commitGate = commitGate
        self.maximumChapterPageItems = min(5000, max(1, maximumChapterPageItems))
    }
}

/// Each provider instance pins source, account and configuration for the complete catalog flow.
public protocol SourceProvider: Sendable {
    var descriptor: SourceProviderDescriptor { get }
    func search(_ input: SourceWire.SearchInput) async throws -> SourceWire.SearchPage
    func book(_ input: SourceWire.BookInput) async throws -> SourceWire.BookDetails
    func chapters(_ input: SourceWire.ChaptersInput) async throws -> SourceWire.ChapterPage
    func content(_ input: SourceWire.ContentInput) async throws -> SourceWire.ChapterContent
}

/// Linearizes native commits against operation completion or supersession.
/// A mutation already committed before invalidation remains valid; no later commit is admitted.
public final class SourceCommitGate: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    private let parent: SourceCommitGate?
    public init(parent: SourceCommitGate? = nil) { self.parent = parent }
    func inherits(_ gate: SourceCommitGate) -> Bool { self === gate || parent?.inherits(gate) == true }
    public func check() throws { try withCommit { } }
    public func invalidate() { lock.lock(); active = false; lock.unlock() }
    public func withCommit<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        guard active else { throw SourceDomainError(.stale, "Operation already ended or was superseded") }
        try Task.checkCancellation()
        if let parent { return try parent.withCommit(body) }
        return try body()
    }
}
