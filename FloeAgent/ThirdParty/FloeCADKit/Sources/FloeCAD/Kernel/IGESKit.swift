//
//  IGESKit.swift
//  FloeCADKit
//
//  IGES interchange (spec §12.1 / §12.2), the document-level layer on top of
//  `OCCTKernel.readIGES` / `OCCTKernel.writeIGES`.
//
//  IGES is a SURFACE exchange: a file routinely carries closed solids, open
//  shells or isolated faces. This kit preserves the distinction the kernel
//  reader already makes rather than flattening everything to one class:
//
//    * a root containing a solid is imported through `STEPKit.body` and keeps
//      `Body.brep` (the existing exact-solid path);
//    * a shell/face root is imported as `Body.surfaceBRep`, which renders from
//      the exact shape and exports back to IGES, but is deliberately NOT
//      `Body.brep`, so solid-only boolean/fillet/shell/STEP paths never accept
//      it by mistake.
//
//  Export writes every body that owns an exact shape (solid or open surface)
//  through OCCT's IGES BRep writer, in millimetres, baking `Body.transform`
//  exactly like STEPKit does. A mesh-only body is skipped and named; no mesh
//  is ever substituted into a file whose point is exact geometry.
//
//  Units: the model unit is millimetres and the bridge writes "MM", so no
//  scaling happens on either side.
//

import Foundation

nonisolated enum IGESKit {

    /// What `export(bodies:)` managed to do.
    enum ExportOutcome: Equatable {
        /// At least one exact body was written. `skipped` names mesh-only (or
        /// untransformable) bodies left out, so the caller can state the loss.
        case success(Data, skipped: [String])
        /// There were bodies, but none carried an exact B-rep solid/surface.
        case nothingAnalytic(skipped: [String])
        /// OCCT refused the transfer, or the staged temp file could not be written.
        case failed
    }

    /// Write every body with an exact B-rep (solid or open shell/face) to an
    /// IGES file and return its bytes.
    ///
    /// Each body's `transform` is baked first: the exact handle lives in the
    /// same body-local space as the render mesh, and IGES roots have no
    /// per-body placement record to carry it, so a moved body must be written
    /// where the user actually sees it.
    static func export(bodies: [Body]) -> ExportOutcome {
        var shapes: [BRepHandle] = []
        var skipped: [String] = []
        for body in bodies {
            // A body is one or the other; prefer the solid if a future path
            // ever leaves both populated.
            guard let brep = body.brep ?? body.surfaceBRep,
                  let placed = OCCTKernel.transformed(brep, by: body.transform) else {
                skipped.append(body.name)
                continue
            }
            shapes.append(placed)
        }
        guard !shapes.isEmpty else { return .nothingAnalytic(skipped: skipped) }

        // OCCT writes to a path, so stage a temp file and read it back.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-iges-\(UUID().uuidString)")
            .appendingPathExtension("igs")
        defer { try? FileManager.default.removeItem(at: url) }
        guard OCCTKernel.writeIGES(shapes, to: url),
              let data = try? Data(contentsOf: url),
              !data.isEmpty else { return .failed }
        return .success(data, skipped: skipped)
    }

    /// Turn one imported open surface root into a real body. Nil when the
    /// shape contains a solid (wrong classification — caller must use the
    /// solid path) or cannot be tessellated; half a surface body is worse
    /// than an honest refusal.
    static func surfaceBody(from handle: BRepHandle, name: String,
                            revision: UInt64) -> Body? {
        var body = Body(
            id: BodyID(), name: name, transform: .identity, primitive: nil,
            render: RenderMesh(positions: [], normals: [], indices: []),
            revision: revision)
        guard body.adoptSurfaceBRep(handle) else { return nil }
        return body
    }
}
