import Foundation
import Testing
@testable import FloeToolboxUtilities

private let accuracy = 1e-6

// Physical-tilt note: CMDeviceMotion attitude maps world→device coordinates, so a
// device physically rotated by angle γ about an axis reports the inverse rotation.
// Tests build attitudes with `rotation(axis:angleRadians: -γ)` accordingly.

@Test func gravityIsLevelWhenFlatAndRejectsInvalidInput() {
    let flat = InstrumentMath.levelAngles(gravity: InstrumentVec3(0, 0, -9.81))
    #expect(flat != nil)
    #expect(abs(flat!.x) < accuracy && abs(flat!.y) < accuracy && abs(flat!.tilt) < accuracy)
    #expect(InstrumentMath.levelAngles(gravity: InstrumentVec3(.nan, 0, -1)) == nil)
    #expect(InstrumentMath.levelAngles(gravity: InstrumentVec3(0, .infinity, -1)) == nil)
    #expect(InstrumentMath.levelAngles(gravity: InstrumentVec3(0, 0, 0)) == nil)
}

@Test func gravitySignsRightRaisedAndTopRaised() {
    // Right edge raised by 30 degrees: gravity tips toward -x in device coordinates.
    let right = InstrumentMath.levelAngles(gravity: InstrumentVec3(-0.5, 0, -(3.0).squareRoot() / 2))
    #expect(right != nil && abs(right!.x - 30) < 1e-4 && abs(right!.y) < 1e-4 && abs(right!.tilt - 30) < 1e-4)
    // Top edge raised by 20 degrees: gravity tips toward -y.
    let top = InstrumentMath.levelAngles(gravity: InstrumentVec3(0, -sin(.pi / 9), -cos(.pi / 9)))
    #expect(top != nil && abs(top!.x) < 1e-4 && abs(top!.y - 20) < 1e-4)
    // Face down still reports honest angles rather than rejecting the sample.
    let down = InstrumentMath.levelAngles(gravity: InstrumentVec3(0, 0, 1))
    #expect(down != nil && abs(down!.tilt - 180) < 1e-4)
}

@Test func upAnglesMatchGravityAnglesForTheSamePose() {
    // Device physically rotated -15 degrees about the y axis (right edge raised).
    // The attitude world→device map is the inverse: +15 degrees about y.
    let attitude = InstrumentQuaternion.rotation(axis: InstrumentVec3(0, 1, 0), angleRadians: .pi / 12)
    let up = InstrumentMath.upVector(attitude: attitude!)
    let fromUp = InstrumentMath.levelAngles(up: up!)
    let fromGravity = InstrumentMath.levelAngles(gravity: InstrumentVec3(-sin(.pi / 12), 0, -cos(.pi / 12)))
    #expect(fromUp != nil && fromGravity != nil)
    #expect(abs(fromUp!.x - fromGravity!.x) < 1e-4 && abs(fromUp!.y - fromGravity!.y) < 1e-4)
    #expect(abs(fromUp!.tilt - fromGravity!.tilt) < 1e-4)
    #expect(InstrumentMath.levelAngles(up: InstrumentVec3(.nan, 0, 1)) == nil)
}

@Test func relativeLevelReadsZeroAtTheReferencePose() {
    let reference = InstrumentQuaternion.rotation(axis: InstrumentVec3(1, 0, 0), angleRadians: 0.3)!
    let same = InstrumentMath.relativeUp(current: reference, reference: reference)!
    let angles = InstrumentMath.levelAngles(up: same)!
    #expect(abs(angles.x) < accuracy && abs(angles.y) < accuracy && abs(angles.tilt) < accuracy)
}

@Test func relativeLevelTracksTiltAfterZeroing() {
    let reference = InstrumentQuaternion(0, 0, 0, 1)
    // Device physically rotated 25 degrees about x after zeroing: attitude is the inverse.
    let current = InstrumentQuaternion.rotation(axis: InstrumentVec3(1, 0, 0), angleRadians: -.pi * 25 / 180)!
    let relative = InstrumentMath.relativeUp(current: current, reference: reference)!
    let angles = InstrumentMath.levelAngles(up: relative)!
    #expect(abs(angles.y - 25) < 1e-4)
    #expect(abs(angles.x) < 1e-4)
    // A reference made from the current pose is always level.
    let rezeroed = InstrumentMath.relativeUp(current: current, reference: current)!
    let zeroedAngles = InstrumentMath.levelAngles(up: rezeroed)!
    #expect(abs(zeroedAngles.tilt) < accuracy)
}

