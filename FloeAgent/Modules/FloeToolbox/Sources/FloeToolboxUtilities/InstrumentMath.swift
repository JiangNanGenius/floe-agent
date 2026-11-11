import Foundation

/// Device-space vector shared by the Toolbox motion instruments.
public struct InstrumentVec3: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double
    public init(x: Double = 0, y: Double = 0, z: Double = 0) { self.x = x; self.y = y; self.z = z }
    public init(_ x: Double, _ y: Double, _ z: Double) { self.init(x: x, y: y, z: z) }
    public var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
    public var magnitude: Double { (x * x + y * y + z * z).squareRoot() }
    /// Unit vector; nil for non-finite or near-zero input.
    public func normalized() -> InstrumentVec3? {
        guard isFinite else { return nil }
        let length = magnitude
        guard length > 1e-9 else { return nil }
        return InstrumentVec3(x / length, y / length, z / length)
    }
}

/// Unit-quaternion attitude in scalar-last (x, y, z, w) order, matching CoreMotion.
/// The quaternion describes the world→device coordinate map reported by CMDeviceMotion.
public struct InstrumentQuaternion: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double
    public var w: Double
    public init(x: Double, y: Double, z: Double, w: Double) { self.x = x; self.y = y; self.z = z; self.w = w }
    public init(_ x: Double, _ y: Double, _ z: Double, _ w: Double) { self.init(x: x, y: y, z: z, w: w) }
    public var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite && w.isFinite }
    /// Unit quaternion; nil for non-finite or near-zero input.
    public func normalized() -> InstrumentQuaternion? {
        guard isFinite else { return nil }
        let length = (x * x + y * y + z * z + w * w).squareRoot()
        guard length > 1e-9 else { return nil }
        return InstrumentQuaternion(x / length, y / length, z / length, w / length)
    }
    /// Conjugate. For a unit quaternion this is the inverse rotation.
    public func inverted() -> InstrumentQuaternion { InstrumentQuaternion(-x, -y, -z, w) }
    /// Hamilton product (self ⊗ other). Returns nil for non-finite input.
    public func multiplied(by other: InstrumentQuaternion) -> InstrumentQuaternion? {
        guard isFinite, other.isFinite else { return nil }
        return InstrumentQuaternion(
            w * other.x + x * other.w + y * other.z - z * other.y,
            w * other.y - x * other.z + y * other.w + z * other.x,
            w * other.z + x * other.y - y * other.x + z * other.w,
            w * other.w - x * other.x - y * other.y - z * other.z)
    }
    /// Rotate a vector by this quaternion (normalized defensively). Returns nil on invalid input.
    public func rotated(_ vector: InstrumentVec3) -> InstrumentVec3? {
        guard let q = normalized(), vector.isFinite else { return nil }
        func cross(_ a: InstrumentVec3, _ b: InstrumentVec3) -> InstrumentVec3 {
            InstrumentVec3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
        }
        let u = InstrumentVec3(q.x, q.y, q.z)
        let t = cross(u, vector)
        let t2 = InstrumentVec3(t.x * 2, t.y * 2, t.z * 2)
        let c = cross(u, t2)
        return InstrumentVec3(vector.x + q.w * t2.x + c.x,
                              vector.y + q.w * t2.y + c.y,
                              vector.z + q.w * t2.z + c.z)
    }
    /// Rotation about an axis by an angle in radians; nil for invalid input.
    public static func rotation(axis: InstrumentVec3, angleRadians: Double) -> InstrumentQuaternion? {
        guard let u = axis.normalized(), angleRadians.isFinite else { return nil }
        let half = angleRadians / 2
        return InstrumentQuaternion(u.x * sin(half), u.y * sin(half), u.z * sin(half), cos(half))
    }
}

/// Row-major world→device rotation matrix.
public struct InstrumentRotationMatrix: Equatable, Sendable {
    public var m11: Double; public var m12: Double; public var m13: Double
    public var m21: Double; public var m22: Double; public var m23: Double
    public var m31: Double; public var m32: Double; public var m33: Double
    public init(m11: Double, m12: Double, m13: Double, m21: Double, m22: Double, m23: Double,
                m31: Double, m32: Double, m33: Double) {
        self.m11 = m11; self.m12 = m12; self.m13 = m13
        self.m21 = m21; self.m22 = m22; self.m23 = m23
        self.m31 = m31; self.m32 = m32; self.m33 = m33
    }
    public var isFinite: Bool {
        [m11, m12, m13, m21, m22, m23, m31, m32, m33].allSatisfy { $0.isFinite }
    }
}

/// Dual-axis tilt angles in degrees. Positive x: right edge raised; positive y: top edge raised.
public struct InstrumentLevelAngles: Equatable, Sendable {
    public var x: Double
    public var y: Double
    /// Total tilt away from a level face in degrees (0 = face flat, 180 = face down).
    public var tilt: Double
    public init(x: Double, y: Double, tilt: Double) { self.x = x; self.y = y; self.tilt = tilt }
}

