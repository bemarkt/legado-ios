import Foundation
import SwiftSoup

public struct ChapterDocument: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public struct Mark: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable { case strong, emphasis }
        public let kind: Kind
        public let startUTF16: Int
        public var endUTF16: Int
    }
    public struct Block: Codable, Sendable, Equatable {
        public enum Kind: String, Codable, Sendable { case paragraph, heading }
        public let kind: Kind
        public let text: String
        public let headingLevel: Int?
        public let marks: [Mark]
    }
    public let normalizationVersion: Int
    public let revision: String?
    public let blocks: [Block]
    public var plainText: String { blocks.map(\.text).joined(separator: "\n\n") }
    public var digest: String { SourceCoding.digest(Data(plainText.utf8)) }
}

public enum ChapterNormalizer {
    public static func text(_ input: String) -> String {
        var value = input
        if value.first == "\u{feff}" { value.removeFirst() }
        value = value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").replacingOccurrences(of: "\0", with: "")
        var lines = value.components(separatedBy: "\n").map { line -> String in
            var line = line
            while let last = line.last, last == " " || last == "\t" || last == "\u{3000}" { line.removeLast() }
            return line
        }
        while lines.first == "" { lines.removeFirst() }
        while lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    public static func normalize(_ content: SourceWire.ChapterContent) throws -> ChapterDocument {
        let blocks: [ChapterDocument.Block]
        switch content.body {
        case .text(let body):
            guard body.text.utf8.count <= 8_388_608 else { throw SourceDomainError(.resourceLimit, "Chapter exceeds text budget") }
            let value = text(body.text)
            blocks = value.isEmpty ? [] : [.init(kind: .paragraph, text: value, headingLevel: nil, marks: [])]
        case .html(let body):
            guard body.html.utf8.count <= 8_388_608 else { throw SourceDomainError(.resourceLimit, "Chapter exceeds HTML budget") }
            blocks = try html(body.html)
        }
        guard !blocks.isEmpty else { throw SourceDomainError(.invalidData, "Chapter contains no readable text") }
        return ChapterDocument(normalizationVersion: ChapterDocument.currentVersion, revision: content.revision, blocks: blocks)
    }

    /// SwiftSoup never executes HTML or loads remote resources. Only text and finite marks leave this method.
    private static func html(_ input: String) throws -> [ChapterDocument.Block] {
        let document = try SwiftSoup.parseBodyFragment(input)
        guard let body = document.body() else { return [] }
        let dropped: Set<String> = ["script", "style", "iframe", "object", "embed", "template", "img", "video", "audio", "source", "canvas", "svg", "math", "noscript"]
        let boundaries: Set<String> = ["p", "div", "article", "section", "li", "ul", "ol", "blockquote", "pre", "tr", "hr", "h1", "h2", "h3", "h4", "h5", "h6"]
        var result: [ChapterDocument.Block] = []
        var buffer = ""
        var units = 0
        var marks: [ChapterDocument.Mark] = []
        var lastMark: [ChapterDocument.Mark.Kind: Int] = [:]
        var pendingSpace = false
        var heading: Int?
        var nodes = 0
        func append(_ string: String, styles: [ChapterDocument.Mark.Kind]) {
            let start = units
            buffer += string; units += string.utf16.count
            for style in styles {
                if let index = lastMark[style], marks[index].endUTF16 == start { marks[index].endUTF16 = units }
                else { lastMark[style] = marks.count; marks.append(.init(kind: style, startUTF16: start, endUTF16: units)) }
            }
        }
        func flush() {
            while buffer.last == " " || buffer.last == "\n" || buffer.last == "\t" { buffer.removeLast(); units -= 1 }
            if !buffer.isEmpty {
                let valid = marks.compactMap { mark -> ChapterDocument.Mark? in
                    guard mark.startUTF16 < units else { return nil }
                    return .init(kind: mark.kind, startUTF16: mark.startUTF16, endUTF16: min(mark.endUTF16, units))
                }
                result.append(.init(kind: heading == nil ? .paragraph : .heading, text: buffer, headingLevel: heading, marks: valid))
            }
            buffer = ""; units = 0; marks = []; lastMark = [:]; pendingSpace = false
        }
        func visit(_ node: Node, depth: Int, styles: [ChapterDocument.Mark.Kind], pre: Bool) throws {
            nodes += 1
            guard depth <= 128, nodes <= 100_000 else { throw SourceDomainError(.resourceLimit, "HTML structure budget exceeded") }
            if let node = node as? TextNode {
                let value = node.getWholeText().replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
                for scalar in value.unicodeScalars where scalar.value != 0 {
                    if !pre, [9, 10, 12, 13, 32].contains(scalar.value) { pendingSpace = !buffer.isEmpty && buffer.last != "\n"; continue }
                    if pendingSpace { append(" ", styles: styles); pendingSpace = false }
                    append(String(scalar), styles: styles)
                }
                return
            }
            guard let element = node as? Element else { return }
            let tag = element.tagName().lowercased()
            guard !dropped.contains(tag) else { return }
            if tag == "br" { pendingSpace = false; append("\n", styles: styles); return }
            let boundary = boundaries.contains(tag)
            let previousHeading = heading
            if boundary { flush(); heading = tag.count == 2 && tag.first == "h" ? Int(tag.dropFirst()) : nil }
            var styles = styles
            if ["strong", "b"].contains(tag), !styles.contains(.strong) { styles.append(.strong) }
            if ["em", "i"].contains(tag), !styles.contains(.emphasis) { styles.append(.emphasis) }
            for child in element.getChildNodes() { try visit(child, depth: depth + 1, styles: styles, pre: pre || tag == "pre") }
            if boundary { flush(); heading = previousHeading }
        }
        try visit(body, depth: 0, styles: [], pre: false)
        flush()
        return result
    }
}

public struct SourceReadingAnchor: Codable, Sendable, Equatable {
    public let chapter: SourceChapterKey
    public let documentDigest: String
    public let normalizationVersion: Int
    public let offsetUTF16: Int
    public let quote: String
    public let prefix: String

