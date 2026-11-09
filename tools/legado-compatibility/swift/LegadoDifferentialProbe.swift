import CryptoKit
import Foundation
import LegadoCore

private struct Corpus: Decodable {
    let schemaVersion: Int
    let referenceCommit: String
    let cases: [Fixture]
}

private struct Fixture: Decodable {
    let id: String
    let family: String
    let rule: String
    let input: String
    let mode: String
    let baseURL: String
    let variables: [String: String]
    let inspectVariables: [String]
    let sanityValues: [String]?
}

private struct Observation: Encodable {
    let id: String
    let outcome: String
    let values: [String]
    let variables: [String: String]
    let errors: [[String: String]]
}

private struct Report: Encodable {
    let schemaVersion = 1
    let engine = "swift-legacy-rule-engine"
    let referenceCommit: String
    let corpusSHA256: String
    let environment: [String: String]
    let results: [Observation]
}

private enum ProbeError: Error {
    case invalidArguments, invalidCorpus, networkNotAllowed, sanityFailed(String)
}

private struct OfflineNetworkLoader: JavaScriptNetworkLoading {
    func load(_ request: URLRequest) throws -> HTTPResponse {
        throw ProbeError.networkNotAllowed
    }
}

@main
struct LegadoDifferentialProbe {
    static func main() async throws {
        guard CommandLine.arguments.count == 3 else { throw ProbeError.invalidArguments }
        let input = URL(fileURLWithPath: CommandLine.arguments[1])
        let output = URL(fileURLWithPath: CommandLine.arguments[2])
        let data = try Data(contentsOf: input)
        guard data.count <= 1_048_576 else { throw ProbeError.invalidCorpus }
        let corpus = try JSONDecoder().decode(Corpus.self, from: data)
        guard corpus.schemaVersion == 1, !corpus.cases.isEmpty,
              Set(corpus.cases.map(\.id)).count == corpus.cases.count,
              corpus.cases.allSatisfy({ ["string", "list"].contains($0.mode) })
        else { throw ProbeError.invalidCorpus }
        var observations: [Observation] = []
        for fixture in corpus.cases {
            let engine = RuleEngine(javaScript: JavaScriptRuleEvaluator(networkLoader: OfflineNetworkLoader()))
            let result = await engine.evaluate(
                fixture.rule, inText: fixture.input, baseURL: fixture.baseURL,
                listMode: fixture.mode == "list",
                context: .init(variables: fixture.variables, baseURL: fixture.baseURL)
            )
            let failures = result.diagnostics.filter { $0.severity == .error }
            let values: [String]
            if failures.isEmpty, fixture.mode == "string" {
                values = [result.strings.joined(separator: "\n")]
            } else {
                values = result.strings
            }
            observations.append(Observation(
                id: fixture.id, outcome: failures.isEmpty ? "success" : "error", values: values,
                variables: Dictionary(uniqueKeysWithValues: fixture.inspectVariables.map {
                    ($0, result.variables[$0] ?? "")
                }),
                errors: result.diagnostics.map { ["code": $0.code, "message": String($0.message.prefix(1024)), "severity": $0.severity.rawValue] }
            ))
        }
        let report = Report(
            referenceCommit: corpus.referenceCommit,
            corpusSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            environment: ["os": ProcessInfo.processInfo.operatingSystemVersionString,
                          "appCommit": ProcessInfo.processInfo.environment["GITHUB_SHA"] ?? "local-unverified"],
            results: observations
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(report).write(to: output, options: .atomic)
        for (fixture, observation) in zip(corpus.cases, observations) {
            if let sanity = fixture.sanityValues,
               observation.outcome != "success" || observation.values != sanity {
                throw ProbeError.sanityFailed(fixture.id)
            }
        }
        print("Recorded \(observations.count) offline rule cases; this is not a provider compatibility verdict.")
    }
}
