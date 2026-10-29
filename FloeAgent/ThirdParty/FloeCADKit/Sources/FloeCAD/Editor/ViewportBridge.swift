//
//  ViewportBridge.swift
//  openshape3d
//
//  The contract between the editor (model side) and the Metal viewport
//  (render side). The viewport consumes ViewportScene and never mutates the
//  document; it reports events back through ViewportEventHandler.
//

import OCCTShim
import Foundation
import simd
#if canImport(MetalKit)
import MetalKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// One encoded image map of an engineering material. Exactly one entry per
/// `MaterialTextureSlot` (the canonical model allows at most one), carried from
/// the applied `BodyMaterialSpec` without a second material store.
struct BodyMaterialMap: Equatable {
    var slot: MaterialTextureSlot
    /// Encoded PNG/JPEG bytes, bounded by `CADMaterialLimits`.
    var data: Data
    /// Cache identity computed ONCE when the drawable is built — never per
    /// frame. The applied snapshot's persisted SHA-256 when it covers these
    /// bytes (the normal service/inspector path), otherwise a deterministic
    /// byte fingerprint for legacy images that arrived without metadata.
    var cacheIdentity: String
    /// Declared colour space of the encoded image (defaults mirror the core:
    /// base colour/emissive are sRGB, scalar/normal maps are linear data).
    var colorSpace: MaterialTextureColorSpace
    /// Where the image's first row is; applied as a shader-side V flip.
    var orientation: MaterialTextureOrientation

    /// Decode/cache key: content identity + slot + declared colour space. The
    /// orientation is a sampling flag, not a decode property, so it stays out
    /// of the key (two materials differing only in row order share one upload).
    var textureCacheKey: String {
        "\(slot.rawValue)|\(colorSpace.rawValue)|\(cacheIdentity)"
    }

    var flipsV: Bool { orientation == .bottomLeft }
    var isSRGB: Bool { colorSpace == .srgb }
    var uniformFlag: UInt32 { slot.uniformFlag }

    /// Identity for a slot's bytes. A metadata SHA is used only when its
    /// recorded byte count still matches, so a stale/edited blob cannot point
    /// the cache at a different image.
    static func identity(for data: Data,
                         metadata: CADMaterialTextureMetadata?) -> String {
        if let sha = metadata?.sha256, !sha.isEmpty,
           metadata?.byteCount == data.count {
            return sha
        }
        return "fnv1a-\(data.count)-\(fingerprint(data))"
    }

    /// Deterministic FNV-1a over the byte count plus the head, middle and tail
    /// of the image. Used only when no persisted digest exists; equal images
    /// give equal identities in every process (unlike Swift's seeded Hasher).
    static func fingerprint(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        func mix(_ slice: Data) {
            for byte in slice {
                hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
            }
        }
        mix(data.prefix(32))
        if data.count > 96 {
            mix(data.dropFirst(data.count / 2).prefix(32))
        }
        mix(data.suffix(32))
        return String(hash, radix: 16)
    }
}

/// Fragment texture unit and `BodyUniforms` flag bit for one slot. The bit
/// order mirrors the C `BodyTextureFlag` enum in ShaderTypes.h and the
/// `MaterialTextureSlot` declaration order; the private source check asserts
/// the two never drift.
extension MaterialTextureSlot {
    var uniformFlag: UInt32 {
        switch self {
        case .baseColor: return 1 << 0
        case .metallic: return 1 << 1
        case .roughness: return 1 << 2
        case .normal: return 1 << 3
        case .emissive: return 1 << 4
        case .opacity: return 1 << 5
        }
    }

    var textureUnit: Int {
        switch self {
        case .baseColor: return 0
        case .metallic: return 1
        case .roughness: return 2
        case .normal: return 3
        case .emissive: return 4
        case .opacity: return 5
        }
    }
}

