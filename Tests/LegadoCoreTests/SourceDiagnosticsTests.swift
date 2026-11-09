import Foundation
import Testing
@testable import LegadoCore

@Suite("Native source recovery and diagnostic privacy")
struct SourceDiagnosticsTests {
    @Test func failedResponsesAreLocalBoundedCorrelatedAndExpire() async throws {
        let diagnostics = SourceDiagnostics(), now = Date()
        let identity = try SourceExecutionIdentity(scope: .init(installationID: UUID()), sourceDigest: String(repeating: "d", count: 64), configuration: .object([:]))
        let ids = (0..<9).map { _ in UUID() }
        let marker = "private-response-marker"
        let body = marker + String(repeating: "😀", count: 30_000)
        for (index, id) in ids.enumerated() {
            let response = SourceLocalResponse(response: .init(data: Data(body.utf8), statusCode: 202,
                headers: ["content-type": "text/html; charset=utf-8", "Set-Cookie": "private-session"],
                finalURL: URL(string: "https://user:password@fixture.invalid/book?token=private-query#secret")!))
            let failure = SourceExtractionFailure(field: .catalog, httpStatus: 202, responseBytes: body.utf8.count, responseID: id, localResponse: response)
            await diagnostics.record(id: id, operation: .chapters, identity: identity, issue: failure.issue,
                elapsedMilliseconds: 1, localResponse: response, now: now.addingTimeInterval(Double(index)))
        }
        let last = ids.last!
        #expect(await diagnostics.localResponse(id: ids[0], sourceDigest: identity.sourceDigest, now: now) == nil)
        #expect(await diagnostics.localResponse(id: last, sourceDigest: "another-source", now: now) == nil)
        let response = try #require(await diagnostics.localResponse(id: last, sourceDigest: identity.sourceDigest, now: now))
        #expect(response.body.hasPrefix(marker) && response.truncated)
        #expect(response.body.utf8.count <= 65_536 && !response.body.contains("�"))
        #expect(response.finalURL == "https://fixture.invalid/book?token=private-query")
        #expect(response.contentType == "text/html; charset=utf-8")
        let report = String(decoding: try await diagnostics.export(), as: UTF8.self)
        for secret in [marker, "private-session", "fixture.invalid", "private-query", "password", "text/html"] { #expect(!report.contains(secret)) }
        #expect(await diagnostics.localResponse(id: last, sourceDigest: identity.sourceDigest, now: now.addingTimeInterval(909)) == nil)
        let freshID = UUID(), fresh = SourceLocalResponse(response: .init(data: Data(), statusCode: 202, headers: [:], finalURL: URL(string: "https://fixture.invalid")!))
        let issue = SourceExtractionFailure(field: .catalog, httpStatus: 202, responseBytes: 0, responseID: freshID).issue
        await diagnostics.record(id: freshID, operation: .chapters, identity: identity, issue: issue, elapsedMilliseconds: 0, localResponse: fresh)
        await diagnostics.clear()
        #expect(await diagnostics.localResponse(id: freshID, sourceDigest: identity.sourceDigest) == nil)
    }
    @Test func extractionFactsAreBoundedAndOlderDiagnosticReportsRemainReadable() async throws {
        let detail = SourceExtractionContext(field: .content, httpStatus: 999, responseBytes: Int.max)
        #expect(detail.httpStatus == nil && detail.responseBytes == 8_388_608)
        let diagnostics = SourceDiagnostics()
        let identity = try SourceExecutionIdentity(scope: .init(installationID: UUID()), sourceDigest: String(repeating: "a", count: 64), configuration: .object([:]))
        await diagnostics.record(id: UUID(), operation: .content, identity: identity, issue: SourceExtractionFailure(field: .content, httpStatus: 202, responseBytes: 209).issue, elapsedMilliseconds: 10)
        let record = try #require(await diagnostics.records().first)
        #expect(record.extraction?.httpStatus == 202 && record.code == "EMPTY_CONTENT")
        var old = try #require(JSONSerialization.jsonObject(with: SourceCoding.encode(record)) as? [String: Any])
        old.removeValue(forKey: "extraction")
        #expect(try SourceCoding.decode(SourceDiagnosticRecord.self, from: JSONSerialization.data(withJSONObject: old)).extraction == nil)
    }
    @Test func rateLimitHonorsBoundedRetryTimeAndCannotTurnOtherFailuresIntoBackoff() {
        let now = Date(timeIntervalSince1970: 1000)
        let rate = SourceIssue(code: "RATE_LIMITED", retryAfterMs: 5000, now: now)
        #expect(!rate.canRetry(at: now.addingTimeInterval(4.99)))
        #expect(rate.canRetry(at: now.addingTimeInterval(5)))
        #expect(SourceIssue(code: "AUTH_REQUIRED", retryAfterMs: 5000, now: now).retryAt == nil)
        #expect(SourceIssue(code: "RATE_LIMITED", retryAfterMs: -1, now: now).retryAt == nil)
        #expect(SourceIssue(code: "RATE_LIMITED", retryAfterMs: Int.max, now: now).retryAt == nil)
        #expect(SourceIssue(code: "AUTH_REQUIRED").recovery == .login)
        #expect(SourceIssue(code: "STALE_SNAPSHOT").recovery == .refreshCatalog)
        #expect(SourceIssue(code: "PARSE").recovery == .inspectSource)
        #expect(SourceIssue(code: "NOT_DOWNLOADED").recovery == .none)
    }
    @Test func exportedDiagnosticsCannotContainRawAccountOrUntrustedCode() async throws {
        let diagnostics = SourceDiagnostics()
        let account = "secret-private-account-token"
        let identity = try SourceExecutionIdentity(scope: .init(installationID: UUID(), accountID: account),
            sourceDigest: String(repeating: "a", count: 64), configuration: .object(["private": .string("secret-config")]))
        let issue = SourceIssue(code: "Cookie: private-session; https://secret.example/private-query")
        await diagnostics.record(id: UUID(), operation: .search, identity: identity, issue: issue, elapsedMilliseconds: -200, line: -10, column: Int.max)
        let data = try await diagnostics.export(), json = String(decoding: data, as: UTF8.self)
        for secret in [account,"secret-config","private-session","secret.example","private-query"] { #expect(!json.contains(secret)) }
        let record = try #require(await diagnostics.records().first)
        #expect(record.code == "UNKNOWN")
        #expect(record.elapsedMilliseconds == 0)
        #expect(record.line == nil && record.column == nil)
        #expect(record.scopeDigest.count == 64)
    }
    @Test func diagnosticBufferIsBoundedOrderedAndClearedWithoutAffectingOtherInstances() async throws {
        let diagnostics = SourceDiagnostics(capacity: 2), separate = SourceDiagnostics()
        let identity = try SourceExecutionIdentity(scope: .init(installationID: UUID()), sourceDigest: String(repeating: "b", count: 64), configuration: .object([:]))
        let first = UUID(), second = UUID(), third = UUID()
        for id in [first, second, third] {
            await diagnostics.record(id: id, operation: .content, identity: identity, issue: nil, elapsedMilliseconds: Int.max)
        }
        let records = await diagnostics.records()
        #expect(records.map(\.id) == [third, second])
        #expect(records.allSatisfy { $0.elapsedMilliseconds == 300_000 && $0.code == "OK" })
        #expect(try await diagnostics.export().count < 131_072)
        #expect(await separate.records().isEmpty)
        await diagnostics.clear()
        #expect(await diagnostics.records().isEmpty)
    }

    @Test func sourceExcerptUsesExactDigestAndUTF16AcrossLineEndings() throws {
        for separator in ["\n", "\r\n", "\r", "\u{2028}", "\u{2029}"] {
            let source = ["first", "emoji 😀 line", "third", "fourth", "fifth", "sixth"].joined(separator: separator)
            let digest = SourceCoding.digest(Data(source.utf8))
            let excerpt = try SourceCodeExcerpt(source: source, expectedDigest: digest, line: 2, column: 9)
            #expect(excerpt.lines.map(\.number) == [1, 2, 3, 4])
            #expect(excerpt.lines.filter(\.selected).map(\.text) == ["emoji 😀 line"])
            #expect(excerpt.column == 9)
            #expect(throws: SourceDomainError.self) { try SourceCodeExcerpt(source: source + "changed", expectedDigest: digest, line: 2) }
            #expect(throws: SourceDomainError.self) { try SourceCodeExcerpt(source: source, expectedDigest: digest, line: 0) }
            #expect(throws: SourceDomainError.self) { try SourceCodeExcerpt(source: source, expectedDigest: digest, line: 7) }
            #expect(throws: SourceDomainError.self) { try SourceCodeExcerpt(source: source, expectedDigest: digest, line: 2, column: 99) }
        }
    }
    @Test func sourceExcerptBoundsOutputWithoutSplittingEmoji() throws {
        let source = String(repeating: "😀", count: 700)
        let excerpt = try SourceCodeExcerpt(source: source, expectedDigest: SourceCoding.digest(Data(source.utf8)), line: 1, column: 1201)
        #expect(excerpt.lines.count == 1 && excerpt.lines[0].text == String(repeating: "😀", count: 500) + "…")
    }
    @Test func diagnosticSourceLookupUsesRetainedHistoryAndNeverSubstitutesNewerVersion() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("source-diagnostic-\(UUID().uuidString)/native.sqlite3")
        let archive = try SourceArchive(url: url)
        let first = try SourceInstallation(publisherID: "org.example", name: "Source", version: "1", source: "source one", origins: ["https://example.org"])
        try await archive.saveInstallation(first)
        #expect(try await archive.sourceSnapshot(digest: first.digest) == first)
        var current = first
        for number in 2...9 {
            let next = try SourceInstallation(id: first.id, publisherID: first.publisherID, name: first.name, version: String(number),
                source: "source \(number)", origins: first.origins)
            try await archive.saveInstallation(next, replacing: current.digest)
            current = next
        }
        let reopened = try SourceArchive(url: url)
        #expect(try await reopened.sourceSnapshot(digest: first.digest) == first)
        let last = try SourceInstallation(id: first.id, publisherID: first.publisherID, name: first.name, version: "10", source: "source ten", origins: first.origins)
        try await archive.saveInstallation(last, replacing: current.digest)
        #expect(try await reopened.sourceSnapshot(digest: first.digest) == nil)
        #expect(try await reopened.sourceSnapshot(digest: current.digest) == current)
        #expect(try await reopened.sourceSnapshot(digest: last.digest) == last)
        await #expect(throws: SourceDomainError.self) { try await archive.sourceSnapshot(digest: "not-a-digest") }
    }
}