    public init(chapter: SourceChapterKey, document: ChapterDocument, offsetUTF16: Int) {
        let text = document.plainText as NSString
        let offset = Self.safeOffset(offsetUTF16, in: document.plainText)
        self.chapter = chapter; documentDigest = document.digest
        normalizationVersion = document.normalizationVersion; self.offsetUTF16 = offset
        let suffixRange = text.rangeOfComposedCharacterSequences(for: NSRange(location: offset, length: min(48, text.length - offset)))
        quote = text.substring(with: suffixRange)
        let prefixRange = text.rangeOfComposedCharacterSequences(for: NSRange(location: max(0, offset - 24), length: min(offset, 24)))
        prefix = text.substring(with: prefixRange)
    }

    public struct Resolution: Sendable, Equatable {
        public enum Method: String, Sendable { case exact, quote, nearest }
        public let offsetUTF16: Int
        public let method: Method
    }
    public func resolve(chapter: SourceChapterKey, document: ChapterDocument) throws -> Resolution {
        guard self.chapter == chapter else { throw SourceDomainError(.invalidInput, "Reading anchor belongs to another chapter or account") }
        let value = document.plainText
        if documentDigest == document.digest, normalizationVersion == document.normalizationVersion {
            return .init(offsetUTF16: Self.safeOffset(offsetUTF16, in: value), method: .exact)
        }
        let text = value as NSString
        if !quote.isEmpty {
            var remaining = NSRange(location: 0, length: text.length)
            var best: Int?
            var bestScore = Int.max
            while remaining.length > 0 {
                let match = text.range(of: quote, options: .literal, range: remaining)
                if match.location == NSNotFound { break }
                let before = text.substring(to: match.location)
                let score = abs(match.location - offsetUTF16) + (before.hasSuffix(prefix) ? 0 : text.length)
                if score < bestScore { best = match.location; bestScore = score }
                let next = match.location + max(1, match.length)
                remaining = NSRange(location: next, length: text.length - next)
            }
            if let best { return .init(offsetUTF16: Self.safeOffset(best, in: value), method: .quote) }
        }
        return .init(offsetUTF16: Self.safeOffset(offsetUTF16, in: value), method: .nearest)
    }
    private static func safeOffset(_ offset: Int, in text: String) -> Int {
        let value = text as NSString
        let clamped = min(max(offset, 0), value.length)
        return clamped == value.length ? clamped : value.rangeOfComposedCharacterSequence(at: clamped).location
    }
}
