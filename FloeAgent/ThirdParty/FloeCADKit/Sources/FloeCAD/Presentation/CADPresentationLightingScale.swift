// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Shadow coverage follows the visible scene, from millimetre parts to a
/// building. A fixed 20 m cascade clips large models and wastes small-model
/// precision. Only renderer inputs change; authored lights remain intact.
nonisolated enum CADPresentationLightingScale {
    static func shadowDistance(radiusMetres: Float?) -> Float {
        guard let radiusMetres, radiusMetres.isFinite, radiusMetres > 0 else { return 20 }
        return min(max(radiusMetres * 4, 0.1), 2_000)
    }
}
