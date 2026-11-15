// SPDX-License-Identifier: MPL-2.0
import Foundation
import CryptoKit

public enum BuildingAnalysisError: Error, Equatable, Sendable {
    case invalidInput(String)
    case malformedPhotometry(String)
    case unsupportedPhotometry(String)
    case budgetExceeded(Int)
    case cancelled
}

extension BuildingAnalysisError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidInput(let field): "Invalid analysis input: \(field)"
        case .malformedPhotometry(let detail): "Malformed photometry: \(detail)"
        case .unsupportedPhotometry(let detail): "Unsupported photometry: \(detail)"
        case .budgetExceeded(let count): "Analysis cell budget exceeded: \(count)"
        case .cancelled: "Analysis cancelled"
        }
    }
}

/// Analysis coordinates are explicitly metres, X/Y horizontal and Z up.
public struct AnalysisVector3: Codable, Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double
    public init(_ x: Double, _ y: Double, _ z: Double) { self.x=x; self.y=y; self.z=z }
    public var isFinite: Bool { x.isFinite && y.isFinite && z.isFinite }
    public var squaredLength: Double { x*x+y*y+z*z }
    public func dot(_ b: Self) -> Double { x*b.x+y*b.y+z*b.z }
    public func cross(_ b: Self) -> Self { .init(y*b.z-z*b.y,z*b.x-x*b.z,x*b.y-y*b.x) }
    public func normalized() throws -> Self {
        guard isFinite, squaredLength.isFinite, squaredLength>1e-20 else {
            throw BuildingAnalysisError.invalidInput("direction")
        }
        return self / sqrt(squaredLength)
    }
    public static func +(a: Self,b: Self)->Self { .init(a.x+b.x,a.y+b.y,a.z+b.z) }
    public static func -(a: Self,b: Self)->Self { .init(a.x-b.x,a.y-b.y,a.z-b.z) }
    public static func *(a: Self,b: Double)->Self { .init(a.x*b,a.y*b,a.z*b) }
    public static func /(a: Self,b: Double)->Self { .init(a.x/b,a.y/b,a.z/b) }
}

public enum BuildingAnalysisFingerprint {
    public static func hash<T: Encodable>(_ value: T) throws -> String {
        let encoder=JSONEncoder(); encoder.outputFormatting=[.sortedKeys]
        return dataHash(try encoder.encode(value))
    }
    public static func dataHash(_ data: Data) -> String {
        SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
    }
}
