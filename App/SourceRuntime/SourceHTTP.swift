import Foundation
#if SWIFT_PACKAGE
import LegadoCore
#endif

typealias SourceHTTPRequest = SourceHostHTTPRequest
typealias SourceHTTPResponse = SourceHostHTTPResponse
typealias SourceHTTPPolicy = SourceHostHTTPPolicy

/// Shared by source execution and source-file import. Policy and transport are native-core responsibilities.
enum SourceHTTP {
    private static let client = SourceHostHTTPClient()
    static func fetch(_ input: SourceHTTPRequest, policy: SourceHTTPPolicy, priority: SourceWorkScheduler.Priority = .reading,
                      deadline: ContinuousClock.Instant? = nil, budget: SourceHTTPRequestBudget? = nil) async throws -> SourceHTTPResponse {
        do { return try await client.fetch(input, policy: policy, priority: priority, deadline: deadline, budget: budget) }
        catch let failure as SourceHostHTTPFailure { throw SourceFailure(code: failure.code.rawValue, message: failure.message) }
    }
}
