import Foundation
import ImageIO

struct SourceCoverKey: Codable, Sendable, Equatable {
    let scope: SourceScope
    let digest: String
    init(identity: SourceExecutionIdentity, url: String) throws {
        struct Identity: Encodable { let execution: SourceExecutionIdentity; let url: String }
        scope = identity.scope
        digest = SourceCoding.digest(try SourceCoding.encode(Identity(execution: identity, url: url)))
    }
}
struct SourceCoverRecord: Sendable { let data: Data; let storedAt: Date }
struct SourceCoverRequest: Sendable { let key: SourceCoverKey; let generation: String; let cached: SourceCoverRecord? }
struct SourceCoverMetadata: Codable, Sendable { let storedAt: Date }
public struct SourceCoverStorageUsage: Sendable {
    public let count: Int
    public let bytes: Int
    public static let maximumBytes = 32 * 1024 * 1024
    public static let maximumCount = 128
}

/// ImageIO inspects dimensions before decoding, and only a bounded static thumbnail is persisted.
enum SourceCoverProcessor {
    static let maximumInputBytes = 2 * 1024 * 1024
    static let maximumThumbnailBytes = 1024 * 1024
    static func thumbnail(_ data: Data) throws -> Data {
        guard !data.isEmpty, data.count <= maximumInputBytes else { throw SourceDomainError(.resourceLimit, "封面文件超过 2 MiB。") }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              width.doubleValue.isFinite, height.doubleValue.isFinite,
              width.doubleValue >= 1, height.doubleValue >= 1,
              width.doubleValue <= 10_000, height.doubleValue <= 10_000,
              width.doubleValue * height.doubleValue <= 20_000_000 else {
            throw SourceDomainError(.invalidData, "封面不是可显示的图片，或像素尺寸过大。")
        }
        try Task.checkCancellation()
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 480,
            kCGImageSourceShouldCacheImmediately: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw SourceDomainError(.invalidData, "无法解码封面。")
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.png" as CFString, 1, nil) else {
            throw SourceDomainError(.unavailable, "无法生成封面缩略图。")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), output.length <= maximumThumbnailBytes else {
            throw SourceDomainError(.resourceLimit, "封面缩略图超过容量限制。")
        }
        try Task.checkCancellation()
        return output as Data
    }
}

/// All cover HTTP uses the same injected native client as source operations.
/// No URLSession, cookies, or remote image loader is created by the view.
public actor SourceCoverService {
    private let archive: SourceArchive
    private let client: SourceHostHTTPClient
    private let scheduler = SourceWorkScheduler(globalLimit: 2, perOriginLimit: 1)
    public init(archive: SourceArchive, client: SourceHostHTTPClient) { self.archive = archive; self.client = client }
    public func image(url: String, identity: SourceExecutionIdentity, origins: Set<String>,
                      credentials: SourceCredentialSession? = nil, gate: SourceCommitGate? = nil,
                      allowLoopbackHTTP: Bool = false, cachedOnly: Bool = false) async throws -> Data {
        guard (credentials == nil && identity.credentialRevision == nil) || (credentials?.scope == identity.scope && credentials?.revision == identity.credentialRevision
              && credentials?.allowedOrigins == origins) else {
            throw SourceDomainError(.invalidInput, "封面凭据与执行范围不一致。")
        }
        let gate = SourceCommitGate(parent: credentials?.commitGate ?? gate)
        try gate.check()
        let policy = SourceHostHTTPPolicy(origins: origins, allowLoopbackHTTP: allowLoopbackHTTP,
            maximumBytes: SourceCoverProcessor.maximumInputBytes, timeout: 12, maximumAttempts: 1)
        let validated = try policy.validate(url)
        let key = try SourceCoverKey(identity: identity, url: validated.absoluteString)
        let request = try await archive.prepareCover(key, gate: gate)
        try gate.check()
        if let cached = request.cached, cachedOnly || Date().timeIntervalSince(cached.storedAt) < 86_400 { return cached.data }
        if cachedOnly { throw SourceDomainError(.notDownloaded, "此账号尚未缓存封面。") }
        let data: Data
        do {
            data = try await scheduler.withPermit(origin: SourceHostHTTPPolicy.origin(validated)!, priority: .background,
                deadline: Date().addingTimeInterval(15)) {
                try gate.check()
                let response = try await self.client.fetch(.init(url: validated.absoluteString, headers: ["Accept": "image/*"]),
                    policy: policy, priority: .background, credentials: credentials)
                try gate.check()
                guard response.status == 200, let bytes = Data(base64Encoded: response.body) else {
                    throw SourceDomainError(.invalidData, "封面服务器未返回图片。")
                }
                return bytes
            }
        } catch let error as SourceHostHTTPFailure where error.code == .network || error.code == .timeout {
            try gate.check()
            if let cached = request.cached { return cached.data }
            throw error
        }
        try gate.check()
        let thumbnail = try SourceCoverProcessor.thumbnail(data)
        try gate.check()
        try await archive.saveCover(thumbnail, request: request, gate: gate)
        try gate.check()
        return thumbnail
    }
}