@Test func bubbleDriftsTowardTheRaisedEdges() {
    // Right raised: +x. Top raised: +y.
    let right = InstrumentMath.bubblePosition(up: InstrumentVec3(sin(.pi / 6), 0, cos(.pi / 6)))!
    #expect(right.x > 0.4 && abs(right.y) < accuracy)
    let top = InstrumentMath.bubblePosition(up: InstrumentVec3(0, sin(.pi / 6), cos(.pi / 6)))!
    #expect(top.y > 0.4 && abs(top.x) < accuracy)
    let centered = InstrumentMath.bubblePosition(up: InstrumentVec3(0, 0, 1))!
    #expect(abs(centered.x) < accuracy && abs(centered.y) < accuracy)
    #expect(InstrumentMath.bubblePosition(up: InstrumentVec3(0, 0, 0)) == nil)
}

@Test func quaternionVectorRotationAndComposition() {
    let qx90 = InstrumentQuaternion.rotation(axis: InstrumentVec3(1, 0, 0), angleRadians: .pi / 2)!
    // World z rotated into the device frame tips toward device -y for a +90 degree x attitude.
    let rotated = qx90.rotated(InstrumentVec3(0, 0, 1))!
    #expect(abs(rotated.x) < accuracy && abs(rotated.y + 1) < 1e-9 && abs(rotated.z) < 1e-9)
    let qy90 = InstrumentQuaternion.rotation(axis: InstrumentVec3(0, 1, 0), angleRadians: .pi / 2)!
    let composed = qy90.multiplied(by: qx90)!
    let viaComposition = composed.rotated(InstrumentVec3(0, 0, 1))!
    let stepwise = qy90.rotated(qx90.rotated(InstrumentVec3(0, 0, 1))!)!
    #expect(abs(viaComposition.x - stepwise.x) < 1e-9)
    #expect(abs(viaComposition.y - stepwise.y) < 1e-9)
    #expect(abs(viaComposition.z - stepwise.z) < 1e-9)
    #expect(InstrumentQuaternion(.nan, 0, 0, 1).rotated(InstrumentVec3(0, 0, 1)) == nil)
    #expect(InstrumentQuaternion.rotation(axis: InstrumentVec3(0, 0, 0), angleRadians: 1) == nil)
}

@Test func headingReadsMagneticNorthReferenceFrame() {
    // Attitude for a device whose top points north: inverse of a physical -90 degree
    // z rotation, expressed directly as a +90 degree world→device z rotation.
    let north = InstrumentQuaternion.rotation(axis: InstrumentVec3(0, 0, 1), angleRadians: .pi / 2)!
    let northHeading = InstrumentMath.headingDegrees(attitude: north)
    #expect(northHeading != nil && abs(northHeading! - 0) < 1e-9)
    // Aligned device (top points east) reads 90.
    let identity = InstrumentQuaternion(0, 0, 0, 1)
    #expect(abs(InstrumentMath.headingDegrees(attitude: identity)! - 90) < 1e-9)
    // Top points south: attitude -90 about z.
    let south = InstrumentQuaternion.rotation(axis: InstrumentVec3(0, 0, 1), angleRadians: -.pi / 2)!
    #expect(abs(InstrumentMath.headingDegrees(attitude: south)! - 180) < 1e-9)
    let matrix = InstrumentRotationMatrix(m11: .nan, m12: 0, m13: 0, m21: 0, m22: 1, m23: 0, m31: 0, m32: 0, m33: 1)
    #expect(InstrumentMath.headingDegrees(matrix: matrix) == nil)
}

@Test func headingNormalizationAndCardinalWinds() {
    #expect(abs(InstrumentMath.normalizedDegrees(-90) - 270) < accuracy)
    #expect(abs(InstrumentMath.normalizedDegrees(725) - 5) < accuracy)
    #expect(InstrumentCardinal.allCases.count == 8)
    #expect(InstrumentMath.cardinal(headingDegrees: 0) == .north)
    #expect(InstrumentMath.cardinal(headingDegrees: 22.4) == .north)
    #expect(InstrumentMath.cardinal(headingDegrees: 22.6) == .northEast)
    #expect(InstrumentMath.cardinal(headingDegrees: 45) == .northEast)
    #expect(InstrumentMath.cardinal(headingDegrees: 90) == .east)
    #expect(InstrumentMath.cardinal(headingDegrees: 359.9) == .north)
}

