// SPDX-License-Identifier: MPL-2.0
import Foundation

public struct NCError: Error, LocalizedError, Sendable {
    public let line: Int
    public let message: String
    public init(_ message: String, line: Int = 0) { self.line = line; self.message = message }
    public var errorDescription: String? { line > 0 ? "Line \(line): \(message)" : message }
}

public struct NCVector: Codable, Equatable, Sendable {
    public var x, y, z: Double
    public init(_ x: Double, _ y: Double, _ z: Double) { self.x = x; self.y = y; self.z = z }
    public subscript(_ axis: Int) -> Double {
        get { axis == 0 ? x : axis == 1 ? y : z }
        set { if axis == 0 { x = newValue } else if axis == 1 { y = newValue } else { z = newValue } }
    }
    public static func + (a: Self, b: Self) -> Self { .init(a.x+b.x,a.y+b.y,a.z+b.z) }
    public static func - (a: Self, b: Self) -> Self { .init(a.x-b.x,a.y-b.y,a.z-b.z) }
    public static func * (a: Self, b: Double) -> Self { .init(a.x*b,a.y*b,a.z*b) }
    public var length: Double { sqrt(x*x+y*y+z*z) }
    public var finite: Bool { x.isFinite && y.isFinite && z.isFinite }
    static func mix(_ a: Self, _ b: Self, _ t: Double) -> Self { a*(1-t)+b*t }
}

/// XYZ in physical millimetres; ABC in unwrapped degrees. Nil is unknown, never home.
public struct NCPosition: Codable, Equatable, Sendable {
    public var x, y, z, a, b, c: Double?
    public init(x: Double? = nil, y: Double? = nil, z: Double? = nil,
                a: Double? = nil, b: Double? = nil, c: Double? = nil) {
        self.x=x; self.y=y; self.z=z; self.a=a; self.b=b; self.c=c
    }
    public subscript(_ axis: Int) -> Double? {
        get { switch axis { case 0:x; case 1:y; case 2:z; case 3:a; case 4:b; default:c } }
        set { switch axis { case 0:x=newValue; case 1:y=newValue; case 2:z=newValue; case 3:a=newValue; case 4:b=newValue; default:c=newValue } }
    }
    /// Reference-plane display only when an axis is unknown. See unresolvedAxes.
    public var displayPoint: NCVector { .init(x ?? 0,y ?? 0,z ?? 0) }
    public var unresolvedAxes: String { (0..<6).filter { self[$0] == nil }.map { String(Array("XYZABC")[$0]) }.joined() }
}

public enum NCUnits: String, Codable, Sendable { case millimetres, inches
    var scale: Double { self == .inches ? 25.4 : 1 }
}
public enum NCPlane: String, Codable, Sendable { case xy, zx, yz
    // Right handed: G18 uses Z,X with positive Y normal.
    public var axes: [Int] { switch self { case .xy:[0,1,2]; case .zx:[2,0,1]; case .yz:[1,2,0] } }
    var code: Double { switch self { case .xy:17; case .zx:18; case .yz:19 } }
}
public enum NCFeedMode: String, Codable, Sendable { case perMinute, perRevolution, inverseTime }
public enum NCSpindleMode: String, Codable, Sendable { case rpm, constantSurfaceSpeed }
public enum NCSpindleDirection: String, Codable, Sendable { case stopped, clockwise, counterclockwise }
public struct NCSpindle: Codable, Equatable, Sendable {
    public internal(set) var mode: NCSpindleMode = .rpm
    /// RPM, or metres/minute for CSS. This is a command, not measured rotation.
    public internal(set) var speed: Double = 0
    public internal(set) var maximumRPM: Double?
    public internal(set) var direction: NCSpindleDirection = .stopped
}
public struct NCProcessState: Codable, Equatable, Sendable {
    public internal(set) var feedMode: NCFeedMode = .perMinute
    /// mm/min, mm/revolution, or inverse minutes according to feedMode.
    public internal(set) var feed: Double?
    public internal(set) var selectedTool: Int?
    public internal(set) var loadedTool: Int?
    public internal(set) var mist = false
    public internal(set) var flood = false
    public internal(set) var spindles: [Int:NCSpindle] = [0:NCSpindle()]
}

public enum NCCurve: Codable, Equatable, Sendable {
    case unlocated
    case line
    case arc(center: NCVector, sweepRadians: Double, plane: NCPlane)
    case bezier(controls: [NCVector])
    case nurbs(controls: [NCVector], weights: [Double], knots: [Double], order: Int)
}
public struct NCMotion: Encodable, Equatable, Sendable {
    public let line: Int
    public let start, end: NCPosition
    public let curve: NCCurve
    public let rapid: Bool
    public let process: NCProcessState
}
public struct NCEvent: Encodable, Equatable, Sendable {
    public let line: Int
    public let kind: String
    public let value: Double?
    public let process: NCProcessState
}
public struct NCWord: Encodable, Equatable, Sendable {
    public let letter: String
    public let value: Double
    public init(_ letter: String, _ value: Double) { self.letter = letter; self.value = value }
}
public struct NCBlock: Encodable, Equatable, Sendable {
    public let line: Int
    public let words: [NCWord]
}
public struct NCConfiguration: Codable, Equatable, Sendable {
    public var initialPosition = NCPosition()
    public var defaultUnits: NCUnits?
    public var arcRadiusToleranceMM: Double = 0.000001
    public var chordToleranceMM: Double = 0.02
    public var maximumBytes = 4_000_000
    public var maximumBlocks = 50_000
    public var maximumPoints = 200_000
    public var maximumControlPoints = 256
    public init() {}
    func validate() throws {
        guard arcRadiusToleranceMM.isFinite, arcRadiusToleranceMM > 0,
              chordToleranceMM.isFinite, chordToleranceMM >= arcRadiusToleranceMM*4,
              maximumBytes > 0, maximumBytes <= 16_000_000,
              maximumBlocks > 0, maximumBlocks <= 200_000,
              maximumPoints >= 2, maximumPoints <= 2_000_000,
              maximumControlPoints >= 4, maximumControlPoints <= 1024,
              (0..<6).allSatisfy({ initialPosition[$0].map { $0.isFinite && abs($0) <= 1e9 } ?? true })
        else { throw NCError("Invalid geometry tolerance, initial position or resource budget") }
    }
}
public struct NCProgram: Encodable, Sendable {
    public let profile: String
    public let blocks: [NCBlock]
    public let motions: [NCMotion]
    public let events: [NCEvent]
    public let finalPosition: NCPosition
    public let finalProcess: NCProcessState
    public let configuration: NCConfiguration
    public let notes: [String]
}

/// Cooperative cancellation checked during lexical, geometric and subdivision work.
public final class NCCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    public init() {}
    public func cancel() { lock.lock(); stopped = true; lock.unlock() }
    public func check() throws {
        lock.lock(); let value = stopped; lock.unlock()
        if value { throw CancellationError() }
    }
}
public enum NCFormat {
    public static func number(_ value: Double) -> String {
        var text = String(format:"%.15f",locale:Locale(identifier:"en_US_POSIX"),value)
        while text.last == "0" { text.removeLast() }
        if text.last == "." { text.removeLast() }
        return text == "-0" || text.isEmpty ? "0" : text
    }
}