/// Render-side appearance of a body (or of one resolved face range): nil on a
/// `BodyDrawable` keeps the legacy shaded look exactly (metallic 0, legacy
/// fixed highlight, no emission).
///
/// This is the ONE material value both the body and its face ranges use; it
/// carries every canonical scalar and every image map, so the engineering
/// viewport cannot "accept" an edit it then ignores. Present mode resolves the
/// same `BodyMaterialSpec` independently.
struct BodyMaterial: Equatable {
    var baseColor: SIMD4<Float>
    var metallic: Float = 0
    var roughness: Float = 0
    /// Effective opacity 0…1. Below 1 the body (or face) is drawn in the
    /// blended pass with this alpha.
    var opacity: Float = 1
    /// Emissive colour factor (renderer working space) and strength; strength
    /// 0 (the default) means no emission, so a legacy body is unchanged.
    var emissive: SIMD3<Float> = .zero
    var emissiveStrength: Float = 0
    /// UV source/mapping. Non-mesh values generate render UVs on the GPU
    /// upload path from the mesh's own positions — the B-rep/mesh is never
    /// rewritten.
    var uvMapping: CADMaterialUVMapping? = nil
    /// At most one map per slot, in `MaterialTextureSlot.allCases` order.
    var maps: [BodyMaterialMap] = []
    /// Slots whose bytes exist but cannot be sampled on this mesh: it has no
    /// authored UVs and the material uses the mesh UV source. Reported (not
    /// silently painted with a guessed projection); the scalar factors remain.
    var unavailableMapSlots: [MaterialTextureSlot] = []
    var textureRevision: UInt64 = 0

    func map(_ slot: MaterialTextureSlot) -> BodyMaterialMap? {
        maps.first { $0.slot == slot }
    }

    /// True when any part of this appearance needs the blended pass: a
    /// sub-1 opacity factor, or an opacity MAP (whose pixels are only known on
    /// the GPU, so the range must be blended regardless of the factor).
    var isTransparent: Bool {
        opacity < 0.999 || map(.opacity) != nil
    }

    var hasAnyMap: Bool { !maps.isEmpty }

    /// Image data is compared by identity, not byte-for-byte: `BodyMaterial`
    /// equality runs on every scene rebuild, and the cache identity already
    /// covers the content.
    static func == (lhs: BodyMaterial, rhs: BodyMaterial) -> Bool {
        lhs.baseColor == rhs.baseColor
            && lhs.metallic == rhs.metallic
            && lhs.roughness == rhs.roughness
            && lhs.opacity == rhs.opacity
            && lhs.emissive == rhs.emissive
            && lhs.emissiveStrength == rhs.emissiveStrength
            && lhs.uvMapping == rhs.uvMapping
            && lhs.unavailableMapSlots == rhs.unavailableMapSlots
            && lhs.textureRevision == rhs.textureRevision
            && lhs.maps.count == rhs.maps.count
            && zip(lhs.maps, rhs.maps).allSatisfy { pair in
                pair.0.slot == pair.1.slot
                    && pair.0.cacheIdentity == pair.1.cacheIdentity
                    && pair.0.colorSpace == pair.1.colorSpace
                    && pair.0.orientation == pair.1.orientation
            }
    }
}

extension BodyMaterial {
    /// Default colour space for a slot when the applied snapshot carries no
    /// typed metadata (legacy images). Matches `CADMaterialTexture`'s own
    /// defaults and the Presentation resolver.
    static func defaultColorSpace(for slot: MaterialTextureSlot) -> MaterialTextureColorSpace {
        slot == .baseColor || slot == .emissive ? .srgb : .linear
    }

    /// The render-side form of a body's persisted appearance — the one mapping
    /// shared by the body and by every live preview that stands in for it
    /// (push/pull, blend, shell, delete/replace face), which otherwise drew the
    /// default grey.
    ///
    /// Maps ride along only when the mesh can actually sample them: a rebuilt
    /// (boolean'd, blended, previewed) mesh has no texcoords and no projection,
    /// so it keeps the colour/scalars and drops the maps (recorded in
    /// `unavailableMapSlots`) rather than pretending they are painted.
    init(spec: BodyMaterialSpec, meshHasTexcoords: Bool, revision: UInt64) {
        let clean = spec.clamped
        let mapping = clean.uvMapping
        let canProject = (mapping?.source ?? .mesh) != .mesh
        let canSample = meshHasTexcoords || canProject

        var maps: [BodyMaterialMap] = []
        var unavailable: [MaterialTextureSlot] = []
        for slot in MaterialTextureSlot.allCases {
            guard let data = clean.textureData(for: slot), !data.isEmpty else { continue }
            // Corrupt or oversized bytes are dropped by the renderer, never
            // guessed at; the scalar factors still shade the body.
            guard data.count <= CADMaterialLimits.maximumTextureBytes,
                  MaterialImageSniffer.mimeType(of: data) != nil else { continue }
            guard canSample else {
                unavailable.append(slot)
                continue
            }
            let metadata = clean.textureMetadata?.first { $0.slot == slot }
            maps.append(BodyMaterialMap(
                slot: slot,
                data: data,
                cacheIdentity: BodyMaterialMap.identity(for: data, metadata: metadata),
                colorSpace: metadata?.colorSpace ?? Self.defaultColorSpace(for: slot),
                orientation: metadata?.orientation ?? .topLeft))
        }

        self.init(
            baseColor: SIMD4<Float>(clean.baseColor),
            metallic: Float(clean.metallic),
            roughness: Float(clean.roughness),
            opacity: Float(clean.effectiveOpacity),
            emissive: clean.emissive.map {
                SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z))
            } ?? .zero,
            emissiveStrength: Float(clean.emissiveStrength ?? 0),
            uvMapping: mapping,
            maps: maps,
            unavailableMapSlots: unavailable,
            textureRevision: revision
        )
    }
}

