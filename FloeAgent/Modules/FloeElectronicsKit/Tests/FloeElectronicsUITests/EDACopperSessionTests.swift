// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import FloeElectronicsCore
@testable import FloeElectronicsUI

/// Controls only the public cancellation predicate to hold a real detached
/// fill at its first cancellation checkpoint. Geometry/store are not mocked.
private final class CopperFillGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var opened = false
    private var didEnter = false
    private var sawCancellation = false
    private var deadlineExpired = false
    var entered: Bool { condition.lock(); defer { condition.unlock() }; return didEnter }
    var observedCancellation: Bool { condition.lock(); defer { condition.unlock() }; return sawCancellation }
    var timedOut: Bool { condition.lock(); defer { condition.unlock() }; return deadlineExpired }
    func release() { condition.lock(); opened=true;condition.broadcast();condition.unlock() }
    func check() -> Bool {
        condition.lock(); defer { condition.unlock() }
        didEnter = true; condition.broadcast()
        let limit=Date().addingTimeInterval(3)
        while !opened && !Task.isCancelled && Date()<limit { _=condition.wait(until:Date().addingTimeInterval(0.005)) }
        if !opened && !Task.isCancelled { deadlineExpired=true }
        sawCancellation = sawCancellation || Task.isCancelled
        return Task.isCancelled || deadlineExpired
    }
}

@MainActor struct EDACopperSessionTests {
    private func original() throws -> EDAProject {
        var p=EDAProject(title:"Real session copper refill")
        p.sheets[0].labels=[.init(name:"GND",position:.zero,scope:.global)]
        let net=try EDAConnectivity.derive(p).nets[0].id
        p.boards[0].zones=[EDACopperFill.newZone(netID:net,layer:"F.Cu",outline:p.boards[0].outline)]
        return p
    }
    private func root() throws -> URL {
        let base=try #require(ProcessInfo.processInfo.environment["FLOE_COPPER_TEST_TEMP"])
        return URL(fileURLWithPath:base).appendingPathComponent(UUID().uuidString)
    }
    private func awaitEntry(_ gate:CopperFillGate) async -> Bool {
        let limit=Date().addingTimeInterval(2)
        while !gate.entered && Date()<limit { await Task.yield() }
        return gate.entered
    }
    private func cancelled(_ result:Result<EDACopperFillReport,Error>) -> Bool {
        guard case .failure(let error)=result else{return false}
        if error is CancellationError{return true}
        if case EDAError.cancelled=error{return true}
        return false
    }

    @Test func refillPersistsThroughSameSessionAndUndoRebindsRealGeometry() async throws {
        let directory=try root();defer{try? FileManager.default.removeItem(at:directory)}
        let project=try original(),store=try await EDAProjectStore.create(root:directory,project:project)
        let session=try await EDWorkbenchSession(store:store)
        var saves=0;session.onSaved={_ in saves+=1}
        let report=try await session.refillCopper(boardID:project.boards[0].id,expectedRevision:0)
        #expect(saves==1 && report.resultRevision==1 && !session.isDirty)
        #expect(try await store.load().project==session.project)
        #expect(session.project.boards[0].zones[0].thermalRelief == .creationDefault)
        #expect(session.project.boards[0].zones[0].fillState == .filled)
        try await session.undo(expectedRevision:1)
        #expect(session.project.boards[0].zones[0].fillRevision==nil)
        try await session.redo(expectedRevision:2)
        #expect(session.project.boards[0].zones[0].fillRevision==3 && session.project.boards[0].zones[0].fillState == .filled)
        var zone=session.project.boards[0].zones[0];zone.thermalRelief?.gap=0.4
        try await session.apply([.putZone(board:project.boards[0].id,zone)],expectedRevision:3)
        #expect(session.project.boards[0].zones[0].fillState==nil && session.copperFillReport==nil)
        #expect(try await store.load().project.boards[0].zones[0].fillRevision==nil)
        try await session.createCopperZone(boardID:project.boards[0].id,netID:project.boards[0].zones[0].netID,
            layer:"B.Cu",outline:project.boards[0].outline,expectedRevision:4)
        #expect(session.project.boards[0].zones.count==2)
        #expect(session.project.boards[0].zones[1].thermalRelief == .creationDefault)
        #expect(session.selection.objectIDs == [session.project.boards[0].zones[1].id])
        await session.close();#expect(session.isClosed)
    }

