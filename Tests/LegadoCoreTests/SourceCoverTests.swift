import Foundation
import ImageIO
import CoreGraphics
import Testing
@testable import LegadoCore

@Suite("Native cover loading and bounded cache", .timeLimit(.minutes(1)))
struct SourceCoverTests {
    private func database(bytes: Int = SourceCoverStorageUsage.maximumBytes, count: Int = SourceCoverStorageUsage.maximumCount) throws -> SourceArchive {
        try SourceArchive(url: FileManager.default.temporaryDirectory.appendingPathComponent("covers-\(UUID().uuidString)/native.sqlite3"), coverStorageBytes: bytes, coverStorageCount: count)
    }
    private func identity(scope: SourceScope? = nil, revision: String? = nil) throws -> SourceExecutionIdentity {
        try .init(scope: scope ?? SourceScope(installationID: UUID()), sourceDigest: String(repeating: "a", count: 64), configuration: .object([:]), credentialRevision: revision)
    }
    private func image(width: Int = 120, height: Int = 160, red: CGFloat = 0.5) throws -> Data {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: red, green: 0.2, blue: 0.7, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage()), data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return data as Data
    }
    private func waitForRequest(_ fixture: NativeHTTPFixture) async throws {
        for _ in 0..<300 {
            if await fixture.statistics().requests.count > 0 { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        throw URLError(.timedOut)
    }
    @Test func imageIsDownsampledBeforePersistenceAndInvalidInputsAreRejected() throws {
        let thumbnail = try SourceCoverProcessor.thumbnail(image(width: 1200, height: 1600))
        let source = try #require(CGImageSourceCreateWithData(thumbnail as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == 360)
        #expect((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == 480)
        #expect(thumbnail.count <= SourceCoverProcessor.maximumThumbnailBytes)
        #expect(throws: SourceDomainError.self) { try SourceCoverProcessor.thumbnail(Data("<html>login</html>".utf8)) }
        #expect(throws: SourceDomainError.self) { try SourceCoverProcessor.thumbnail(Data(count: SourceCoverProcessor.maximumInputBytes + 1)) }
        let oversized = try image(width: 10_001, height: 1)
        #expect(throws: SourceDomainError.self) { try SourceCoverProcessor.thumbnail(oversized) }
    }
    @Test func cacheUsesGlobalLRUAndSurvivesAnotherConnection() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cover-lru-\(UUID().uuidString)/native.sqlite3")
        let archive = try SourceArchive(url: url, coverStorageBytes: 6, coverStorageCount: 2)
        let a = try SourceCoverKey(identity: identity(), url: "https://fixture.example/a")
        let b = try SourceCoverKey(identity: identity(), url: "https://fixture.example/b")
        let c = try SourceCoverKey(identity: identity(), url: "https://fixture.example/c")
        for key in [a,b] {
            let request = try await archive.prepareCover(key, gate: .init())
            try await archive.saveCover(Data([1,2,3]), request: request, gate: .init())
        }
        _ = try await archive.prepareCover(a, gate: .init())
        let request = try await archive.prepareCover(c, gate: .init())
        try await archive.saveCover(Data([4,5,6]), request: request, gate: .init())
        let reopened = try SourceArchive(url: url)
        #expect(try await reopened.prepareCover(a, gate: .init()).cached?.data == Data([1,2,3]))
        #expect(try await reopened.prepareCover(b, gate: .init()).cached == nil)
        #expect(try await reopened.prepareCover(c, gate: .init()).cached?.data == Data([4,5,6]))
        #expect(try await reopened.coverStorageUsage().bytes == 6)
        #expect(try await reopened.coverStorageUsage().count == 2)
    }
    @Test func clearingAndRevocationRejectPendingCacheWrites() async throws {
        let archive = try database(), key = try SourceCoverKey(identity: identity(), url: "https://fixture.example/cover")
        let pending = try await archive.prepareCover(key, gate: .init())
        _ = try await archive.clearCoverCache()
        await #expect(throws: SourceDomainError.self) { try await archive.saveCover(Data([1]), request: pending, gate: .init()) }
        let next = try await archive.prepareCover(key, gate: .init()), gate = SourceCommitGate()
        gate.invalidate()
        await #expect(throws: SourceDomainError.self) { try await archive.saveCover(Data([2]), request: next, gate: gate) }
        #expect(try await archive.coverStorageUsage().count == 0)
    }
    @Test func sourceAccountConfigurationAndCredentialIdentityNeverShareCacheKeys() throws {
        let scope = try SourceScope(installationID: UUID(), accountID: UUID().uuidString)
        let base = try identity(scope: scope, revision: "login-a"), url = "https://fixture.example/image"
        let key = try SourceCoverKey(identity: base, url: url)
        let alternatives = try [identity(), identity(scope: scope, revision: "login-b"),
            SourceExecutionIdentity(scope: scope, sourceDigest: String(repeating: "b", count: 64), configuration: .object([:]), credentialRevision: "login-a"),
            SourceExecutionIdentity(scope: scope, sourceDigest: base.sourceDigest, configuration: .object(["mode": .bool(true)]), credentialRevision: "login-a")]
        for other in alternatives { #expect(try SourceCoverKey(identity: other, url: url).digest != key.digest) }
        #expect(try SourceCoverKey(identity: base, url: url + "?v=2").digest != key.digest)
    }
    @Test func freshCoverHitsDiskCacheWithoutAnotherHTTPAttempt() async throws {
        let bytes = try image()
        let fixture = try NativeHTTPFixture { _ in .init(headers: ["Content-Type": "image/png"], body: bytes) }
        let origin = try await fixture.start(); defer { fixture.stop() }
        let archive = try database(), identity = try identity()
        let service = SourceCoverService(archive: archive, client: .init())
        let first = try await service.image(url: origin + "/cover", identity: identity, origins: [origin], allowLoopbackHTTP: true)
        let second = try await service.image(url: origin + "/cover", identity: identity, origins: [origin], allowLoopbackHTTP: true)
        #expect(first == second)
        #expect(await fixture.statistics().requests.count == 1)
        let offline = try await SourceCoverService(archive: archive, client: .init()).image(url: origin + "/cover", identity: identity, origins: [origin], allowLoopbackHTTP: true, cachedOnly: true)
        #expect(offline == first)
        #expect(await fixture.statistics().requests.count == 1)
    }
    @Test func coversUseTheCorrectAccountCookieAndRejectGuests() async throws {
        let firstImage = try image(red: 0.1), secondImage = try image(red: 0.8)
        let fixture = try NativeHTTPFixture { request in
            if request.headers["cookie"] == "session=a" { return .init(body: firstImage) }
            if request.headers["cookie"] == "session=b" { return .init(body: secondImage) }
            return .init(status: 401)
        }
        let origin = try await fixture.start(); defer { fixture.stop() }
        let installation = UUID(), vault = SourceCredentialVault(persistence: MemorySourceCredentials())
        let a = try await vault.session(scope: .init(installationID: installation, accountID: "a"), allowedOrigins: [origin])
        let b = try await vault.session(scope: .init(installationID: installation, accountID: "b"), allowedOrigins: [origin])
        try await a.receive([.init(origin: origin, name: "session", value: "a", secure: false)])
        try await b.receive([.init(origin: origin, name: "session", value: "b", secure: false)])
        let service = SourceCoverService(archive: try database(), client: .init())
        let first = try await service.image(url: origin + "/private", identity: identity(scope: a.scope, revision: a.revision), origins: [origin], credentials: a, allowLoopbackHTTP: true)
        let second = try await service.image(url: origin + "/private", identity: identity(scope: b.scope, revision: b.revision), origins: [origin], credentials: b, allowLoopbackHTTP: true)
        #expect(first != second)
        await #expect(throws: SourceDomainError.self) {
            _ = try await service.image(url: origin + "/private", identity: identity(scope: .init(installationID: installation)), origins: [origin], allowLoopbackHTTP: true)
        }
        #expect(await fixture.statistics().requests.count == 3)
    }
    @Test func forbiddenCoverRedirectNeverReachesDestination() async throws {
        let target = try NativeHTTPFixture { _ in .init() }
        let denied = try await target.start(); defer { target.stop() }
        let redirect = try NativeHTTPFixture { _ in .init(status: 302, headers: ["Location": denied + "/cover"]) }
        let allowed = try await redirect.start(); defer { redirect.stop() }
        let service = SourceCoverService(archive: try database(), client: .init())
        await #expect(throws: SourceHostHTTPFailure.self) {
            _ = try await service.image(url: allowed + "/cover", identity: identity(), origins: [allowed], allowLoopbackHTTP: true)
        }
        #expect(await target.statistics().requests.isEmpty)
    }
    @Test func logoutAndCacheClearRejectImagesAlreadyDownloading() async throws {
        let bytes = try image()
        for logout in [true,false] {
            let fixture = try NativeHTTPFixture { _ in .init(body: bytes, delay: 0.2) }
            let origin = try await fixture.start(); defer { fixture.stop() }
            let archive = try database(), vault = SourceCredentialVault(persistence: MemorySourceCredentials())
            let session = try await vault.session(scope: .init(installationID: UUID(), accountID: "reader"), allowedOrigins: [origin])
            let identity = try identity(scope: session.scope, revision: session.revision)
            let service = SourceCoverService(archive: archive, client: .init())
            let task = Task { try await service.image(url: origin + "/slow", identity: identity, origins: [origin], credentials: session, allowLoopbackHTTP: true) }
            try await waitForRequest(fixture)
            if logout { try await vault.clear(scope: session.scope) }
            else { _ = try await archive.clearCoverCache() }
            do { _ = try await task.value; Issue.record("Stale image was accepted") }
            catch let error as SourceDomainError { #expect(error.code == .stale) }
            catch let error as SourceHostHTTPFailure { #expect(error.code == .stale) }
            #expect(try await archive.coverStorageUsage().count == 0)
        }
    }
}