/// One resolved face-material range on a body. `triangles` index the body's
/// render mesh; the mesh itself is unchanged and shared.
struct BodyFaceMaterial: Equatable {
    var faceIndex: Int
    var triangles: [Int]
    var material: BodyMaterial
}

/// Everything the renderer needs to draw one body.
struct BodyDrawable: Identifiable {
    let id: BodyID
    var renderMesh: RenderMesh
    var edges: FeatureEdgeSet?
    /// Cache key: buffers are rebuilt only when (id, meshRevision) changes.
    var meshRevision: UInt64
    var modelMatrix: simd_float4x4
    var baseColor: SIMD4<Float>
    var selectionState: UInt32 = 0 // SelectionState raw value
    var isTranslucent: Bool = false
    /// Optional appearance override; when set its colour, PBR factors,
    /// emission and image maps replace `baseColor` and the default shading.
    var material: BodyMaterial?
    /// Resolved per-face appearances. Empty unless the body has face bindings;
    /// the renderer splits the SAME index buffer into ranges.
    var faceMaterials: [BodyFaceMaterial] = []
    /// Set when this drawable is an ASSEMBLY INSTANCE placement rather than a
    /// document body: the shared source body's mesh is referenced (never
    /// duplicated) and `modelMatrix` carries the instance transform composed
    /// with the source placement. Taps and selection route to the instance id.
    var assemblyInstanceID: UUID? = nil

    var hasTransparentMaterial: Bool {
        (material?.isTransparent ?? false)
            || faceMaterials.contains { $0.material.isTransparent }
    }
}

/// A snapshot of what the viewport should draw. Value type, rebuilt cheaply
/// by the editor on any model change (mesh arrays are CoW references).
/// A batch of world-space line segments drawn in one color (sketch entities,
/// pending rubber-band, profile highlights).
struct SketchLineBatch {
    /// Pairs: [a0,b0, a1,b1, ...]
    var segments: [SIMD3<Float>]
    var color: SIMD4<Float>
}

/// Translucent triangles filling closed sketch profiles (Shapr3D-style fill).
struct SketchFillBatch {
    /// Triangle list: 3 vertices per triangle, world space.
    var triangles: [SIMD3<Float>]
    var color: SIMD4<Float>
}

/// Viewport display mode (spec §16.4). `.shaded` is the pre-mode renderer
/// exactly: lit fill + feature edges.
enum DisplayMode: String, CaseIterable, Equatable {
    /// Lit fill + feature edges (default).
    case shaded
    /// Lit fill only.
    case shadedNoEdges
    /// Feature edges over a depth-only prepass — hidden lines stay hidden,
    /// no fill.
    case wireframe
    /// Translucent fill (depth read, no write) + feature edges.
    case xray
}

/// Section view clip plane (spec §16.1). Fragments on the side the normal
/// points AWAY from — dot(p - point, normal) < 0 — are discarded in the lit,
/// edge, fill, and sketch-line shaders. Cut faces are left open (no caps).
struct SectionPlaneState: Equatable {
    var point: SIMD3<Float>
    var normal: SIMD3<Float>
    var enabled: Bool = true

    /// Shader-ready plane: xyz unit normal, w offset (dot(p, xyz) + w >= 0
    /// is kept). Zero when the normal is degenerate.
    var clipVector: SIMD4<Float> {
        let length = simd_length(normal)
        guard length > 1e-6 else { return .zero }
        let n = normal / length
        return SIMD4(n, -simd_dot(n, point))
    }
}

/// A reference image placed in the world (Insert Image, plan §B10). `origin`
/// is the quad CENTER; xAxis/yAxis are unit world directions spanning
/// width × height. Nonisolated so the texture cache can stay actor-free.
nonisolated struct ImageQuadDrawable: Identifiable, Sendable {
    let id: UUID
    var origin: SIMD3<Float>
    var xAxis: SIMD3<Float>
    var yAxis: SIMD3<Float>
    var width: Float
    var height: Float
    var opacity: Float = 1
    /// Encoded image bytes (PNG/JPEG). Decoded into an MTLTexture keyed by
    /// (id, textureRevision) — bump the revision to force a reload.
    var textureData: Data
    var textureRevision: UInt64 = 0
}

