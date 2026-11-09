import Foundation

/// Local per-book choices. Nil follows the global reader setting; website sessions are unrelated.
public struct SourceReaderPreferences: Codable, Sendable, Equatable {
    public var useReplaceRules: Bool?
    public var pageAnimation: Int?
    public var ttsEngine: String?
    public init(useReplaceRules: Bool? = nil, pageAnimation: Int? = nil, ttsEngine: String? = nil) {
        self.useReplaceRules = useReplaceRules; self.pageAnimation = pageAnimation; self.ttsEngine = ttsEngine
    }
}

/// Patch one choice in a transaction rather than replacing a stale snapshot of all choices.
public enum SourceReaderPreferenceChange: Sendable {
    case useReplaceRules(Bool?), pageAnimation(Int?), ttsEngine(String?)
}

public struct SourceReaderBookmark: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let revision: String
    public let anchor: SourceReadingAnchor
    public let chapterTitle: String
    public let selectedText: String
    public let note: String
    public let createdAt: Date
    public let updatedAt: Date
}

/// A local reading lease. Opening another reader for this book revokes progress writes
/// from the earlier reader; a website login change does not revoke it.
public struct SourceReaderSession: Codable, Sendable, Equatable {
    public let id: UUID
    public let book: SourceBookKey
    public let startedAt: Date
}

/// Cumulative elapsed time makes retries idempotent. Sequence orders progress within a session,
/// while the active session id orders different readers. Neither ordering uses wall-clock time.
public struct SourceReaderCheckpoint: Codable, Sendable, Equatable {
    public let session: SourceReaderSession
    public let sequence: UInt64
    public let elapsedMilliseconds: Int64
    public let updatedAt: Date
    public let anchor: SourceReadingAnchor?
    public let ended: Bool

    public init(session: SourceReaderSession, sequence: UInt64, elapsedMilliseconds: Int64,
                updatedAt: Date = Date(), anchor: SourceReadingAnchor? = nil, ended: Bool = false) {
        self.session = session; self.sequence = sequence; self.elapsedMilliseconds = elapsedMilliseconds
        self.updatedAt = updatedAt; self.anchor = anchor; self.ended = ended
    }
}
