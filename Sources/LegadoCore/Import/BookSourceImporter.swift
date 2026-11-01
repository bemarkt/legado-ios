import Compression
import CoreFoundation
import Foundation

public enum DuplicatePolicy: Sendable {
    case replace
    case skip
    case fail
}

public enum BookSourceImportError: Error, Equatable, LocalizedError {
    case emptyDocument
    case invalidDocument(String)
    case invalidSources([BookSourceIssue])
    case duplicate(String)

    public var errorDescription: String? {
        switch self {
        case .emptyDocument:
            return "导入内容为空"
        case .invalidDocument(let detail):
            return "无法解析书源 JSON：\(detail)"
        case .invalidSources(let issues):
            return issues.map(\.message).joined(separator: "；")
        case .duplicate(let url):
            return "书源已存在：\(url)"
        }
    }
}

public struct BookSourceImportResult: Sendable {
    public var sources: [BookSource]
    public var inserted: Int
    public var replaced: Int
    public var skipped: Int
    public var warnings: [BookSourceIssue]

    public init(
        sources: [BookSource],
        inserted: Int,
        replaced: Int,
        skipped: Int,
        warnings: [BookSourceIssue]
    ) {
        self.sources = sources
        self.inserted = inserted
        self.replaced = replaced
        self.skipped = skipped
        self.warnings = warnings
    }
}

public struct BookSourceImporter: Sendable {
    public static let maximumDocumentBytes = 50 * 1_024 * 1_024
    private let decoder: JSONDecoder

    public init() {
        decoder = JSONDecoder()
    }

    public struct RejectedSource: Sendable {
        public var source: BookSource
        public var issues: [BookSourceIssue]
    }

    public struct Inspection: Sendable {
        public var sources: [BookSource]
        public var rejected: [RejectedSource]
    }

    public func inspect(_ data: Data) throws -> Inspection {
        let cleaned = try normalizedData(data)
        let root: JSONValue
        do { root = try JSONValue.decode(data: cleaned) }
        catch { throw BookSourceImportError.invalidDocument(error.localizedDescription) }
        let entries: [JSONValue]
        switch root {
        case .array(let array): entries = array
        case .object: entries = [root]
        default: throw BookSourceImportError.invalidDocument("需要书源对象或数组")
        }
        guard !entries.isEmpty else { throw BookSourceImportError.emptyDocument }
        var sources: [BookSource] = []
        var rejected: [RejectedSource] = []
        for (index, entry) in entries.enumerated() {
            do {
                guard case .object = entry else { throw BookSourceImportError.invalidDocument("第 \(index + 1) 项不是对象") }
                let source = try decoder.decode(BookSource.self, from: JSONEncoder().encode(entry))
                let errors = BookSourceValidator.validate(source).filter { $0.severity == .error }
                if errors.isEmpty { sources.append(source) }
                else { rejected.append(.init(source: source, issues: errors)) }
            } catch {
                let placeholder = BookSource(bookSourceUrl: entry["bookSourceUrl"]?.stringValue ?? "",
                                             bookSourceName: entry["bookSourceName"]?.stringValue ?? "第 \(index + 1) 项")
                rejected.append(.init(source: placeholder, issues: [.init(severity: .error, code: "source.decode",
                    field: "[\(index)]", message: "第 \(index + 1) 项：\(error.localizedDescription)")]))
            }
        }
        return .init(sources: sources, rejected: rejected)
    }

    public func decode(_ data: Data) throws -> [BookSource] {
        let result = try inspect(data)
        guard result.rejected.isEmpty else { throw BookSourceImportError.invalidSources(result.rejected.flatMap(\.issues)) }
        return result.sources
    }

    public func normalizedData(_ data: Data) throws -> Data {
        guard data.count <= Self.maximumDocumentBytes else { throw BookSourceImportError.invalidDocument("书源文件超过 50 MB") }
        let cleaned = decodeText(stripUTF8BOM(decompressIfGzip(data)))
        guard cleaned.count <= Self.maximumDocumentBytes else { throw BookSourceImportError.invalidDocument("解压后书源超过 50 MB") }
        guard !String(decoding: cleaned, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BookSourceImportError.emptyDocument
        }
        return cleaned
    }