/// The extrude pull arrow ("the arrows are the interface for creating an
/// extrude"). Drawn in the overlay pass at the pull cap.
struct PullArrowState: Equatable {
    var origin: SIMD3<Float>
    var direction: SIMD3<Float> // unit
    /// Operation-validity feedback (spec §18): false renders the arrow red
    /// because committing the pending result would fail.
    var isValid: Bool = true
}

struct ViewportScene {
    var bodies: [BodyDrawable] = []
    /// Active sketch grid; nil keeps the modeling view's ground grid.
    var gridPlane: SketchPlane?
    /// Legacy-scene presentation imported through `importLegacyScene`:
    /// camera (consumed by the viewport coordinator at open), background,
    /// lighting rig and grid visibility. Nil on ordinary CAD documents.
    var appearance: CADSceneSettings?
    /// Grid visibility. `false` skips the ground/sketch grid pass; ordinary
    /// CAD documents keep `true`.
    var showsGrid = true
    /// Move gizmo, when a body is selected. `scale` is finalized by the
    /// renderer each frame for constant screen size.
    var gizmo: GizmoState?
    /// Sketch overlay lines, drawn after the grid with edge depth bias.
    var sketchLines: [SketchLineBatch] = []
    /// Closed-profile fills, drawn between the grid and the sketch lines.
    var profileFills: [SketchFillBatch] = []
    /// Extrude pull arrow, drawn in the overlay pass.
    var pullArrow: PullArrowState?
    /// Plane picker tiles (origin planes + construction planes) shown while a
    /// sketch tool waits for a plane; drawn in the overlay pass.
    var planePickers: [PlanePickerTile] = []
    /// Section view (spec §16.1); nil (or `enabled == false`) clips nothing.
    var sectionPlane: SectionPlaneState?
    /// Display mode (spec §16.4); `.shaded` matches the pre-mode output.
    var displayMode: DisplayMode = .shaded
    /// Extra low-alpha edge pass with a reversed depth test (spec §16.4
    /// "Show Hidden Edges").
    var showHiddenEdges: Bool = false
    /// Reference images, drawn after the grid and before profile fills.
    var imageQuads: [ImageQuadDrawable] = []
    /// Cheap planar blob shadows under body AABBs (visualization v1).
    var groundShadow: Bool = false

    /// World-space AABB of everything drawn — bodies AND sketches — for
    /// fit-view. Nil when empty.
    ///
    /// Sketches count: a sketch on an empty document used to leave Zoom to
    /// Fit with nothing to frame, so it fell back to the DEFAULT camera — the
    /// drawing you were looking at head-on snapped to an isometric view with
    /// the 950 mm sketch off-screen (gotcha 38). The sketch overlay batches
    /// are already in world space, so folding them in costs one pass.
    var worldBounds: (min: SIMD3<Float>, max: SIMD3<Float>)? {
        var result: (min: SIMD3<Float>, max: SIMD3<Float>)?
        func fold(_ world: SIMD3<Float>) {
            if let current = result {
                result = (simd_min(current.min, world), simd_max(current.max, world))
            } else {
                result = (world, world)
            }
        }
        for body in bodies {
            let aabb = body.renderMesh.localAABB
            // Transform the 8 corners; cheap and correct for TRS.
            for i in 0..<8 {
                let corner = SIMD3<Float>(
                    (i & 1) == 0 ? aabb.min.x : aabb.max.x,
                    (i & 2) == 0 ? aabb.min.y : aabb.max.y,
                    (i & 4) == 0 ? aabb.min.z : aabb.max.z
                )
                let world4 = body.modelMatrix * SIMD4(corner, 1)
                fold(SIMD3(world4.x, world4.y, world4.z))
            }
        }
        for batch in sketchLines {
            for point in batch.segments { fold(point) }
        }
        for batch in profileFills {
            for point in batch.triangles { fold(point) }
        }
        return result
    }
}

// MARK: - Canvas preview (viewport, independent of drawings)