/// Interface orientation, rather than UIDeviceOrientation. Landscape-left has
/// the device's bottom on the screen's left; landscape-right has it on the right.
public enum InstrumentScreenOrientation: Sendable, Equatable, CaseIterable {
    case portrait, portraitUpsideDown, landscapeLeft, landscapeRight
}

public enum InstrumentLevelDisplayMode: Sendable, Equatable {
    case dualAxis, bar
}

/// ZYX Euler angles in degrees derived from an attitude quaternion.
public struct InstrumentEulerAngles: Equatable, Sendable {
    public var pitch: Double
    public var roll: Double
    public var yaw: Double
    public init(pitch: Double, roll: Double, yaw: Double) { self.pitch = pitch; self.roll = roll; self.yaw = yaw }
}

public enum InstrumentCardinal: String, Sendable, CaseIterable, Equatable {
    case north, northEast, east, southEast, south, southWest, west, northWest
}

/// Rolling retention for instrument samples. Oldest values are dropped past capacity.
public struct InstrumentSampleBuffer<Value: Sendable>: Sendable {
    public let capacity: Int
    private var storage: [Value] = []
    public private(set) var droppedCount: Int = 0
    public init(capacity: Int) {
        precondition((1...1_000_000).contains(capacity), "capacity out of range")
        self.capacity = capacity
    }
    public var count: Int { storage.count }
    public var isEmpty: Bool { storage.isEmpty }
    /// Oldest first.
    public var values: [Value] { storage }
    public mutating func append(_ value: Value) {
        if storage.count == capacity { storage.removeFirst(); droppedCount += 1 }
        storage.append(value)
    }
    public mutating func reset() { storage.removeAll(); droppedCount = 0 }
}

public enum InstrumentMath {
    private static let degreesPerRadian = 180.0 / Double.pi
    /// Standard gravity in m/s². CoreMotion reports gravity and user acceleration in g.
    public static let standardGravityMps2 = 9.80665

    /// World-up expressed in device coordinates for an absolute attitude.
    public static func upVector(attitude: InstrumentQuaternion) -> InstrumentVec3? {
        attitude.rotated(InstrumentVec3(0, 0, 1))
    }

    /// Apparent world-up relative to a zeroed reference orientation. When the device
    /// returns to the exact zero pose this returns +Z (perfectly level) by construction.
    public static func relativeUp(current: InstrumentQuaternion, reference: InstrumentQuaternion) -> InstrumentVec3? {
        guard let relative = current.multiplied(by: reference.inverted()) else { return nil }
        return relative.rotated(InstrumentVec3(0, 0, 1))
    }

    /// Axis tilt from a world-up vector in device coordinates.
    /// x: + = right edge raised; y: + = top edge raised; both 0 on a level face.
    public static func levelAngles(up rawUp: InstrumentVec3) -> InstrumentLevelAngles? {
        guard let up = rawUp.normalized() else { return nil }
        let x = atan2(up.x, up.z) * degreesPerRadian
        let y = atan2(up.y, up.z) * degreesPerRadian
        let tilt = acos(min(max(up.z, -1), 1)) * degreesPerRadian
        return InstrumentLevelAngles(x: x, y: y, tilt: tilt)
    }

    /// Axis tilt straight from a gravity vector in device coordinates (any units).
    /// x: + = right edge raised; y: + = top edge raised; both 0 on a level face.
    public static func levelAngles(gravity rawGravity: InstrumentVec3) -> InstrumentLevelAngles? {
        guard let gravity = rawGravity.normalized() else { return nil }
        let x = atan2(-gravity.x, -gravity.z) * degreesPerRadian
        let y = atan2(-gravity.y, -gravity.z) * degreesPerRadian
        let tilt = acos(min(max(-gravity.z, -1), 1)) * degreesPerRadian
        return InstrumentLevelAngles(x: x, y: y, tilt: tilt)
    }

    /// Bubble offset in a unit square: +x drifts toward the raised right edge,
    /// +y drifts toward the raised top edge, matching a physical spirit level.
    public static func bubblePosition(up rawUp: InstrumentVec3) -> (x: Double, y: Double)? {
        guard let up = rawUp.normalized() else { return nil }
        return (min(max(up.x, -1), 1), min(max(up.y, -1), 1))
    }

    /// Maps device coordinates to screen-right, screen-top and screen-outward.
    /// UIKit interface landscape orientations are opposite to device orientations.
    public static func screenVector(_ vector: InstrumentVec3,
                                    orientation: InstrumentScreenOrientation) -> InstrumentVec3 {
        switch orientation {
        case .portrait: return vector
        case .portraitUpsideDown: return InstrumentVec3(-vector.x, -vector.y, vector.z)
        case .landscapeLeft: return InstrumentVec3(vector.y, -vector.x, vector.z)
        case .landscapeRight: return InstrumentVec3(-vector.y, vector.x, vector.z)
        }
    }

