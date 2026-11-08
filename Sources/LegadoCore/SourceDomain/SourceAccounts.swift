import Foundation

public struct SourceAccount: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let createdAt: Date
    public static let guest = SourceAccount(id: "guest", name: "访客", createdAt: Date(timeIntervalSince1970: 0))
    public init(name: String) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw SourceDomainError(.invalidInput, "账号名称需要 1 至 80 个可见字符。")
        }
        self.init(id: UUID().uuidString, name: name, createdAt: Date())
    }
    private init(id: String, name: String, createdAt: Date) { self.id = id; self.name = name; self.createdAt = createdAt }
}

/// Names and the selected local slot only. Passwords, tokens and cookies never enter SQLite.
public struct SourceAccountSettings: Codable, Sendable, Equatable {
    public var accounts: [SourceAccount]
    public var selectedID: String
    public init() { accounts = [.guest]; selectedID = "guest" }
    public var selected: SourceAccount { accounts.first { $0.id == selectedID } ?? .guest }
}
