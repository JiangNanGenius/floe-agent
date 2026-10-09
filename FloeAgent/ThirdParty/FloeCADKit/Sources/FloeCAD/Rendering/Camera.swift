//
//  Camera.swift
//  openshape3d
//
//  Turntable camera (stable Y-up, the CAD convention): orbit azimuth/elevation
//  around a target, dolly by distance, pan moves the target in the view plane.
//

import Foundation
import CoreGraphics
import simd

/// Camera projection mode (spec §7.3: FOV slider reaching 0° = orthographic;
/// v1 is a binary toggle).
nonisolated enum CameraProjection: Sendable, Equatable {
    case perspective(fovY: Float)
    case orthographic
}

nonisolated struct TurntableCamera: Sendable, Equatable {
    var target: SIMD3<Float> = .zero
    var distance: Float = 12
    var azimuth: Float = .pi / 5      // radians around +Y, 0 looks down -Z
    var elevation: Float = .pi / 7    // radians above the ground plane
    var projection: CameraProjection = .perspective(fovY: TurntableCamera.defaultFovY)

    static let defaultFovY: Float = 40 * .pi / 180
    static let elevationLimit: Float = 89 * .pi / 180
    /// Farthest a pinch can dolly out, mm (100 m: a room scan still fits).
    static let maxZoomDistance: Float = 100_000

    /// Vertical FOV used for screen-size conversions (pan, fit, gizmo scale).
    /// Orthographic keeps the default so the frustum height at the target
    /// depth (2·d·tan(fov/2)) matches perspective — toggling projection keeps
    /// the model the same on-screen size and pinch-zoom keeps working.
    var fovY: Float {
        if case .perspective(let fov) = projection { return fov }
        return Self.defaultFovY
    }

    var position: SIMD3<Float> {
        let ce = cos(elevation)
        let offset = SIMD3(
            ce * sin(azimuth),
            sin(elevation),
            ce * cos(azimuth)
        ) * distance
        return target + offset
    }

    var viewMatrix: simd_float4x4 {
        Matrices.lookAt(eye: position, target: target, up: SIMD3(0, 1, 0))
    }

    /// `centerOffset` moves the image's centre — where the target lands — off
    /// the viewport's middle, in NDC (the viewport spans −1…1): the middle of
    /// the strip the phone palette leaves visible (`ViewportSafeArea`).
    /// Everything that draws, picks or projects must pass the same offset.
    func projectionMatrix(aspect: Float, centerOffset: SIMD2<Float> = .zero) -> simd_float4x4 {
        // Near/far scaled to distance keeps depth precision sane whether the
        // model is 5mm or 5m.
        let near = max(0.01, distance * 0.01)
        let far = max(100, distance * 40)
        let lens: simd_float4x4
        switch projection {
        case .perspective(let fov):
            lens = Matrices.perspective(fovYRadians: fov, aspect: aspect, near: near, far: far)
        case .orthographic:
            // Ortho scale derives from distance: the frustum height equals the
            // perspective height at the target depth, so dolly = zoom.
            let halfHeight = distance * tan(fovY * 0.5)
            lens = Matrices.orthographic(
                halfWidth: halfHeight * aspect, halfHeight: halfHeight, near: near, far: far
            )
        }
        guard centerOffset != .zero else { return lens }
        // x_clip += offset · w_clip: after the divide every point moves by
        // the same NDC offset, perspective and ortho alike.
        var shift = matrix_identity_float4x4
        shift.columns.3 = SIMD4(centerOffset.x, centerOffset.y, 0, 1)
        return shift * lens
    }

    func viewProjection(aspect: Float, centerOffset: SIMD2<Float> = .zero) -> simd_float4x4 {
        projectionMatrix(aspect: aspect, centerOffset: centerOffset) * viewMatrix
    }

    // MARK: - Navigation

    mutating func orbit(deltaPixels: CGSize, viewportSize: CGSize) {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return }
        let sensitivity: Float = 2 * .pi / Float(min(viewportSize.width, viewportSize.height))
        azimuth -= Float(deltaPixels.width) * sensitivity
        elevation += Float(deltaPixels.height) * sensitivity
        elevation = min(max(elevation, -Self.elevationLimit), Self.elevationLimit)
    }

    mutating func pan(deltaPixels: CGSize, viewportSize: CGSize) {
        guard viewportSize.height > 0 else { return }
        // World-units-per-pixel at the target depth.
        let worldPerPixel = 2 * distance * tan(fovY * 0.5) / Float(viewportSize.height)
        let view = viewMatrix
        // View matrix rows give camera basis vectors in world space.
        let right = SIMD3(view.columns.0.x, view.columns.1.x, view.columns.2.x)
        let up = SIMD3(view.columns.0.y, view.columns.1.y, view.columns.2.y)
        target -= right * Float(deltaPixels.width) * worldPerPixel
        target += up * Float(deltaPixels.height) * worldPerPixel
    }

    mutating func zoom(scale: Float) {
        guard scale > 0 else { return }
        // The ceiling never sits below the current distance: `fit` sets
        // distance directly, and a metre-scale model fits from ~2.6 m, so the
        // old fixed 2000 mm cap turned every pinch-OUT there into a jump IN.
        // Near/far scale with distance, so a far camera stays depth-precise.
        distance = min(max(distance / scale, 0.05), max(Self.maxZoomDistance, distance))
    }

    /// Ray through a screen point (points, UIKit top-left origin).
    /// Orthographic needs no special branch: the inverse view-projection is
    /// affine (w stays 1), so unprojected near/far points yield parallel rays
    /// whose origins slide on the near plane — exactly ortho picking.
    func ray(through point: CGPoint, viewportSize: CGSize,
             centerOffset: SIMD2<Float> = .zero) -> Ray {
        let aspect = Float(viewportSize.width / max(viewportSize.height, 1))
        let ndcX = Float(point.x / viewportSize.width) * 2 - 1
        let ndcY = 1 - Float(point.y / viewportSize.height) * 2
        let inverseVP = simd_inverse(viewProjection(aspect: aspect, centerOffset: centerOffset))
        let nearPoint = inverseVP * SIMD4(ndcX, ndcY, 0, 1)
        let farPoint = inverseVP * SIMD4(ndcX, ndcY, 1, 1)
        let near3 = SIMD3(nearPoint.x, nearPoint.y, nearPoint.z) / nearPoint.w
        let far3 = SIMD3(farPoint.x, farPoint.y, farPoint.z) / farPoint.w
        return Ray(origin: near3, direction: simd_normalize(far3 - near3))
    }

    /// Frame the given world-space AABB, keeping the current orientation.
    /// `aspect` is the viewport's width / height: the bounding sphere is fitted
    /// inside whichever FOV is tighter, so a wide model on a portrait phone
    /// (aspect ≈ 0.46) no longer overflows the width. Nil (no laid-out
    /// viewport yet) or aspect ≥ 1 keeps the vertical fit.
    mutating func fit(boundsMin: SIMD3<Float>, boundsMax: SIMD3<Float>, aspect: Float? = nil) {
        let center = (boundsMin + boundsMax) * 0.5
        let radius = max(simd_length(boundsMax - boundsMin) * 0.5, 0.5)
        target = center
        distance = radius / tan(fitHalfAngle(aspect: aspect)) * 1.35
    }

    /// The half-FOV the fit must respect. The horizontal half-FOV is
    /// atan(tan(fovY / 2) · aspect); orthographic needs no branch, since its
    /// half-width is distance · tan(fovY / 2) · aspect — the same relation.
    func fitHalfAngle(aspect: Float?) -> Float {
        let vertical = fovY * 0.5
        guard let aspect, aspect.isFinite, aspect > 0, aspect < 1 else { return vertical }
        return atan(tan(vertical) * aspect)
    }
}

