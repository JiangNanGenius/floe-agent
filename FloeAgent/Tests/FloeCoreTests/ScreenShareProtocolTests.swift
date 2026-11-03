// Synthetic protocol bytes only. These tests do not claim ReplayKit capture.
import XCTest
import Foundation
import FloeCore

final class ScreenShareProtocolTests: XCTestCase {
    func testObservingFramesCannotGrantConsentAndNewSessionCancelsTicket() throws {
        let now=Date(),provider=UUID(),model=UUID()
        var gate=ScreenShareAnalysisGate()
        let first=ScreenShareSessionState(sessionID:UUID(),isActive:true,updatedAt:now,phase:.active,frameID:UUID(),frameCapturedAt:now)
        gate.observe(sessionID:first.sessionID)
        XCTAssertNil(gate.ticket)
        let ticket=try XCTUnwrap(gate.begin(state:first,providerID:provider,modelID:model,now:now))
        XCTAssertTrue(gate.accepts(ticket,state:first,providerID:provider,modelID:model,now:now))
        gate.observe(sessionID:UUID())
        XCTAssertNil(gate.ticket)
        XCTAssertFalse(gate.accepts(ticket,state:first,providerID:provider,modelID:model,now:now))
    }
    func testCancelledOldResultAndChangedDestinationCannotBeAccepted() throws {
        let now=Date(),provider=UUID(),model=UUID()
        var gate=ScreenShareAnalysisGate()
        let state=ScreenShareSessionState(sessionID:UUID(),isActive:true,updatedAt:now,frameID:UUID(),frameCapturedAt:now)
        gate.observe(sessionID:state.sessionID)
        let first=try XCTUnwrap(gate.begin(state:state,providerID:provider,modelID:model,now:now))
        gate.cancel()
        let second=try XCTUnwrap(gate.begin(state:state,providerID:provider,modelID:model,now:now))
        XCTAssertFalse(gate.accepts(first,state:state,providerID:provider,modelID:model,now:now))
        XCTAssertFalse(gate.accepts(second,state:state,providerID:UUID(),modelID:model,now:now))
    }
    func testPausedHeartbeatDoesNotPretendThereIsANewFrame() {
        let now=Date(),session=UUID()
        var state=ScreenShareSessionState(sessionID:session,isActive:true,updatedAt:now,phase:.paused,frameID:UUID(),frameCapturedAt:now.addingTimeInterval(-20))
        XCTAssertTrue(state.hasFreshHeartbeat(at:now))
        XCTAssertFalse(state.isFresh(at:now))
        state.phase = .active
        XCTAssertFalse(state.isFresh(at:now),"Heartbeat must not renew frame capture time")
    }
    func testStopCommandRejectsOtherSessionExpiryAndFutureVersion() {
        let now=Date(),state=ScreenShareSessionState(sessionID:UUID(),isActive:true,updatedAt:now)
        var command=ScreenShareStopCommand(sessionID:state.sessionID,now:now)
        XCTAssertTrue(command.matches(state,at:now))
        XCTAssertFalse(command.matches(.init(sessionID:UUID(),isActive:true,updatedAt:now),at:now))
        XCTAssertFalse(command.matches(state,at:now.addingTimeInterval(16)))
        command.version += 1
        XCTAssertFalse(command.matches(state,at:now))
    }
    func testOldFinisherCannotOverwriteNewStateOrDeleteNewFrame() throws {
        let container=FileManager.default.temporaryDirectory.appendingPathComponent("ScreenProtocol-\(UUID())")
        defer{try? FileManager.default.removeItem(at:container)}
        let store=ScreenShareSharedStore(container:container),old=UUID(),new=UUID(),frame=UUID()
        try store.install(.init(sessionID:old,isActive:true))
        let command=ScreenShareStopCommand(sessionID:old)
        XCTAssertTrue(try store.requestStop(command))
        let state=ScreenShareSessionState(sessionID:new,isActive:true,phase:.active,frameID:frame,frameCapturedAt:Date())
        try store.install(state)
        try store.publishJPEG(Data([1,2,3]),state:state) // Protocol payload, NOT a fake image/capture.
        XCTAssertFalse(try store.update(.init(sessionID:old,isActive:false,phase:.stopped)))
        XCTAssertFalse(try store.requestStop(command))
        store.removeFrames(for:old)
        XCTAssertEqual(store.state()?.sessionID,new)
        XCTAssertTrue(FileManager.default.fileExists(atPath:store.frameURL(sessionID:new,frameID:frame).path))
    }
    func testFinishedAckCannotDowngradeAndRequestIDMustMatch() throws {
        let container=FileManager.default.temporaryDirectory.appendingPathComponent("ScreenAck-\(UUID())")
        defer{try? FileManager.default.removeItem(at:container)}
        let store=ScreenShareSharedStore(container:container),command=ScreenShareStopCommand(sessionID:UUID())
        try store.install(.init(sessionID:command.sessionID,isActive:true))
        XCTAssertTrue(try store.requestStop(command))
        try store.acknowledge(.init(command:command,phase:.finished))
        try store.acknowledge(.init(command:command,phase:.finishInvoked))
        let ack=try XCTUnwrap(store.acknowledgment(for:command.sessionID))
        XCTAssertEqual(ack.phase,.finished)
        XCTAssertTrue(ack.matches(command))
        XCTAssertFalse(ack.matches(.init(sessionID:command.sessionID)))
    }
}