@Test func eulerAnglesTrackAttitudeRotation() {
    let roll30 = InstrumentQuaternion.rotation(axis: InstrumentVec3(1, 0, 0), angleRadians: .pi / 6)!
    let euler = InstrumentMath.eulerDegrees(attitude: roll30)!
    #expect(abs(euler.roll - 30) < 1e-6 && abs(euler.pitch) < 1e-6 && abs(euler.yaw) < 1e-6)
    let yaw45 = InstrumentQuaternion.rotation(axis: InstrumentVec3(0, 0, 1), angleRadians: .pi / 4)!
    let yawEuler = InstrumentMath.eulerDegrees(attitude: yaw45)!
    #expect(abs(yawEuler.yaw - 45) < 1e-6)
    #expect(InstrumentMath.eulerDegrees(attitude: InstrumentQuaternion(0, 0, .nan, 1)) == nil)
}

@Test func sampleBufferDropsOldestAndResets() {
    var buffer = InstrumentSampleBuffer<Int>(capacity: 3)
    for value in 1...5 { buffer.append(value) }
    #expect(buffer.count == 3)
    #expect(buffer.values == [3, 4, 5])
    #expect(buffer.droppedCount == 2)
    buffer.reset()
    #expect(buffer.isEmpty && buffer.droppedCount == 0)
    var single = InstrumentSampleBuffer<String>(capacity: 1)
    single.append("a"); single.append("b")
    #expect(single.values == ["b"] && single.droppedCount == 1)
}

@Test func standardGravityConversionScalesCoreMotionUnits() {
    // CoreMotion reports gravity/userAcceleration in g; the service converts once to m/s².
    let scale = InstrumentMath.standardGravityMps2
    #expect(abs(scale - 9.80665) < accuracy)
    #expect(abs(1.0 * scale - 9.80665) < accuracy)
    #expect(abs(0.5 * scale - 4.903325) < accuracy)
    let flatGravity = InstrumentVec3(0, 0, -1 * scale)
    #expect(abs(flatGravity.magnitude - scale) < 1e-9)
}

@Test func vectorNormalizationRejectsInvalidInput() {
    #expect(InstrumentVec3(3, 0, 0).normalized() == InstrumentVec3(1, 0, 0))
    #expect(InstrumentVec3(0, 0, 0).normalized() == nil)
    #expect(InstrumentVec3(1e-12, 0, 0).normalized() == nil)
    #expect(InstrumentVec3(.infinity, 0, 0).normalized() == nil)
}

@Test func levelModeUsesPhysicalGravityWithHysteresis() {
    func gravity(degreesFromVertical: Double) -> InstrumentVec3 {
        let angle = degreesFromVertical * .pi / 180
        return InstrumentVec3(0, -cos(angle) * 9.80665, -sin(angle) * 9.80665)
    }
    var mode = InstrumentLevelDisplayMode.dualAxis
    mode = InstrumentMath.levelDisplayMode(gravity: gravity(degreesFromVertical: 16), previous: mode)
    #expect(mode == .dualAxis)
    mode = InstrumentMath.levelDisplayMode(gravity: gravity(degreesFromVertical: 14), previous: mode)
    #expect(mode == .bar)
    for angle in [16.0, 14, 21, 16] {
        mode = InstrumentMath.levelDisplayMode(gravity: gravity(degreesFromVertical: angle), previous: mode)
        #expect(mode == .bar)
    }
    mode = InstrumentMath.levelDisplayMode(gravity: gravity(degreesFromVertical: 23), previous: mode)
    #expect(mode == .dualAxis)
    for angle in [21.0, 16] {
        mode = InstrumentMath.levelDisplayMode(gravity: gravity(degreesFromVertical: angle), previous: mode)
        #expect(mode == .dualAxis)
    }
    for flat in [InstrumentVec3(0, 0, -9.80665), InstrumentVec3(0, 0, 9.80665)] {
        #expect(InstrumentMath.levelDisplayMode(gravity: flat, previous: .bar) == .dualAxis)
    }
    // iPad portrait and either iPhone landscape edge all enter the same mode.
    for upright in [InstrumentVec3(0, -1, 0), InstrumentVec3(0, 1, 0),
                    InstrumentVec3(1, 0, 0), InstrumentVec3(-1, 0, 0)] {
        #expect(InstrumentMath.levelDisplayMode(gravity: upright, previous: .dualAxis) == .bar)
    }
}

