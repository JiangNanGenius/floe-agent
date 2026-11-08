// SPDX-License-Identifier: MPL-2.0
import Foundation
import Darwin
import Testing
import FloeElectronicsCore
@testable import FloeElectronicsUI

private final class CommitCancelFlag: @unchecked Sendable {
    private let lock=NSLock()
    private var value=false
    func cancel(){lock.lock();value=true;lock.unlock()}
    func read()->Bool{lock.lock();defer{lock.unlock()};return value}
}
private final class RealOriginalLock {
    private var descriptor:Int32
    init(_ root:URL) throws {
        descriptor=Darwin.open(root.appendingPathComponent(".floe-eda.lock").path,O_RDWR|O_NOFOLLOW)
        guard descriptor>=0 else{throw EDAError.invalid("test original lock open")}
        guard flock(descriptor,LOCK_EX|LOCK_NB)==0 else{Darwin.close(descriptor);descriptor = -1;throw EDAError.invalid("test original lock acquisition")}
    }
    func release(){if descriptor>=0{flock(descriptor,LOCK_UN);Darwin.close(descriptor);descriptor = -1}}
    deinit{release()}
}

@MainActor struct EDACopperCommitBoundaryTests {
    @Test func realSaveWaitRefusesStopAndLateCancelReportsTheActualCommit() async throws {
        let temp=try #require(ProcessInfo.processInfo.environment["FLOE_COMMIT_TEST_TEMP"])
        let root=URL(fileURLWithPath:temp).appendingPathComponent(UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:root)}
        var source=EDAProject(title:"Real save wait boundary")
        source.sheets[0].labels=[.init(name:"GND",position:.zero,scope:.global)]
        let net=try EDAConnectivity.derive(source).nets[0].id
        source.boards[0].zones=[.init(netID:net,outline:source.boards[0].outline,thermal:false)]
        let store=try await EDAProjectStore.create(root:root,project:source)
        let session=try await EDWorkbenchSession(store:store),cancel=CommitCancelFlag()
        let initial=session.project,lease=try RealOriginalLock(root)
        defer{lease.release()}
        var savedCallbacks=0;session.onSaved={_ in savedCallbacks+=1}
        let operation=Task{@MainActor in try await session.refillCopper(boardID:initial.boards[0].id,cancelled:{cancel.read()})}
        let deadline=Date().addingTimeInterval(2)
        while !(session.busy && session.isFilling) && Date()<deadline{await Task.yield()}
        let waiting=session.busy && session.isFilling
        #expect(waiting)
        #expect(session.isCommittingCopperFill && !session.canCancelFilling)
        // An actual POSIX lock owns the same .floe-eda.lock used by save.
        // Give its nonblocking-lock loop one turn while disk stays unchanged.
        try? await Task.sleep(for:.milliseconds(25))
        let diskBefore=try JSONDecoder().decode(EDAProject.self,from:Data(contentsOf:root.appendingPathComponent("project.json")))
        #expect(diskBefore==initial && session.project==initial && savedCallbacks==0 && !session.isDirty)
        #expect(session.cancelFilling()==false)
        cancel.cancel()
        await session.close()
        #expect(!session.isClosed && session.busy)
        #expect(!(await session.flushForClose()))
        lease.release()
        let outcome=await operation.result
        let disk=try await store.load()
        #expect(disk.project==session.project && session.revision==1 && !session.isDirty && savedCallbacks==1)
        #expect(!session.isFilling && !session.isCommittingCopperFill && !session.canCancelFilling)
        #expect(session.project.boards[0].zones[0].fillState == .filled)
        var returnedSuccess=false
        switch outcome {
        case .success(let report):returnedSuccess=true;#expect(report.resultRevision==1)
        case .failure(let error):Issue.record("A real saved commit must not be reported as cancelled: \(error)")
        }
        #expect(session.canUndo)
        try await session.undo(expectedRevision:1)
        #expect(session.project.boards[0].zones[0].fillRevision==nil && !session.isDirty)
        #expect(try await store.load().project==session.project)
        #expect(try await store.history().count==2)
        await session.close();#expect(session.isClosed)
        if let path=ProcessInfo.processInfo.environment["FLOE_COMMIT_EVIDENCE_ROOT"]{
            let record:[String:Any]=["heldActualStoreLock":true,"saveWaitObserved":waiting,"diskUnchangedWhileLocked":diskBefore==initial,
                "returnedSuccess":returnedSuccess,"afterSaveRevision":disk.project.revision,"afterUndoRevision":session.revision,
                "savedCallbacksIncludingUndo":savedCallbacks,"lateExternalCancelRequested":cancel.read(),"closedOnlyAfterSaveAndUndo":session.isClosed]
            try JSONSerialization.data(withJSONObject:record,options:[.sortedKeys,.prettyPrinted]).write(to:URL(fileURLWithPath:path).appendingPathComponent("real-save-wait.json"))
        }
    }
}
