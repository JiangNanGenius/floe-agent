import Foundation
import Testing
import FloeToolboxDiagnostics
import FloeToolboxIPInformation
@testable import FloeToolboxQualification

@MainActor struct IPOwnerAdapterTests {
    @Test func theActualAppOwnerDistinguishesLoadFailureFromMissingDatabase() async {
        let owner = IPInformationAppOwner(loadService: { _ in throw IPInformationError.invalidStorage })
        let provider = owner.tracerouteProvider()
        do {
            _ = try await provider.databaseVersion()
            Issue.record("A loader failure must not become an empty database")
        } catch {
            #expect(error as? IPInformationError == .invalidStorage)
        }
        do {
            #expect(try await provider.lookupResult(for: "192.168.1.1") == .localOrSpecialUse)
        } catch { Issue.record("A local address does not require a loaded database: \(error)") }
    }

    @Test func theActualAppOwnerClassifiesLocalAddressesAndReportsAnEmptyStore() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("qualified-ip-owner-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = IPInformationAppOwner(storageRoot: root)
        let provider = owner.tracerouteProvider()
        #expect(try await provider.databaseVersion() == nil)
        #expect(try await provider.lookupResult(for: "8.8.8.8") == .databaseUnavailable)
        #expect(try await provider.lookupResult(for: "127.0.0.1") == .localOrSpecialUse)
    }
}
