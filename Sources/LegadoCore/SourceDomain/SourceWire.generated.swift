// Generated from protocols/source-v1/schema.json; do not edit.
// Shape only: source boundary validation remains mandatory.
import Foundation

public enum SourceWire {
    public struct SourceRef: Codable, Sendable, Equatable {
        public let id: String
        public let url: String?
        public let state: SourceJSON?
        public init(id: String, url: String? = nil, state: SourceJSON? = nil) {
            self.id = id
            self.url = url
            self.state = state
        }
        private enum CodingKeys: String, CodingKey { case id, url, state }
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            url = try container.decodeIfPresent(String.self, forKey: .url)
            state = container.contains(.state) ? try container.decode(SourceJSON.self, forKey: .state) : nil
        }
    }

    public struct Cover: Codable, Sendable, Equatable {
        public let url: String
        public init(url: String) {
            self.url = url
        }
    }

    public struct BookSummary: Codable, Sendable, Equatable {
        public let ref: SourceRef
        public let title: String
        public let author: String?
        public let cover: Cover?
        public init(ref: SourceRef, title: String, author: String? = nil, cover: Cover? = nil) {
            self.ref = ref
            self.title = title
            self.author = author
            self.cover = cover
        }
    }

    public struct BookDetails: Codable, Sendable, Equatable {
        public let ref: SourceRef
        public let title: String
        public let author: String?
        public let cover: Cover?
        public let `description`: String?
        public let status: String?
        public init(ref: SourceRef, title: String, author: String? = nil, cover: Cover? = nil, `description`: String? = nil, status: String? = nil) {
            self.ref = ref
            self.title = title
            self.author = author
            self.cover = cover
            self.`description` = `description`
            self.status = status
        }
    }

    public struct Volume: Codable, Sendable, Equatable {
        public let id: String
        public let title: String
        public init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }

    public struct Chapter: Codable, Sendable, Equatable {
        public let ref: SourceRef
        public let title: String
        public let volume: Volume?
        public init(ref: SourceRef, title: String, volume: Volume? = nil) {
            self.ref = ref
            self.title = title
            self.volume = volume
        }
    }

    public struct SearchPage: Codable, Sendable, Equatable {
        public let items: [BookSummary]
        public let nextCursor: SourceJSON
        public let revision: String?
        public init(items: [BookSummary], nextCursor: SourceJSON, revision: String? = nil) {
            self.items = items
            self.nextCursor = nextCursor
            self.revision = revision
        }
    }

    public struct ChapterPage: Codable, Sendable, Equatable {
        public let items: [Chapter]
        public let nextCursor: SourceJSON
        public let revision: String?
        public init(items: [Chapter], nextCursor: SourceJSON, revision: String? = nil) {
            self.items = items
            self.nextCursor = nextCursor
            self.revision = revision
        }
    }

    public struct TextBody: Codable, Sendable, Equatable {
        public let kind: String
        public let text: String
        public init(kind: String = "text", text: String) {
            self.kind = kind
            self.text = text
        }
    }

    public struct HTMLBody: Codable, Sendable, Equatable {
        public let kind: String
        public let html: String
        public let baseURL: String
        public init(kind: String = "html", html: String, baseURL: String) {
            self.kind = kind
            self.html = html
            self.baseURL = baseURL
        }
    }

    public struct ChapterContent: Codable, Sendable, Equatable {
        public let title: String?
        public let revision: String?
        public let body: Body
        public init(title: String? = nil, revision: String? = nil, body: Body) {
            self.title = title
            self.revision = revision
            self.body = body
        }
    }

    public struct SearchInput: Codable, Sendable, Equatable {
        public let query: String
        public let cursor: SourceJSON?
        public init(query: String, cursor: SourceJSON? = nil) {
            self.query = query
            self.cursor = cursor
        }
        private enum CodingKeys: String, CodingKey { case query, cursor }
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            query = try container.decode(String.self, forKey: .query)
            cursor = container.contains(.cursor) ? try container.decode(SourceJSON.self, forKey: .cursor) : nil
        }
    }

    public struct BookInput: Codable, Sendable, Equatable {
        public let ref: SourceRef
        public init(ref: SourceRef) {
            self.ref = ref
        }
    }

    public struct ChaptersInput: Codable, Sendable, Equatable {
        public let book: SourceRef
        public let cursor: SourceJSON?
        public init(book: SourceRef, cursor: SourceJSON? = nil) {
            self.book = book
            self.cursor = cursor
        }
        private enum CodingKeys: String, CodingKey { case book, cursor }
        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            book = try container.decode(SourceRef.self, forKey: .book)
            cursor = container.contains(.cursor) ? try container.decode(SourceJSON.self, forKey: .cursor) : nil
        }
    }

    public struct ContentInput: Codable, Sendable, Equatable {
        public let book: SourceRef
        public let chapter: SourceRef
        public init(book: SourceRef, chapter: SourceRef) {
            self.book = book
            self.chapter = chapter
        }
    }
}