#if canImport(MetalKit)
public extension FloeCADDocument {
    /// Offscreen VIEWPORT thumbnail of the live document scene (bodies, grid,
    /// assembly instances) — a Canvas node preview must never depend on an
    /// engineering DRAWING page existing. Returns nil when Metal is
    /// unavailable; callers may then use `CADCanvasPreview.placeholderPNG()`.
    ///
    /// ISOLATION (canvas-apply CUA regression): the snapshot is rendered by a
    /// DETACHED `Renderer` over a value-type copy of `viewModel.scene`, fitted
    /// with its own local camera. It deliberately does NOT go through
    /// `ViewportCoordinator.attach`, which would (a) install the transient
    /// coordinator as the shared view model's `cameraControl` and overwrite
    /// its `thumbnailProvider`/`screenshotProvider`, and (b) fit ITS camera to
    /// the scene. The editor's live renderer callbacks, camera, selection and
    /// orientation cube are therefore untouched — closing the tools panel
    /// after "Apply to canvas" can no longer re-frame or blank the live
    /// viewport.
    @MainActor
    func viewportThumbnailPNG(width: Int = 640, height: Int = 480) -> Data? {
        guard width > 0, height > 0 else { return nil }
        guard let context = RenderContext() else { return nil }
        // Read the current scene ONCE (a value type with CoW mesh references);
        // the snapshot renderer never observes or mutates the editor.
        let snapshot = viewModel().scene
        let snapshotRenderer = Renderer(context: context)
        return snapshotRenderer.makeSceneSnapshotPNG(
            snapshot, width: width, height: height)
    }
}
#endif

/// Explicit preview placeholder, used ONLY when the viewport renderer is
/// unavailable on this device: the canvas node still binds the editable
/// `.floecad` package instead of failing the creation. The image is deliberately
/// NOT a blank grey rectangle (which read as "an undecodable image") — it draws
/// an explicit cube glyph and a CAD label so a human can tell a real render is
/// unavailable from a genuine preview of an empty/unrenderable scene.
public enum CADCanvasPreview {
    public static func placeholderPNG(width: Int = 640, height: Int = 480) -> Data? {
        #if canImport(UIKit)
        let size = CGSize(width: max(width, 1), height: max(height, 1))
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            let rect = CGRect(origin: .zero, size: size)
            UIColor.secondarySystemFill.setFill()
            context.fill(rect)
            let stroke = UIColor.secondaryLabel.withAlphaComponent(0.55)
            // Rounded border keeps it distinct from a rasterized photo.
            let inset = rect.insetBy(dx: size.width * 0.08, dy: size.height * 0.10)
            let border = UIBezierPath(roundedRect: inset, cornerRadius: size.height * 0.06)
            border.lineWidth = max(2, size.height * 0.008)
            stroke.setStroke()
            border.stroke()
            // Explicit cube glyph, drawn as a wireframe isometric cube so the
            // placeholder reads as "3D CAD" without depending on SF Symbols in
            // an offscreen graphics context.
            let cx = rect.midX
            let glyphH = size.height * 0.30
            let glyphW = glyphH
            let topY = inset.minY + size.height * 0.10
            let s = glyphW * 0.5
            let front = CGRect(x: cx - s, y: topY + s * 0.6, width: s * 2, height: s * 2)
            let dx = s * 0.6, dy = -s * 0.6
            let glyph = UIBezierPath()
            glyph.lineWidth = max(2, size.height * 0.010)
            stroke.setStroke()
            // Front face
            glyph.move(to: front.origin)
            glyph.addLine(to: CGPoint(x: front.maxX, y: front.minY))
            glyph.addLine(to: CGPoint(x: front.maxX, y: front.maxY))
            glyph.addLine(to: CGPoint(x: front.minX, y: front.maxY))
            glyph.close()
            // Top + side edges
            let shifted = front.offsetBy(dx: dx, dy: dy)
            glyph.move(to: front.origin)
            glyph.addLine(to: shifted.origin)
            glyph.move(to: CGPoint(x: front.maxX, y: front.minY))
            glyph.addLine(to: CGPoint(x: shifted.maxX, y: shifted.minY))
            glyph.move(to: CGPoint(x: front.maxX, y: front.maxY))
            glyph.addLine(to: CGPoint(x: shifted.maxX, y: shifted.maxY))
            glyph.append(UIBezierPath(rect: shifted))
            glyph.stroke()
            // Explicit label.
            let label = "CAD"
            let font = UIFont.systemFont(ofSize: size.height * 0.11, weight: .semibold)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor.secondaryLabel,
            ]
            let textSize = label.size(withAttributes: attrs)
            let textPoint = CGPoint(x: cx - textSize.width / 2,
                                    y: front.maxY + size.height * 0.06)
            label.draw(at: textPoint, withAttributes: attrs)
        }.pngData()
        #else
        return nil
        #endif
    }
}
