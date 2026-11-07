// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import FloeManufacturingCore
@testable import FloeManufacturingUI

@Suite("Shared native manufacturing research sessions", .serialized)
@MainActor struct ManufacturingResearchSessionTests {
    private func stale(_ body:() throws -> Void) {
        do { try body();Issue.record("A stale research operation succeeded") }
        catch ManufacturingError.stale { }
        catch { Issue.record("Research CAS failed for an unrelated reason: \(error)") }
    }
    private func directory() -> URL {
        var root = URL(fileURLWithPath:#filePath)
        for _ in 0..<4 { root.deleteLastPathComponent() }
        return root.appendingPathComponent("Local/Scratch/manufacturing-research-\(UUID())")
    }
    @Test func missingInspectionCreatesNoExampleOrDirectoryAndDirtyUIRejectsAStaleTool() throws {
        let root = directory();defer { try? FileManager.default.removeItem(at:root) }
        let sessions = ManufacturingResearchSessions(directory:root,ownerDocumentID:"cad:contract")
        let empty = try sessions.snapshot(.engineeringAnalysis)
        #expect(empty.state == "none" && empty.contentJSON == nil && !FileManager.default.fileExists(atPath:root.path))
        var input = EngineeringAnalysisProject.demonstration();input.name = "Explicit test input"
        let configured = try sessions.configure(.engineeringAnalysis,inputJSON:ManufacturingStudy.encoder.encode(input),expectedFingerprint:empty.fingerprint)
        let ui = sessions.engineering()
        #expect(ui === sessions.engineering() && ui.project.id == input.id)
        ui.project.name = "Newer UI input"
        let edited = try sessions.snapshot(.engineeringAnalysis)
        #expect(edited.inputRevision > configured.inputRevision && edited.fingerprint != configured.fingerprint)
        stale {
            try sessions.configure(.engineeringAnalysis,inputJSON:ManufacturingStudy.encoder.encode(input),expectedFingerprint:configured.fingerprint)
        }
        #expect(ui.project.name == "Newer UI input")
        let parsed = try JSONDecoder().decode(EngineeringAnalysisProject.self,from:Data(try #require(edited.contentJSON).utf8))
        #expect(parsed.source.documentID == input.source.documentID && parsed.source.documentID != "cad:contract")
    }
    @Test func aRealEngineeringCalculationSavesAndHydratesWithoutASecondSolve() async throws {
        let root = directory();defer { try? FileManager.default.removeItem(at:root) }
        let sessions = ManufacturingResearchSessions(directory:root,ownerDocumentID:"cad:contract")
        let empty = try sessions.snapshot(.engineeringAnalysis),input = EngineeringAnalysisProject.demonstration()
        let prepared = try sessions.configure(.engineeringAnalysis,inputJSON:ManufacturingStudy.encoder.encode(input),expectedFingerprint:empty.fingerprint)
        var checks = 0
        let completed = try await sessions.calculateAndSave(.engineeringAnalysis,expectedFingerprint:prepared.fingerprint) { checks += 1 }
        #expect(completed.state == "completed" && completed.hasResult && checks == 2)
        let file = root.appendingPathComponent("engineering/latest.floeanalysis"),bytes = try Data(contentsOf:file)
        let actual = try EngineeringAnalysisArchive.open(file)
        #expect(actual.0.id == input.id && actual.1.inputSHA256 == completed.inputSHA256)
        let other = ManufacturingResearchSessions(directory:root,ownerDocumentID:"cad:contract")
        let before = try other.snapshot(.engineeringAnalysis)
        let restored = try other.adoptSaved(.engineeringAnalysis,data:bytes,isArchive:true,expectedFingerprint:before.fingerprint)
        #expect(restored.hasResult && restored.resultSHA256 == completed.resultSHA256)
        #expect(try Data(contentsOf:file) == bytes && other.engineering().work == nil)
    }
    @Test func explicitCancellationFencesTheRealWorkerAndReleaseCannotBeReused() async throws {
        let root = directory();defer { try? FileManager.default.removeItem(at:root) }
        let sessions = ManufacturingResearchSessions(directory:root,ownerDocumentID:"cad:contract")
        let empty = try sessions.snapshot(.engineeringAnalysis),input = EngineeringAnalysisProject.demonstration()
        _ = try sessions.configure(.engineeringAnalysis,inputJSON:ManufacturingStudy.encoder.encode(input),expectedFingerprint:empty.fingerprint)
        let ui = sessions.engineering();ui.calculate()
        let work = try #require(ui.work),running = try sessions.snapshot(.engineeringAnalysis)
        let operation = try #require(running.operationID)
        let cancelled = try sessions.cancel(.engineeringAnalysis,expectedFingerprint:running.fingerprint,operationID:operation)
        #expect(cancelled.state == "cancelling" && sessions.isBusy)
        await work.value
        #expect(try sessions.snapshot(.engineeringAnalysis).state == "cancelled")
        #expect(!sessions.isBusy && !ui.busy && ui.artifact == nil)
        #expect(!FileManager.default.fileExists(atPath:root.appendingPathComponent("engineering/latest.floeanalysis").path))
        stale {
            try sessions.cancel(.engineeringAnalysis,expectedFingerprint:running.fingerprint,operationID:operation)
        }
        sessions.release()
        stale { try sessions.snapshot(.engineeringAnalysis) }
    }
    @Test func savedHydrationCannotReplaceAnOpenDirtyConfigurationOrAcceptTheWrongFamily() throws {
        let root = directory();defer { try? FileManager.default.removeItem(at:root) }
        let sessions = ManufacturingResearchSessions(directory:root,ownerDocumentID:"cad:contract")
        let empty = try sessions.snapshot(.engineeringAnalysis),input = EngineeringAnalysisProject.demonstration()
        let configured = try sessions.configure(.engineeringAnalysis,inputJSON:ManufacturingStudy.encoder.encode(input),expectedFingerprint:empty.fingerprint)
        stale {
            try sessions.adoptSaved(.engineeringAnalysis,data:ManufacturingStudy.encoder.encode(input),isArchive:false,expectedFingerprint:configured.fingerprint)
        }
        #expect(sessions.engineering().project.id == input.id)
        let cellEmpty = try sessions.snapshot(.manufacturingCell)
        #expect(throws:(any Error).self) {
            try sessions.adoptSaved(.manufacturingCell,data:ManufacturingStudy.encoder.encode(input),isArchive:false,expectedFingerprint:cellEmpty.fingerprint)
        }
        #expect(try sessions.snapshot(.manufacturingCell).state == "none")
    }
}
#endif
