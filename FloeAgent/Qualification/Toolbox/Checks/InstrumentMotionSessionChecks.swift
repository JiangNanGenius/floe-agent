import Foundation
import FloeToolboxUtilities

/// Standalone sensor-free checks, compiled together with InstrumentMotionService.swift.
@main
enum InstrumentMotionSessionChecks {
    @MainActor private static var checks = 0

    @MainActor static func main() {
        supersededSessionsKeepTheirOwnReadings()
        resumedHistoryKeepsOneTimeOriginUntilReset()
        staleLeasesCannotDeliverOrStopANewerLease()
        levelReferencesAndCompassReadingsStayLocal()
        historyRemainsBounded()
        print("Instrument motion session checks passed: \(checks)")
    }

    @MainActor private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        checks += 1
    }

    private static func sample(_ timestamp: TimeInterval, heading: Double? = nil,
                               attitude: InstrumentQuaternion = InstrumentQuaternion(0, 0, 0, 1)) -> InstrumentMotionSample {
        InstrumentMotionSample(
            timestamp: timestamp, receivedAt: Date(timeIntervalSince1970: timestamp), attitude: attitude,
            up: InstrumentMath.upVector(attitude: attitude)!, gravity: InstrumentVec3(0, 0, -9.80665),
            userAcceleration: InstrumentVec3(timestamp, 2, 3), rotationRate: InstrumentVec3(4, 5, 6),
            heading: heading)
    }

    @MainActor private static func supersededSessionsKeepTheirOwnReadings() {
        let first = InstrumentMotionSession()
        let second = InstrumentMotionSession()
        let firstLease = InstrumentMotionLease()
        let secondLease = InstrumentMotionLease()
        first.beginSampling(for: firstLease)
        first.record(sample(100), kind: .motion, for: firstLease)
        first.record(sample(101), kind: .motion, for: firstLease)
        let frozenSample = first.latest
        let frozenHistory = first.motionHistory.values

        first.endSampling(for: firstLease)
        second.beginSampling(for: secondLease)
        second.record(sample(102), kind: .motion, for: secondLease)
        second.record(sample(103), kind: .motion, for: secondLease)
        first.record(sample(104), kind: .motion, for: firstLease)
        first.record(sample(104), kind: .motion, for: secondLease)

        expect(first.latest == frozenSample, "A paused or superseded workbench must keep its own sample")
        expect(first.motionHistory.values == frozenHistory, "A superseded workbench must keep its own curve")
        expect(second.latest?.timestamp == 103, "The active workbench must receive its own samples")
        expect(second.motionHistory.values.map(\.timestamp) == [0, 1], "A different workbench starts its own time origin")
        first.resetHistory()
        expect(first.motionHistory.isEmpty, "Reset clears the workbench's own history")
        expect(second.motionHistory.count == 2, "Reset in a paused workbench must preserve the active workbench's history")
        expect(second.latest?.timestamp == 103, "Reset in another workbench must preserve the active reading")
    }

    @MainActor private static func resumedHistoryKeepsOneTimeOriginUntilReset() {
        let session = InstrumentMotionSession()
        let firstLease = InstrumentMotionLease()
        let resumedLease = InstrumentMotionLease()
        session.beginSampling(for: firstLease)
        session.record(sample(10), kind: .motion, for: firstLease)
        session.record(sample(10.5), kind: .motion, for: firstLease)
        session.endSampling(for: firstLease)
        session.beginSampling(for: resumedLease)
        session.record(sample(17), kind: .motion, for: resumedLease)
        expect(session.motionHistory.values.map(\.timestamp) == [0, 0.5, 7], "Resume must keep CSV time monotonic")

        session.resetHistory()
        expect(session.latest?.timestamp == 17, "Reset keeps the current numerical readout")
        session.record(sample(18), kind: .motion, for: resumedLease)
        session.record(sample(18.25), kind: .motion, for: resumedLease)
        expect(session.motionHistory.values.map(\.timestamp) == [0, 0.25], "The first frame after Reset defines a new zero")
        session.record(sample(18.1), kind: .motion, for: resumedLease)
        session.record(sample(18.25), kind: .motion, for: resumedLease)
        session.record(sample(.infinity), kind: .motion, for: resumedLease)
        session.record(sample(.nan), kind: .motion, for: resumedLease)
        expect(session.motionHistory.values.map(\.timestamp) == [0, 0.25], "Duplicate, reordered and invalid times must not regress the curve")
        expect(session.latest?.timestamp == 18.25, "Invalid or reordered deliveries must not replace the reading")
    }

    @MainActor private static func staleLeasesCannotDeliverOrStopANewerLease() {
        let session = InstrumentMotionSession()
        let oldLease = InstrumentMotionLease()
        let newLease = InstrumentMotionLease()
        session.beginSampling(for: oldLease)
        session.record(sample(20), kind: .motion, for: oldLease)
        session.fail("old error", for: oldLease)
        expect(session.streamError == "old error", "An active stream reports its own error")
        session.endSampling(for: oldLease)
        session.beginSampling(for: newLease)
        expect(session.streamError == nil, "Resume clears only this session's old error")
        session.endSampling(for: oldLease)
        session.fail("late error", for: oldLease)
        session.record(sample(21), kind: .motion, for: oldLease)
        expect(session.latest?.timestamp == 20, "An old lease must not deliver into a resumed session")
        expect(session.streamError == nil, "An old lease must not fail a resumed session")
        session.record(sample(22), kind: .motion, for: newLease)
        expect(session.latest?.timestamp == 22, "Releasing an old lease must not stop its successor")
    }

    @MainActor private static func levelReferencesAndCompassReadingsStayLocal() {
        let level = InstrumentMotionSession()
        let compass = InstrumentMotionSession()
        let levelLease = InstrumentMotionLease()
        let compassLease = InstrumentMotionLease()
        let tilted = InstrumentQuaternion.rotation(axis: InstrumentVec3(1, 0, 0), angleRadians: 0.3)!
        level.beginSampling(for: levelLease)
        level.record(sample(30, attitude: tilted), kind: .level, for: levelLease)
        level.endSampling(for: levelLease)
        compass.beginSampling(for: compassLease)
        compass.record(sample(31, heading: 123), kind: .compass, for: compassLease)
        level.setLevelReference(level.latest!.attitude)
        let zeroed = InstrumentMath.levelAngles(up: level.levelUpVector(for: level.latest!))!
        expect(abs(zeroed.tilt) < 1e-6, "Zero after takeover must use the level's frozen pose")
        expect(compass.levelReference == nil, "Zero must not affect another session")
        expect(level.latest?.attitude == tilted, "Lock reads the level's own frozen sample")
        expect(compass.latest?.heading == 123, "Compass heading must stay available in its own session")
        compass.endSampling(for: compassLease)
        level.beginSampling(for: InstrumentMotionLease())
        expect(compass.latest?.heading == 123, "Another kind acquiring the hardware must not erase frozen heading")
        expect(compass.motionHistory.isEmpty, "Compass sampling must not append motion history")
        level.clearLevelReference()
        expect(level.levelReference == nil, "Clear removes this session's level reference")
    }

    @MainActor private static func historyRemainsBounded() {
        let session = InstrumentMotionSession()
        let lease = InstrumentMotionLease()
        session.beginSampling(for: lease)
        for index in 0..<500 { session.record(sample(Double(index)), kind: .motion, for: lease) }
        expect(session.motionHistory.count == 480, "Motion history must remain bounded")
        expect(session.motionHistory.droppedCount == 20, "Retention must count dropped samples")
        expect(session.motionHistory.values.first?.timestamp == 20, "Dropping old points must preserve elapsed time")
        expect(session.motionHistory.values.last?.timestamp == 499, "The latest elapsed time must survive retention")
        session.resetHistory()
        expect(session.motionHistory.droppedCount == 0, "Reset clears the retention count")
        session.record(sample(500), kind: .motion, for: lease)
        expect(session.motionHistory.values.map(\.timestamp) == [0], "Reset after retention must establish a new zero")
    }
}
