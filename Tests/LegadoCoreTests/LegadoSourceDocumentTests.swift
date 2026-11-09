import Foundation
import Testing
@testable import LegadoCore

struct LegadoSourceDocumentTests {
    private let original = #"{"bookSourceUrl":"https://fixture.invalid","bookSourceName":"JSON fixture","futureField":{"keep":[1,true,"text"]},"ruleBookInfo":{"name":"$.title","futureRule":"untouched"},"jsLib":"while(true){}","header":"@js:throw new Error('must not execute')"}"#
    private func database() throws -> SourceArchive {
        try .init(url: FileManager.default.temporaryDirectory.appendingPathComponent("legacy-document-\(UUID().uuidString)/archive.sqlite"))
    }
    @Test func inspectionNeverRunsScriptsAndPreservesExactObjectBytesAndUnknownFields() throws {
        let doc = try #require(LegadoSourceDocument.inspect(original).first)
        #expect(doc.source == original)
        #expect(doc.suggestedOrigins == ["https://fixture.invalid"])
        let installed = try doc.installation(origins: doc.suggestedOrigins)
        #expect(installed.format == .legado)
        let restored = try SourceCoding.decode(SourceInstallation.self, from: SourceCoding.encode(installed))
        #expect(restored == installed)
        let data = try JSONSerialization.jsonObject(with: Data(restored.source.utf8)) as? [String: Any]
        #expect((data?["ruleBookInfo"] as? [String: Any])?["futureRule"] as? String == "untouched")
        #expect(data?["futureField"] != nil)
    }
    @Test func arraysAreSplitWithoutDroppingUnknownFieldsAndOnlyLiteralURLsSuggestOrigins() throws {
        let next = #"{"bookSourceUrl":"https://another.invalid","bookSourceName":"Second","searchUrl":"https://api.invalid/search?q={{key}}","jsLib":"java.ajax('https://never-grant.invalid')","newKey":17}"#
        let documents = try LegadoSourceDocument.inspect("[" + original + "," + next + "]")
        #expect(documents.count == 2)
        #expect(documents[1].suggestedOrigins == ["https://another.invalid", "https://api.invalid"])
        #expect(documents[1].source.contains("newKey"))
        #expect(try documents[1].approvedOrigins(additional: "https://cdn.invalid") == ["https://another.invalid", "https://api.invalid", "https://cdn.invalid"])
        #expect(throws: SourceDomainError.self) { try documents[1].approvedOrigins(additional: "https://cdn.invalid/path") }
        #expect(throws: SourceDomainError.self) { try documents[1].approvedOrigins(additional: "https://*.invalid") }
    }
    @Test func invalidOrUnsupportedSourcesAreNotInstalledAsNativeModules() throws {
        for source in ["[]", "[42]", "{}", #"{"bookSourceUrl":"https://fixture.invalid","bookSourceName":"Audio","bookSourceType":1}"#] {
            #expect(throws: (any Error).self) { try LegadoSourceDocument.inspect(source) }
        }
        #expect(throws: (any Error).self) { try LegadoSourceDocument.inspect("export const metadata = {}") }
    }
    @Test func oldInstallationRecordsDefaultToNativeAndFormatCannotChangeOnUpdate() async throws {
        let archive = try database()
        let legacy = try #require(LegadoSourceDocument.inspect(original).first).installation(origins: ["https://fixture.invalid"])
        var old = try #require(JSONSerialization.jsonObject(with: SourceCoding.encode(legacy)) as? [String: Any])
        old.removeValue(forKey: "format")
        let native = try SourceCoding.decode(SourceInstallation.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(native.format == .nativeModule)
        try await archive.saveInstallation(native)
        await #expect(throws: SourceDomainError.self) { try await archive.saveInstallation(legacy, replacing: native.digest) }
        #expect(try await archive.installation(native.id)?.format == .nativeModule)
    }
    @Test func multiSourceImportRollsBackIfAnyInstallationConflicts() async throws {
        let archive = try database()
        let doc = try #require(LegadoSourceDocument.inspect(original).first)
        let existing = try doc.installation(origins: doc.suggestedOrigins), fresh = try doc.installation(origins: doc.suggestedOrigins)
        try await archive.saveInstallation(existing)
        await #expect(throws: SourceDomainError.self) { try await archive.saveNewInstallations([fresh, existing]) }
        #expect(try await archive.installation(fresh.id) == nil)
        #expect(try await archive.installations().count == 1)
        let another = try doc.installation(origins: doc.suggestedOrigins)
        try await archive.saveNewInstallations([fresh, another])
        #expect(try await archive.installations().count == 3)
    }
    @Test func permissionChangeInvalidatesIdentityAndOldWritesEvenWithIdenticalSourceBytes() async throws {
        let archive = try database(), doc = try #require(LegadoSourceDocument.inspect(original).first)
        let first = try doc.installation(origins: doc.suggestedOrigins)
        try await archive.saveInstallation(first)
        let scope = try SourceScope(installationID: first.id)
        let identity = try SourceExecutionIdentity(scope: scope, sourceDigest: first.digest, configuration: .object([:]), approvedOrigins: first.origins)
        let updated = try doc.installation(id: first.id, origins: doc.approvedOrigins(additional: "https://cdn.invalid"))
        try await archive.saveInstallation(updated, replacing: first.digest, expectedOrigins: first.origins)
        #expect(updated.digest == first.digest)
        let next = try SourceExecutionIdentity(scope: scope, sourceDigest: updated.digest, configuration: .object([:]), approvedOrigins: updated.origins)
        #expect(next != identity)
        await #expect(throws: SourceDomainError.self) {
            try await archive.setState(scope: scope, key: "late", value: .string("bad"), expectedIdentity: identity)
        }
        await #expect(throws: SourceDomainError.self) {
            try await archive.saveInstallation(first, replacing: updated.digest, expectedOrigins: first.origins)
        }
        #expect(try await archive.installation(first.id) == updated)
    }
}
