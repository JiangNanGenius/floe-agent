//
//  CADPresentationCamera.swift
//  FloeCADKit
//
//  Orbit camera for the presentation surface, expressed in RealityKit metres
//  and +Y up. The presentation installs one explicit non-AR camera entity at
//  the origin — a perspective or orthographic component, never RealityKit's
//  implicit default camera — and moves a single stage entity by this camera's
//  inverse view transform. Lighting, floor and products therefore share one
//  coordinate frame and one camera state — no second scene, no per-body camera
//  adjustments. Saving a view never changes this struct's live value; only an
//  explicit document command stores a copy.
//

#if canImport(SwiftUI) && canImport(RealityKit) && canImport(UIKit)
import Foundation
import RealityKit
import simd

nonisolated struct CADPresentationCamera: Equatable, Sendable {
    /// Model target in presentation metres.
    var target: SIMD3<Float> = .zero
    /// Eye distance in metres.
    var distance: Float = 1
    var azimuthRadians: Float = .pi * 0.22
    var elevationRadians: Float = .pi * 0.12
    var fovYDegrees: Float = 60
    /// Perspective or orthographic. The pose and the vertical framing angle are
    /// shared: an orthographic camera uses
    /// `distance * tan(fovY / 2)` as its half-height, so switching projection
    /// keeps the model the same on-screen size (the same relation the
    /// engineering `TurntableCamera` uses).
    var projection: CADCameraProjection = .perspective
    /// Transient export framing zoom: multiplies the visible half-height (and
    /// therefore the horizontal frustum) without changing the authored pose,
    /// distance or persisted FOV. It is set only while rendering a saved shot
    /// into a differently-shaped viewport and is never written to a document.
    var transientHalfHeightScale: Float = 1

    static let minimumDistance: Float = 0.002
    static let maximumDistance: Float = 500

    init(target: SIMD3<Float> = .zero,
         distance: Float = 1,
         azimuthRadians: Float = .pi * 0.22,
         elevationRadians: Float = .pi * 0.12,
         fovYDegrees: Float = 60,
         projection: CADCameraProjection = .perspective) {
        self.target = target
        self.distance = distance
        self.azimuthRadians = azimuthRadians
        self.elevationRadians = elevationRadians
        self.fovYDegrees = fovYDegrees
        self.projection = projection
    }

    /// A framing that keeps the whole model visible with a margin. Uses the
    /// bounding sphere so the fit is rotation-independent. When the viewport
    /// aspect (width / height) is supplied, the tighter of the vertical and
    /// horizontal fields of view is used, so a portrait viewport does not clip
    /// a wide model that fit vertically but not horizontally. `projection` is
    /// preserved: fitting an orthographic view stays orthographic.
    static func fitted(to bounds: CADPresentationBounds?,
                       fovYDegrees: Float = 60,
                       aspect: Float? = nil,
                       projection: CADCameraProjection = .perspective) -> CADPresentationCamera {
        guard let bounds else {
            return CADPresentationCamera(target: .zero, distance: 1,
                                         fovYDegrees: fovYDegrees,
                                         projection: projection)
        }
        let radius = max(bounds.radius, 0.002)
        let halfFov = fittedHalfAngle(fovYDegrees: fovYDegrees, aspect: aspect)
        let distance = min(max(radius / max(tan(halfFov), 0.05) * 1.18,
                               radius * 1.6),
                           maximumDistance)
        return CADPresentationCamera(
            target: bounds.center,
            distance: distance,
            azimuthRadians: .pi * 0.22,
            elevationRadians: .pi * 0.12,
            fovYDegrees: fovYDegrees,
            projection: projection)
    }

    /// Half-angle the fit must respect. The vertical half-FOV governs a
    /// landscape/square viewport; a portrait viewport narrows it by its
    /// aspect so the bounding sphere also fits horizontally.
    static func fittedHalfAngle(fovYDegrees: Float, aspect: Float?) -> Float {
        let vertical = max(fovYDegrees, 10) * .pi / 360
        guard let aspect, aspect.isFinite, aspect > 0, aspect < 1 else {
            return vertical
        }
        return atan(tan(vertical) * aspect)
    }

    /// Visible half-height at the target depth. Both projections share it, so
    /// toggling perspective/orthographic never changes the model's on-screen
    /// size (matching `TurntableCamera`'s orthographic scale derivation).
    var halfHeightAtTarget: Float {
        let fov = min(max(fovYDegrees, 10), 150)
        return max(distance * tan(fov * .pi / 360), 0.0005)
    }

    /// Vertical FOV the perspective component actually renders with. Equal to
    /// `fovYDegrees` unless a transient framing scale is active. This is the
    /// camera-side equivalent of multiplying the orthographic half-height: the
    /// authored FOV, distance and pose stay untouched.
    var effectiveFovYDegrees: Float {
        let scale = transientHalfHeightScale
        guard scale.isFinite, scale > 1.000001 else { return fovYDegrees }
        let half = min(max(fovYDegrees, 10), 150) * .pi / 360
        return 2 * atan(tan(half) * min(scale, 1_000)) * 180 / .pi
    }

    /// RealityKit projection component for this camera. Exactly one camera
    /// component is installed on the camera entity; `applyCamera` removes the
    /// other one.
    var perspectiveCameraComponent: PerspectiveCameraComponent {
        PerspectiveCameraComponent(
            // A fitted millimetre-sized part can be only 4 mm from the
            // camera. A fixed 10 mm near plane clips the entire model, even
            // after Fit. Scale clipping with the same orbit distance used by
            // the stage and exports; keep the existing limit for large scenes.
            near: max(0.00001, min(0.01, distance * 0.01)), far: .infinity,
            fieldOfViewInDegrees: effectiveFovYDegrees,
            fieldOfViewOrientation: .vertical)
    }

    /// `OrthographicCameraComponent.scale` is the half-height of the framed
    /// area when `scaleDirection` is `.vertical`. `near`/`far` bracket the
    /// model at the orbit distance, using the same proportional convention as
    /// the engineering camera. A transient saved-shot render multiplies the
    /// half-height, never the distance.
    var orthographicCameraComponent: OrthographicCameraComponent {
        var component = OrthographicCameraComponent()
        component.near = max(0.0005, distance * 0.01)
        component.far = max(100, distance * 40)
        let scale = transientHalfHeightScale
        let boundedScale = scale.isFinite ? min(max(scale, 1), 1_000) : 1
        component.scale = halfHeightAtTarget * boundedScale
        component.scaleDirection = .vertical
        return component
    }

    var position: SIMD3<Float> {
        let cosElevation = cos(elevationRadians)
        let offset = SIMD3(
            cosElevation * sin(azimuthRadians),
            sin(elevationRadians),
            cosElevation * cos(azimuthRadians))
        return target + offset * distance
    }

    /// World→camera transform applied to the presentation stage. The explicit
    /// PerspectiveCamera sits at the anchor origin looking down −Z, so this is
    /// exactly the inverse of the camera-to-world matrix.
    var stageTransform: simd_float4x4 {
        let eye = position
        let forward = simd_normalize(target - eye)
        var right = simd_cross(forward, SIMD3<Float>(0, 1, 0))
        if simd_length_squared(right) < 1e-8 {
            right = SIMD3(1, 0, 0)
        } else {
            right = simd_normalize(right)
        }
        let up = simd_cross(right, forward)
        return simd_float4x4(
            SIMD4(right.x, up.x, -forward.x, 0),
            SIMD4(right.y, up.y, -forward.y, 0),
            SIMD4(right.z, up.z, -forward.z, 0),
            SIMD4(-simd_dot(right, eye), -simd_dot(up, eye),
                  simd_dot(forward, eye), 1))
    }

    /// Camera-to-world matrix (for diagnostics and unit tests).
    var viewToWorld: simd_float4x4 {
        stageTransform.inverse
    }

    mutating func orbit(delta: SIMD2<Float>) {
        azimuthRadians -= delta.x * 0.007
        elevationRadians = min(max(elevationRadians + delta.y * 0.007, -1.48), 1.48)
        if azimuthRadians > .pi * 2 { azimuthRadians -= .pi * 2 }
        if azimuthRadians < -.pi * 2 { azimuthRadians += .pi * 2 }
    }

    /// Pan the target in the camera's screen plane. `delta` is in points and
    /// `viewportHeight` in points; the world delta is matched to the plane at
    /// the target so dragging keeps the point under the finger.
    mutating func pan(delta: SIMD2<Float>, viewportHeight: Float) {
        guard viewportHeight > 1 else { return }
        let worldPerPoint = 2 * distance * tan(fovYDegrees * .pi / 360) / viewportHeight
        let eye = position
        let forward = simd_normalize(target - eye)
        let right = simd_normalize(simd_cross(forward, SIMD3<Float>(0, 1, 0)))
        let up = simd_cross(right, forward)
        target -= right * (delta.x * worldPerPoint)
        target += up * (delta.y * worldPerPoint)
    }

    mutating func zoom(by scale: Float) {
        guard scale.isFinite, scale > 0 else { return }
        distance = min(max(distance / scale, Self.minimumDistance), Self.maximumDistance)
    }

    mutating func fit(_ bounds: CADPresentationBounds?, aspect: Float? = nil) {
        self = Self.fitted(to: bounds, fovYDegrees: fovYDegrees,
                           aspect: aspect, projection: projection)
    }

    var isValid: Bool {
        distance.isFinite && distance > 0
            && target.x.isFinite && target.y.isFinite && target.z.isFinite
            && azimuthRadians.isFinite && elevationRadians.isFinite
            && fovYDegrees.isFinite && fovYDegrees >= 10 && fovYDegrees <= 150
    }
}
#endif