    public func prepare(
        data: Data,
        existing: [BookSource],
        duplicatePolicy: DuplicatePolicy = .replace
    ) throws -> BookSourceImportResult {
        let incoming = try decode(data)
        var fatalIssues: [BookSourceIssue] = []
        var warnings: [BookSourceIssue] = []
        for source in incoming {
            for issue in BookSourceValidator.validate(source) {
                if issue.severity == .error {
                    fatalIssues.append(issue)
                } else {
                    warnings.append(issue)
                }
            }
        }
        guard fatalIssues.isEmpty else {
            throw BookSourceImportError.invalidSources(fatalIssues)
        }

        var merged = existing
        var index = Dictionary(uniqueKeysWithValues: merged.enumerated().map { ($1.id, $0) })
        var inserted = 0
        var replaced = 0
        var skipped = 0

        for source in incoming {
            if let existingIndex = index[source.id] {
                switch duplicatePolicy {
                case .replace:
                    // 更新书源时保留本地已有的 Cookie 开关。
                    //
                    // `enabledCookieJar` 是设备侧的行为设置，不是站点规则；但它写在
                    // 书源 JSON 里，不少源直接写 `"enabledCookieJar": false`。整体替换
                    // 就会把用户本地打开的开关压回关闭，Cookie 其实还在库里，
                    // 只是不再读也不再发——用户抓包看到的就是「更新一次书源，登录态没了」。
                    //
                    // 只保留这一个字段：分组与启用状态由导入预览页的
                    // `keepOriginalGroup` / `keepOriginalEnabled` 决定，
                    // 在这里顺手覆盖会越权改掉用户刚做的选择。
                    var updated = source
                    updated.enabledCookieJar = merged[existingIndex].enabledCookieJar
                    merged[existingIndex] = updated
                    replaced += 1
                case .skip:
                    skipped += 1
                case .fail:
                    throw BookSourceImportError.duplicate(source.id)
                }
            } else {
                index[source.id] = merged.count
                merged.append(source)
                inserted += 1
            }
        }
        return .init(
            sources: merged,
            inserted: inserted,
            replaced: replaced,
            skipped: skipped,
            warnings: warnings
        )
    }

    private func stripUTF8BOM(_ data: Data) -> Data {
        let bom = Data([0xEF, 0xBB, 0xBF])
        return data.starts(with: bom) ? Data(data.dropFirst(3)) : data
    }

    private func decodeText(_ data: Data) -> Data {
        if let value = String(data: data, encoding: .utf8) { return Data(value.utf8) }
        if data.starts(with: [0xFF, 0xFE]), let value = String(data: data, encoding: .utf16LittleEndian) {
            return Data(value.utf8)
        }
        if data.starts(with: [0xFE, 0xFF]), let value = String(data: data, encoding: .utf16BigEndian) {
            return Data(value.utf8)
        }
        if let value = String(data: data, encoding: Self.gb18030Encoding) {
            return Data(value.utf8)
        }
        return data
    }

    private static var gb18030Encoding: String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
    }

    private func decompressIfGzip(_ data: Data) -> Data {
        guard data.count > 10, data[0] == 0x1F, data[1] == 0x8B, data[2] == 0x08 else { return data }
        var offset = 10
        let flags = Int(data[3])
        if flags & 0x04 != 0 {
            guard offset + 2 <= data.count - 8 else { return data }
            let extraLength = Int(data[offset]) | (Int(data[offset + 1]) << 8)
            offset += 2 + extraLength
        }
        if flags & 0x08 != 0 {
            while offset < data.count, data[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x10 != 0 {
            while offset < data.count, data[offset] != 0 { offset += 1 }
            offset += 1
        }
        if flags & 0x02 != 0 { offset += 2 }
        guard offset < data.count - 8 else { return data }
        let payload = Data(data[offset..<data.count - min(8, data.count - offset)])
        return inflate(payload) ?? data
    }

    private func inflate(_ payload: Data) -> Data? {
        var capacity = max(payload.count * 4, 64 * 1_024)
        while capacity > 0, capacity <= Self.maximumDocumentBytes + 1 {
            let destination = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            let produced = payload.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Int in
                guard let base = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(
                    destination, capacity,
                    base, payload.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
            if produced > 0, produced < capacity {
                let result = Data(bytes: destination, count: produced)
                destination.deallocate()
                return result
            }
            destination.deallocate()
            guard produced == capacity, capacity <= Int.max / 2 else { return nil }
            capacity = min(capacity * 2, Self.maximumDocumentBytes + 1)
            if capacity == produced { return nil }
        }
        return nil
    }
}
