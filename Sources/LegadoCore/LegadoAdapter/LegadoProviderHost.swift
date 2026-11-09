import Foundation

/// Production assembly for the independent provider. All calls share native services but keep their scope.
public enum LegadoProviderHost {
    public static func makeProvider(installation: SourceInstallation, scope: SourceScope, configuration: SourceJSON? = nil,
                                    archive: SourceArchive, credentials: SourceCredentialSession? = nil,
                                    activityGate: SourceCommitGate? = nil, client: SourceHostHTTPClient = .init(),
                                    allowLoopbackHTTP: Bool = false, userAgent: String = LegadoURLBuilder.defaultUserAgent,
                                    record: @escaping @Sendable (String) -> Void = { _ in }) throws -> LegadoSourceProvider {
        guard scope.installationID == installation.id,
              installation.digest == SourceCoding.digest(Data(installation.source.utf8)) else {
            throw SourceDomainError(.invalidInput, "Invalid compatibility installation snapshot")
        }
        let source = try SourceCoding.decode(BookSource.self, from: Data(installation.source.utf8))
        let origins = Set(installation.origins)
        if let credentials {
            guard credentials.scope == scope, credentials.allowedOrigins == origins else {
                throw SourceDomainError(.invalidInput, "Compatibility credentials do not match the installation")
            }
        } else if scope.accountID != "guest" { throw SourceDomainError(.invalidInput, "Named account needs a credential session") }
        let identity = try SourceExecutionIdentity(scope: scope, sourceDigest: installation.digest,
                                                   configuration: configuration ?? .object([:]), credentialRevision: credentials?.revision)
        let gate = credentials?.commitGate ?? activityGate ?? SourceCommitGate()
        let descriptor = SourceProviderDescriptor(identity: identity, name: source.bookSourceName,
                                                  supportsSearch: source.searchUrl?.isEmpty == false, commitGate: gate)
        let policy = SourceHostHTTPPolicy(origins: origins, allowLoopbackHTTP: allowLoopbackHTTP, maximumAttempts: 1)
        _ = try policy.validate(source.bookSourceUrl)
        let jar = try LegadoCookieJar(scope: scope, origins: origins, credentials: credentials)
        return try LegadoSourceProvider(source: source, descriptor: descriptor) { control in
            // Revalidate the database snapshot at operation start. Source writes repeat this in their transaction.
            _ = try await archive.state(scope: scope, key: "legado.snapshot-check", expectedIdentity: identity)
            let state = try LegadoScopedSourceState(sourceID: source.id, identity: identity, archive: archive,
                                                   credentials: credentials, control: control)
            let cookies = LegadoScopedCookies(jar: jar, policy: policy, control: control, automatic: source.enabledCookieJar != false)
            let budget = SourceHTTPRequestBudget(maximumRequests: 64)
            let network = LegadoAsyncNetworkLoader(control: control) { request, follow in
                try control.check()
                let timeout = request.timeoutInterval.isFinite ? min(max(request.timeoutInterval, 0.001), policy.timeout) : policy.timeout
                return try await client.fetchCompatibility(request, followRedirects: follow, policy: policy,
                    deadline: min(control.deadline, ContinuousClock.now.advanced(by: .seconds(timeout))), budget: budget, credentials: cookies)
            }
            let identifier = SourceCoding.digest(try SourceCoding.encode(scope))
            return .init(sourceState: state, cookies: cookies, control: control, network: network, userAgent: userAgent,
                         networkHandlesCookies: true, identifier: { identifier }, record: record)
        }
    }
}