    /// The physical screen plane enters bar mode within 15° of vertical and
    /// returns to dual-axis mode beyond 22°. Never pass a zeroed attitude here:
    /// calibration must not change how the device is physically being held.
    public static func levelDisplayMode(gravity rawGravity: InstrumentVec3,
                                        previous: InstrumentLevelDisplayMode) -> InstrumentLevelDisplayMode {
        guard rawGravity.magnitude.isFinite, let gravity = rawGravity.normalized() else { return previous }
        let normalComponent = abs(gravity.z)
        switch previous {
        case .dualAxis: return normalComponent <= sin(15 / degreesPerRadian) ? .bar : .dualAxis
        case .bar: return normalComponent >= sin(22 / degreesPerRadian) ? .dualAxis : .bar
        }
    }

    /// Inclination of the screen's horizontal edge: positive raises its right
    /// end, including when the device is vertical or upside down. A saved pose
    /// subtracts that same edge's inclination, without the vertical singularity
    /// of a zeroed +Z vector. A nil reference measures against physical level.
    public static func barLevelAngle(gravity rawGravity: InstrumentVec3,
                                     referenceUp: InstrumentVec3? = nil,
                                     orientation: InstrumentScreenOrientation) -> Double? {
        guard rawGravity.magnitude.isFinite, let gravity = rawGravity.normalized() else { return nil }
        let up = screenVector(InstrumentVec3(-gravity.x, -gravity.y, -gravity.z), orientation: orientation)
        let angle = asin(min(max(up.x, -1), 1)) * degreesPerRadian
        guard let referenceUp else { return angle }
        guard referenceUp.magnitude.isFinite, let reference = referenceUp.normalized() else { return nil }
        let screenReference = screenVector(reference, orientation: orientation)
        return angle - asin(min(max(screenReference.x, -1), 1)) * degreesPerRadian
    }

    /// Magnified spirit-level travel: ±10° reaches the ends of the tube.
    public static func barBubblePosition(angleDegrees: Double) -> Double? {
        guard angleDegrees.isFinite else { return nil }
        return min(max(angleDegrees / 10, -1), 1)
    }

    /// Row-major rotation matrix for an attitude quaternion; nil on invalid input.
    public static func rotationMatrix(attitude rawQuaternion: InstrumentQuaternion) -> InstrumentRotationMatrix? {
        guard let q = rawQuaternion.normalized() else { return nil }
        let (x, y, z, w) = (q.x, q.y, q.z, q.w)
        return InstrumentRotationMatrix(
            m11: 1 - 2 * (y * y + z * z), m12: 2 * (x * y - w * z), m13: 2 * (x * z + w * y),
            m21: 2 * (x * y + w * z), m22: 1 - 2 * (x * x + z * z), m23: 2 * (y * z - w * x),
            m31: 2 * (x * z - w * y), m32: 2 * (y * z + w * x), m33: 1 - 2 * (x * x + y * y))
    }

    /// Magnetic heading in [0, 360) degrees from a rotation matrix acquired with the
    /// CoreMotion magnetic-north reference frame (xMagneticNorthZVertical).
    /// 0 = device top points to magnetic north, 90 = magnetic east. Nil on invalid input.
    public static func headingDegrees(matrix: InstrumentRotationMatrix) -> Double? {
        guard matrix.isFinite else { return nil }
        return normalizedDegrees(atan2(matrix.m22, matrix.m21) * degreesPerRadian)
    }

    /// Magnetic heading for an attitude quaternion from the magnetic-north reference frame.
    public static func headingDegrees(attitude: InstrumentQuaternion) -> Double? {
        guard let matrix = rotationMatrix(attitude: attitude) else { return nil }
        return headingDegrees(matrix: matrix)
    }

    /// Normalize degrees into [0, 360). Non-finite input becomes 0.
    public static func normalizedDegrees(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        let remainder = value.truncatingRemainder(dividingBy: 360)
        return remainder < 0 ? remainder + 360 : remainder
    }

    /// 8-wind compass direction for a heading in degrees.
    public static func cardinal(headingDegrees value: Double) -> InstrumentCardinal {
        let index = Int((normalizedDegrees(value) + 22.5).truncatingRemainder(dividingBy: 360) / 45)
        return InstrumentCardinal.allCases[index]
    }

    /// ZYX Euler angles in degrees for an attitude quaternion. These describe the
    /// world→device attitude itself, so a physical tilt of the device reads negative.
    public static func eulerDegrees(attitude rawQuaternion: InstrumentQuaternion) -> InstrumentEulerAngles? {
        guard let q = rawQuaternion.normalized() else { return nil }
        let sinPitch = 2 * (q.w * q.y - q.z * q.x)
        let pitch = asin(min(max(sinPitch, -1), 1))
        let roll = atan2(2 * (q.w * q.x + q.y * q.z), 1 - 2 * (q.x * q.x + q.y * q.y))
        let yaw = atan2(2 * (q.w * q.z + q.x * q.y), 1 - 2 * (q.y * q.y + q.z * q.z))
        return InstrumentEulerAngles(pitch: pitch * degreesPerRadian,
                                     roll: roll * degreesPerRadian,
                                     yaw: normalizedDegrees(yaw * degreesPerRadian))
    }
}
