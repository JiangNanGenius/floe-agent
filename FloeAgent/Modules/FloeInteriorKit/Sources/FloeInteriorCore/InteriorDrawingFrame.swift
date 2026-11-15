// SPDX-License-Identifier: MPL-2.0
import Foundation

public enum InteriorDrawingView: String, Codable, Hashable, Sendable, CaseIterable {
    case frontElevation, sideSection, horizontalPlan
}

/// Architectural view basis in domain coordinates (X width, Y depth, Z up).
/// Floe CAD drawing directions are explicit: the API's `viewUp` argument is
/// currently an in-plane X-axis hint, rather than a vertical-axis vector.
public struct InteriorDrawingFrame: Codable, Equatable, Sendable {
    public let view: InteriorDrawingView
    public let originMM: InteriorVector3

    public init(view: InteriorDrawingView, originMM: InteriorVector3 = .init(0, 0, 0)) throws {
        guard originMM.values.allSatisfy(\.isFinite) else {
            throw InteriorDesignError.invalidDimension("viewOrigin")
        }
        self.view = view
        self.originMM = originMM
    }

    public var domainNormal: InteriorVector3 {
        switch view {
        case .frontElevation: .init(0, -1, 0)
        case .sideSection: .init(1, 0, 0)
        case .horizontalPlan: .init(0, 0, 1)
        }
    }

    public var domainHorizontalAxis: InteriorVector3 {
        switch view {
        case .frontElevation, .horizontalPlan: .init(1, 0, 0)
        case .sideSection: .init(0, 1, 0)
        }
    }

    /// The same right-handed rotation used by native board creation.
    private func native(_ value: InteriorVector3) -> InteriorVector3 {
        .init(value.x, value.z, -value.y)
    }

    public var nativeNormal: InteriorVector3 { native(domainNormal) }
    public var nativeHorizontalAxis: InteriorVector3 { native(domainHorizontalAxis) }
    public var nativeOriginMM: InteriorVector3 { native(originMM) }

    private enum CodingKeys: String, CodingKey { case view, originMM }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(view: values.decode(InteriorDrawingView.self, forKey: .view),
                      originMM: values.decode(InteriorVector3.self, forKey: .originMM))
    }
}