/// The part of the viewport the tool palette leaves visible. On a phone the
/// palette covers ~80 of 440 points at one side, and Zoom to Fit centred on
/// the full width put the model's near side under it. Fits frame into the
/// visible strip (`fitAspect`) and the projection centre moves to its middle
/// (`centerOffset`), so the model stays clear at every orbit angle and
/// standard view — not only the one it was fitted at, as shifting the fit's
/// target would.
nonisolated struct ViewportSafeArea: Equatable, Sendable {
    /// Points covered at the leading / trailing edge.
    var leading: CGFloat = 0
    var trailing: CGFloat = 0

    /// The side a palette at `frame` (viewport coordinates) covers. A palette
    /// an open panel pushed inward, leaving under half the width visible,
    /// covers nothing: framing into a sliver is worse than the overlap.
    static func palette(at frame: CGRect?, onRight: Bool, viewportSize: CGSize) -> ViewportSafeArea {
        guard let frame, viewportSize.width > 0 else { return ViewportSafeArea() }
        let area = onRight
            ? ViewportSafeArea(trailing: max(0, viewportSize.width - frame.minX))
            : ViewportSafeArea(leading: max(0, frame.maxX))
        return area.visibleWidth(in: viewportSize.width) >= viewportSize.width * 0.5
            ? area : ViewportSafeArea()
    }

    func visibleWidth(in width: CGFloat) -> CGFloat { width - leading - trailing }

    /// The NDC shift that centres the projection on the visible strip.
    func centerOffset(viewportSize: CGSize) -> SIMD2<Float> {
        guard viewportSize.width > 0 else { return .zero }
        return SIMD2(Float((leading - trailing) / viewportSize.width), 0)
    }

    /// Width / height of the visible strip — the aspect a fit must respect.
    /// Nil before layout (the MTKView starts at .zero).
    func fitAspect(viewportSize: CGSize) -> Float? {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return nil }
        return Float(visibleWidth(in: viewportSize.width) / viewportSize.height)
    }
}

