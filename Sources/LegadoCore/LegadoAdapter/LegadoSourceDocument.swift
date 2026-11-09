import Foundation

/// Static JSON inspection. The original object bytes (including unknown fields) are the installation source.
/// No URL/header/jsLib or rule JavaScript is evaluated during import or update review.
public struct LegadoSourceDocument: Sendable {
    public let source: String
    public let bookSource: BookSource
    public let suggestedOrigins: [String]
    public var name: String { bookSource.bookSourceName }
    public var version: String { String(bookSource.lastUpdateTime) }
    public var publisherID: String { "legado." + SourceCoding.digest(Data(bookSource.bookSourceUrl.utf8)) }
    public var digest: String { SourceCoding.digest(Data(source.utf8)) }

    public static func inspect(_ text: String) throws -> [Self] {
        guard !text.isEmpty, text.utf8.count <= 2_097_152 else { throw SourceDomainError(.resourceLimit, "JSON 书源文件不能超过 2 MiB。") }
        let data = Data(text.utf8)
        let object = try JSONSerialization.jsonObject(with: data)
        if object is [String: Any] { return [try Self(source: text)] }
        guard let array = object as? [[String: Any]], !array.isEmpty, array.count <= 100 else {
            throw SourceDomainError(.invalidInput, "请选择一个书源对象或最多 100 个书源的 JSON 数组。")
        }
        return try array.map { value in
            let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
            return try Self(source: String(decoding: data, as: UTF8.self))
        }
    }
    private init(source: String) throws {
        let bookSource = try SourceCoding.decode(BookSource.self, from: Data(source.utf8))
        guard !bookSource.bookSourceName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              bookSource.bookSourceName.utf8.count <= 1024, bookSource.bookSourceType == 0,
              let base = URL(string: bookSource.bookSourceUrl), let baseOrigin = SourceHostHTTPPolicy.origin(base),
              SourceCredentialCookie.validOrigin(baseOrigin), base.user == nil, base.password == nil else {
            throw SourceDomainError(.invalidInput, "兼容入口需要有效名称、HTTPS 站点地址和文本小说书源。")
        }
        var origins = Set([baseOrigin])
        // Only declared literal URL fields suggest access. Strings inside executable scripts never grant access.
        for value in [bookSource.searchUrl, bookSource.loginUrl, bookSource.exploreUrl] {
            guard let value, let match = value.range(of: #"^https?://[^/\s,{}]+"#, options: .regularExpression),
                  let url = URL(string: String(value[match])), let origin = SourceHostHTTPPolicy.origin(url),
                  SourceCredentialCookie.validOrigin(origin) else { continue }
            origins.insert(origin)
        }
        self.source = source; self.bookSource = bookSource; suggestedOrigins = origins.sorted()
    }
    public func approvedOrigins(additional: String = "") throws -> [String] {
        let values = additional.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
        guard values.count <= 32, values.allSatisfy(SourceCredentialCookie.validOrigin) else {
            throw SourceDomainError(.invalidInput, "其他网站须填写完整 origin（例如 https://cdn.example），不能包含路径、账号或通配符。")
        }
        let origins = Set(suggestedOrigins + values)
        guard origins.count <= 32 else { throw SourceDomainError(.resourceLimit, "单个书源最多允许 32 个网站。") }
        return origins.sorted()
    }
    public func installation(id: UUID = UUID(), origins: [String], createdAt: Date = Date(),
                             originURL: String? = nil, locallyModified: Bool = false) throws -> SourceInstallation {
        guard !origins.isEmpty, origins.count <= 32, origins.allSatisfy(SourceCredentialCookie.validOrigin),
              Set(suggestedOrigins).isSubset(of: Set(origins)) else { throw SourceDomainError(.invalidInput, "书源访问范围尚未审阅。") }
        return try .init(id: id, publisherID: publisherID, name: name, version: version, source: source,
                         origins: origins.sorted(), createdAt: createdAt, originURL: originURL,
                         locallyModified: locallyModified, format: .legado)
    }
}