@Test func interfaceOrientationMapsBubbleTowardTheRaisedScreenEdge() throws {
    let lean = 12.0 * .pi / 180
    let s = sin(lean), c = cos(lean)
    // Explicit device-frame fixtures. Interface landscape-left puts the bottom
    // on the left: device +Y is screen-right, and device -X is screen-top.
    let poses: [(InstrumentScreenOrientation, InstrumentVec3, InstrumentVec3)] = [
        (.portrait, InstrumentVec3(s, 0, c), InstrumentVec3(0, s, c)),
        (.portraitUpsideDown, InstrumentVec3(-s, 0, c), InstrumentVec3(0, -s, c)),
        (.landscapeLeft, InstrumentVec3(0, s, c), InstrumentVec3(-s, 0, c)),
        (.landscapeRight, InstrumentVec3(0, -s, c), InstrumentVec3(s, 0, c))
    ]
    for (orientation, rightRaised, topRaised) in poses {
        let right = InstrumentMath.screenVector(rightRaised, orientation: orientation)
        let rightBubble = try #require(InstrumentMath.bubblePosition(up: right))
        let rightAngles = try #require(InstrumentMath.levelAngles(up: right))
        #expect(abs(rightBubble.x - s) < accuracy && abs(rightBubble.y) < accuracy)
        #expect(abs(rightAngles.x - 12) < accuracy && abs(rightAngles.y) < accuracy)
        let top = InstrumentMath.screenVector(topRaised, orientation: orientation)
        let topBubble = try #require(InstrumentMath.bubblePosition(up: top))
        let topAngles = try #require(InstrumentMath.levelAngles(up: top))
        #expect(abs(topBubble.y - s) < accuracy && abs(topBubble.x) < accuracy)
        #expect(abs(topAngles.y - 12) < accuracy && abs(topAngles.x) < accuracy)
    }
}

@Test func uprightBarCentersAndTracksBothSignsInEveryInterfaceOrientation() throws {
    let lean = 7.0 * .pi / 180
    let s = sin(lean), c = cos(lean)
    let poses: [(InstrumentScreenOrientation, InstrumentVec3, InstrumentVec3, InstrumentVec3)] = [
        (.portrait, InstrumentVec3(0, -1, 0), InstrumentVec3(-s, -c, 0), InstrumentVec3(s, -c, 0)),
        (.portraitUpsideDown, InstrumentVec3(0, 1, 0), InstrumentVec3(s, c, 0), InstrumentVec3(-s, c, 0)),
        (.landscapeLeft, InstrumentVec3(1, 0, 0), InstrumentVec3(c, -s, 0), InstrumentVec3(c, s, 0)),
        (.landscapeRight, InstrumentVec3(-1, 0, 0), InstrumentVec3(-c, s, 0), InstrumentVec3(-c, -s, 0))
    ]
    for (orientation, centered, rightRaised, leftRaised) in poses {
        let zero = try #require(InstrumentMath.barLevelAngle(gravity: centered, orientation: orientation))
        let positive = try #require(InstrumentMath.barLevelAngle(gravity: rightRaised, orientation: orientation))
        let negative = try #require(InstrumentMath.barLevelAngle(gravity: leftRaised, orientation: orientation))
        #expect(abs(zero) < accuracy)
        #expect(abs(positive - 7) < accuracy)
        #expect(abs(negative + 7) < accuracy)
        #expect(InstrumentMath.barBubblePosition(angleDegrees: positive)! > 0)
        #expect(InstrumentMath.barBubblePosition(angleDegrees: negative)! < 0)
    }
    // A locked interface may be upside down physically. Raising its right edge
    // must still move the bubble right, rather than folding the sign at 180°.
    let upsideDown = try #require(InstrumentMath.barLevelAngle(gravity: InstrumentVec3(-s, c, 0), orientation: .portrait))
    #expect(abs(upsideDown - 7) < accuracy)
}