/// Canonical turntable poses for the Views popover (spec §7.3).
nonisolated enum StandardView: String, CaseIterable, Identifiable, Sendable {
    case isometric = "Isometric"
    case top = "Top"
    case bottom = "Bottom"
    case front = "Front"
    case back = "Back"
    case right = "Right"
    case left = "Left"

    var id: String { rawValue }

    /// The world axis this view looks along — the normal a sketch plane must
    /// have for this to be its head-on (or underside) view. Isometric looks
    /// along no axis. Y is up: Top/Bottom look along Y, Front/Back along Z,
    /// Right/Left along X.
    var viewAxis: SIMD3<Double>? {
        switch self {
        case .isometric: return nil
        case .top, .bottom: return SIMD3(0, 1, 0)
        case .front, .back: return SIMD3(0, 0, 1)
        case .right, .left: return SIMD3(1, 0, 0)
        }
    }

    /// Whether this view looks straight at `plane` from either side.
    func isHeadOn(to plane: SketchPlane) -> Bool {
        guard let axis = viewAxis else { return false }
        return abs(simd_dot(axis, simd_normalize(plane.normal))) > 0.999
    }

    /// The pose for this view, keeping target/distance/projection. Top and
    /// Bottom clamp to ±89° (TurntableCamera.elevationLimit) — 1° short of a
    /// true plan view, because the turntable's fixed Y-up degenerates at ±90°.
    /// They square the azimuth up to the nearest quadrant: near-vertical, the
    /// azimuth IS the on-screen roll, and a plan view that keeps an arbitrary
    /// orbit angle comes out rolled by that angle (a 36° tilt was reported
    /// after a stray orbit, and no view command could undo it). Nearest
    /// quadrant rather than always 0 so the flight stays short.
    func applied(to camera: TurntableCamera) -> TurntableCamera {
        var cam = camera
        switch self {
        case .isometric:
            cam.azimuth = .pi / 5
            cam.elevation = .pi / 7
        case .top:
            cam.azimuth = Self.nearestQuadrant(camera.azimuth)
            cam.elevation = TurntableCamera.elevationLimit
        case .bottom:
            cam.azimuth = Self.nearestQuadrant(camera.azimuth)
            cam.elevation = -TurntableCamera.elevationLimit
        case .front:
            cam.azimuth = 0
            cam.elevation = 0
        case .back:
            cam.azimuth = .pi
            cam.elevation = 0
        case .right:
            cam.azimuth = .pi / 2
            cam.elevation = 0
        case .left:
            cam.azimuth = -.pi / 2
            cam.elevation = 0
        }
        return cam
    }

    /// The multiple of 90° closest to `azimuth`, so a plan view ends upright.
    static func nearestQuadrant(_ azimuth: Float) -> Float {
        (azimuth / (.pi / 2)).rounded() * (.pi / 2)
    }
}