    @Test func cancellationAndCloseJoinNativeWorkerWithoutLateSave() async throws {
        for close in [false,true] {
            let directory=try root()
            let project=try original(),store=try await EDAProjectStore.create(root:directory,project:project)
            let session=try await EDWorkbenchSession(store:store),gate=CopperFillGate()
            var saves=0;session.onSaved={_ in saves+=1}
            let operation=Task { @MainActor in try await session.refillCopper(boardID:project.boards[0].id,cancelled:{gate.check()}) }
            let entered=await awaitEntry(gate)
            #expect(entered && session.isFilling)
            if close { await session.close() } else { session.cancelFilling() }
            let result=await operation.result
            gate.release()
            #expect(cancelled(result) && gate.observedCancellation && !gate.timedOut)
            #expect(!session.isFilling && saves==0 && session.project==project)
            #expect(try await store.load().project==project)
            if !close { await session.close() }
            #expect(session.isClosed)
            try FileManager.default.removeItem(at:directory)
        }
    }

    @Test func ordinaryEditDuringComputationFencesTheCompletedOldRevision() async throws {
        let directory=try root();defer{try? FileManager.default.removeItem(at:directory)}
        let project=try original(),store=try await EDAProjectStore.create(root:directory,project:project)
        let session=try await EDWorkbenchSession(store:store),gate=CopperFillGate()
        var saves=0;session.onSaved={_ in saves+=1}
        let operation=Task { @MainActor in try await session.refillCopper(boardID:project.boards[0].id,cancelled:{gate.check()}) }
        #expect(await awaitEntry(gate))
        do { try await session.apply([.rename("Newer saved edit")],expectedRevision:0) }
        catch { gate.release();_ = await operation.result;throw error }
        gate.release()
        let result=await operation.result
        guard case .failure(let error)=result else{Issue.record("A stale refill must not commit");return}
        if case EDAError.staleRevision(expected:0,actual:1)=error {} else{Issue.record("Expected the actual revision fence")}
        #expect(!gate.timedOut && saves==1 && session.revision==1 && session.project.title=="Newer saved edit")
        #expect(session.project.boards[0].zones[0].fillRevision==nil && !session.isDirty)
        #expect(try await store.load().project==session.project)
        await session.close()
    }

    @Test func originalCASConflictPreservesTheUnpublishedLocalFillProposal() async throws {
        let directory=try root();defer{try? FileManager.default.removeItem(at:directory)}
        let project=try original(),store=try await EDAProjectStore.create(root:directory,project:project)
        let source=try await store.load(),session=try await EDWorkbenchSession(store:store),gate=CopperFillGate()
        var saves=0;session.onSaved={_ in saves+=1}
        let operation=Task { @MainActor in try await session.refillCopper(boardID:project.boards[0].id,cancelled:{gate.check()}) }
        #expect(await awaitEntry(gate))
        var external=project;external.revision=1;external.title="External writer"
        do {_ = try await store.save(external,expectedRevision:0,expectedDigest:source.digest)}
        catch {gate.release();_ = await operation.result;throw error}
        gate.release()
        let result=await operation.result
        #expect(!gate.timedOut)
        if case .success=result{Issue.record("A competing original must win its real CAS")}
        #expect(saves==0 && session.conflictWithOriginal && session.isDirty)
        #expect(session.project.boards[0].zones[0].fillState == .filled)
        #expect(try await store.load().project==external)
        try await session.refresh(discardChanges:true)
        #expect(session.project==external && !session.conflictWithOriginal && !session.isDirty)
        await session.close()
    }
}
