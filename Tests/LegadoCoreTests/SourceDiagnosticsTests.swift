import Foundation
import Testing
@testable import LegadoCore

@Suite("Native source recovery and diagnostic privacy")
struct SourceDiagnosticsTests {
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
}