@Test func uprightBarZeroPreservesPhysicalModeAndMeasuresRollAfterCalibration() throws {
    let upright = try #require(InstrumentQuaternion.rotation(axis: InstrumentVec3(1, 0, 0), angleRadians: -.pi / 2))
    let referenceRoll = try #require(InstrumentQuaternion.rotation(axis: InstrumentVec3(0, 0, 1), angleRadians: -5 * .pi / 180))
    let currentRoll = try #require(InstrumentQuaternion.rotation(axis: InstrumentVec3(0, 0, 1), angleRadians: -12 * .pi / 180))
    let reference = try #require(referenceRoll.multiplied(by: upright))
    let current = try #require(currentRoll.multiplied(by: upright))
    let referenceUp = try #require(InstrumentMath.upVector(attitude: reference))
    let currentUp = try #require(InstrumentMath.upVector(attitude: current))
    let gravity = InstrumentVec3(-currentUp.x * 9.80665, -currentUp.y * 9.80665, -currentUp.z * 9.80665)
    let calibrated = try #require(InstrumentMath.barLevelAngle(gravity: gravity, referenceUp: referenceUp, orientation: .portrait))
    #expect(abs(calibrated - 7) < accuracy)
    let rezeroed = try #require(InstrumentMath.barLevelAngle(gravity: gravity, referenceUp: currentUp, orientation: .portrait))
    #expect(abs(rezeroed) < accuracy)
    let zeroedUp = try #require(InstrumentMath.relativeUp(current: current, reference: current))
    #expect(abs(zeroedUp.z - 1) < accuracy)
    #expect(InstrumentMath.levelDisplayMode(gravity: gravity, previous: .dualAxis) == .bar)
    // Clearing the reference returns to the physical horizontal edge's 12°.
    let cleared = try #require(InstrumentMath.barLevelAngle(gravity: gravity, orientation: .portrait))
    #expect(abs(cleared - 12) < accuracy)
}

@Test func uprightBarCalibrationUsesTheCurrentScreenEdge() throws {
    let reference = InstrumentVec3(-cos(5 * .pi / 180), sin(5 * .pi / 180), 0)
    let current = InstrumentVec3(-cos(12 * .pi / 180), sin(12 * .pi / 180), 0)
    let gravity = InstrumentVec3(-current.x, -current.y, 0)
    let left = try #require(InstrumentMath.barLevelAngle(gravity: gravity, referenceUp: reference, orientation: .landscapeLeft))
    let right = try #require(InstrumentMath.barLevelAngle(gravity: gravity, referenceUp: reference, orientation: .landscapeRight))
    #expect(abs(left - 7) < accuracy)
    #expect(abs(right + 7) < accuracy)
}

@Test func uprightBarBoundsTravelAndRejectsInvalidReadings() {
    #expect(InstrumentMath.barBubblePosition(angleDegrees: 0) == 0)
    #expect(InstrumentMath.barBubblePosition(angleDegrees: 5) == 0.5)
    #expect(InstrumentMath.barBubblePosition(angleDegrees: -5) == -0.5)
    #expect(InstrumentMath.barBubblePosition(angleDegrees: 90) == 1)
    #expect(InstrumentMath.barBubblePosition(angleDegrees: -180) == -1)
    #expect(InstrumentMath.barBubblePosition(angleDegrees: .nan) == nil)
    #expect(InstrumentMath.barBubblePosition(angleDegrees: .infinity) == nil)
    for invalid in [InstrumentVec3(0, 0, 0), InstrumentVec3(.nan, -1, 0),
                    InstrumentVec3(0, .infinity, 0), InstrumentVec3(.greatestFiniteMagnitude, 0, 0)] {
        #expect(InstrumentMath.barLevelAngle(gravity: invalid, orientation: .portrait) == nil)
        #expect(InstrumentMath.levelDisplayMode(gravity: invalid, previous: .bar) == .bar)
        #expect(InstrumentMath.levelDisplayMode(gravity: invalid, previous: .dualAxis) == .dualAxis)
    }
    #expect(InstrumentMath.barLevelAngle(gravity: InstrumentVec3(0, -1, 0), referenceUp: InstrumentVec3(0, 0, 0), orientation: .portrait) == nil)
}
