// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import FloeElectronicsCore
@testable import FloeElectronicsUI
import FloeWorkspace
@testable import FloeApp

@MainActor @Suite("Electronics generated-output preview")
struct ElectronicsOutputPreviewTests {
    private func project() -> EDAProject {
        var project = EDAProject(title: "Generated preview fixture")
        project.revision = 7
        var board = EDABoard(outline: [.init(0,0),.init(30,0),.init(30,20),.init(0,20)])
        board.edgePlated = false
        board.tracks = [.init(netID: "A", width: 0.3, points: [.init(2,2),.init(8,2)])]
        board.holes = [.init(position: .init(5,8), diameter: 0.8),
            .init(position: .init(12,8), diameter: 1.0, endPosition: .init(16,10))]
        project.boards = [board]
        return project
    }
    private func expectExact(_ package: EngineeringPreviewPackage, file: EDAExchangeFile) throws {
        #expect(package.kind == .gerber && package.backend == .gerber)
        #expect(package.name == file.name && package.files.count == 1)
        let resource = try #require(package.files.first)
        #expect(resource.name == file.name && Data(base64Encoded: resource.base64) == file.data)
        #expect(package.provenance.sourceName == file.name)
        #expect(package.provenance.sourceSHA256 == file.sha256)
        #expect(package.provenance.sourceByteCount == file.data.count)
        #expect(package.provenance.resourceCount == 1 && package.provenance.resourceByteCount == file.data.count)
        #expect(package.provenance.resources == [.init(name: file.name, byteCount: file.data.count, sha256: file.sha256)])
        #expect(package.provenance.isWithinDefaultLimits)
    }

    @Test("Real generated Gerber and slot/drill bytes reach the reader package without saving the project")
    func generatedOutputsKeepProvenanceAndSavedOriginal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = project(), store = try await EDAProjectStore.create(root: directory, project: original)
        let before = try await store.load()
        var count = 0
        for format in [EDAExportFormat.gerber, .excellon] {
            let output = try EDAExchange.export(before.project, format: format, boardID: original.boards[0].id)
            #expect(output.projectID == original.id && output.revision == before.project.revision)
            for file in output.files where EngineeringPreviewKind.identify(file.name) == .gerber {
                try expectExact(ElectronicsExportPreviewPreparation.package(file: file), file: file)
                count += 1
            }
        }
        #expect(count >= 3)
        #expect(try await store.load() == before)
        #expect(try await store.history().isEmpty)
    }

    @Test("Frozen actual native manufacturing files keep their recorded SHA and provenance")
    func frozenNativeOutputsKeepRecordedHashAndBytes() throws {
        // These small bytes came from real native manufacturing runs. Their
        // recorded hashes keep this regression independent of new writer output.
        let files: [(String, String, String, String)] = [
            ("Copper-L01.gbr","application/vnd.gerber","RzA0IEZsb2UgcHJvamVjdCAyODk5OEZBRS0zM0JCLTRGNzUtOTBGOC0wNkEyQzZDNUMwOTMgYm9hcmQgMUNERUM0MUQtQTlEMy00MDcyLUI5NDQtRTE1MUExQzc5NjczIHJldmlzaW9uIDEqCiVGU0xBWDY2WTY2KiUKJU1PTU0qJQolVEYuRmlsZUZ1bmN0aW9uLENvcHBlcixMMSxUb3AqJQolVEYuRmlsZVBvbGFyaXR5LFBvc2l0aXZlKiUKJUxQRColCiVBTUZMT0UxMCoyMSwxLDAuOTAwMDAwLDAuOTUwMDAwLDAsMCwwLjAwMDAwMDAwMColCiVBREQxMEZMT0UxMColCkcwMSoKRDEwKgpYOTIwMDAwMFkxMDAwMDAwMEQwMyoKRDEwKgpYMTA4MDAwMDBZMTAwMDAwMDBEMDMqCk0wMioK","3e372b53c8655fd4fc0b644316d8a78a141259a43d0feb59fbbd89e48f31612a"),
            ("Drill-NPTH-L01-L04.drl","application/x-excellon","OyBGbG9lIHByb2plY3QgMDAwMDAwMDAtMDAwMC0wMDAwLTAwMDAtMDAwMDAwMDAwMDAxIGJvYXJkIDAwMDAwMDAwLTAwMDAtMDAwMC0wMDAwLTAwMDAwMDAwMDAwMiByZXZpc2lvbiA3CjsgI0AhIFRGLkZpbGVGdW5jdGlvbixOb25QbGF0ZWQsMSw0LE5QVEgsTWl4ZWQKTTQ4Ck1FVFJJQwpUMDFDMS4wMDAwMDAKVDAyQzEuMjAwMDAwCiUKRzA1ClQwMQpYMTAuMDAwMDAwWTMwLjAwMDAwMApHMDUKVDAyCkcwMFgyMC4wMDAwMDBZMzAuMDAwMDAwClQwMgpNMTUKRzAxWDI0LjAwMDAwMFkzMy4wMDAwMDAKTTE2Ck0zMAo=","8978b6a563770adce90c37ea5b4d1f75e3f005832c22793b685ce54e7f3bb4db")
        ]
        for (name, mime, encoded, expectedSHA) in files {
            let bytes = try #require(Data(base64Encoded: encoded))
            let file = EDAExchangeFile(name: name, mimeType: mime, data: bytes)
            #expect(file.sha256 == expectedSHA)
            let package = try ElectronicsExportPreviewPreparation.package(file: file)
            try expectExact(package, file: file)
            #expect(package.provenance.sourceSHA256 == expectedSHA)
            let reopened = try JSONDecoder().decode(EngineeringPreviewPackage.self, from: JSONEncoder().encode(package))
            #expect(reopened.provenance == package.provenance)
            #expect(reopened.files.first?.base64 == package.files.first?.base64)
        }
    }

    @Test("Unsupported, empty and oversized outputs cannot mint an empty or substituted preview")
    func unsupportedAndOutOfBudgetFilesRefusePreview() {
        for file in [
            EDAExchangeFile(name: "Gerber-manifest.json", mimeType: "application/json", data: Data("{}".utf8)),
            EDAExchangeFile(name: "../Board.gbr", mimeType: "application/vnd.gerber", data: Data("M02*".utf8)),
            EDAExchangeFile(name: "Empty.gbr", mimeType: "application/vnd.gerber", data: Data()),
            EDAExchangeFile(name: "Large.gbr", mimeType: "application/vnd.gerber", data: Data(count: EngineeringPreviewPackage.maximumBytes + 1))
        ] {
            #expect(throws: ElectronicsExportPreviewPreparation.Failure.self) {
                try ElectronicsExportPreviewPreparation.package(file: file)
            }
        }
    }

    @Test("Default nil preview and existing trailing assistant closure remain source-compatible")
    func legacyInitializersKeepTheirOriginalCallbacks() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try await EDAProjectStore.create(root: directory, project: project())
        let session = try await EDWorkbenchSession(store: store)
        let oldCall = EDWorkbenchView(session: session) {}
        #expect(oldCall.onAssistant != nil && oldCall.onExportPreview == nil)
        let oldOutputs = EDAOutputsView(session: session)
        #expect(oldOutputs.onExportPreview == nil)
        let newCall = EDWorkbenchView(session: session, onExportPreview: { _, _ in })
        #expect(newCall.onExportPreview != nil && newCall.onAssistant == nil)
        await session.close()
    }
}
#endif
