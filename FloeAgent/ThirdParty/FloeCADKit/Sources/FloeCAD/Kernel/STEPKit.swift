//
//  STEPKit.swift
//  openshape3d
//
//  STEP AP214 interchange (spec §12.1 / §12.2), the document-level layer on
//  top of `OCCTKernel.writeSTEP` / `readSTEP`.
//
//  STEP is the odd one out among our formats. STL/OBJ/3MF/GLB export
//  TRIANGLES — a cylinder leaves as a many-sided prism and can never come
//  back round. STEP carries the EXACT B-rep, so an analytic cylinder is still
//  a cylinder in the CAD tool that opens it, and a STEP file we import stays
//  analytic here: its solids become `Body.brep`, which is what lets fillet,
//  shell and boolean run on the OCCT path afterwards.
//
//  That exactness is also the one limit worth stating plainly: a body with no
//  `brep` (an imported STL, anything the mesh path built) has no analytic
//  geometry to write, so it is SKIPPED rather than silently triangulated into
//  a file whose whole point is that it is not triangles. Callers surface the
//  skipped names.
//
//  Units: our model unit is mm and OCCT reads/writes STEP in mm by default,
//  so no scaling happens on either side.
//

import Foundation

nonisolated enum STEPKit {

    /// What `export(bodies:)` managed to do. `skipped` names the mesh-only
    /// bodies left out, in every case, so the UI can say which ones.
    enum ExportOutcome: Equatable {
        /// At least one solid was written. `skipped` may still be non-empty —
        /// a partial export is a success with a caveat, not a failure.
        case success(Data, skipped: [String])
        /// There were bodies, but not one of them carried a B-rep.
        case nothingAnalytic(skipped: [String])
        /// OCCT refused the transfer, or the file could not be read back.
        case failed
    }

    /// Write every analytic body to a STEP file and hand back its bytes.
    ///
    /// Each body's `transform` is baked in first: a `brep` lives in the same
    /// body-local space as its render mesh, and the flat STEP we write has no
    /// per-solid placement to carry it, so a body that was moved must be
    /// written where the user actually sees it.
    static func export(bodies: [Body]) -> ExportOutcome {
        var solids: [BRepHandle] = []
        var skipped: [String] = []
        for body in bodies {
            guard let brep = body.brep,
                  let placed = OCCTKernel.transformed(brep, by: body.transform) else {
                skipped.append(body.name)
                continue
            }
            solids.append(placed)
        }
        guard !solids.isEmpty else { return .nothingAnalytic(skipped: skipped) }

        // OCCT writes to a path, so stage a temp file and read it back.
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("os3d-step-\(UUID().uuidString)")
            .appendingPathExtension("step")
        defer { try? FileManager.default.removeItem(at: url) }
        guard OCCTKernel.writeSTEP(solids, to: url),
              let data = try? Data(contentsOf: url) else { return .failed }
        return .success(data, skipped: skipped)
    }

    /// Solids in a STEP payload. Empty when the bytes are not a readable STEP
    /// file or carry no solid — the caller reports that as one recoverable
    /// import error either way, since neither gives us anything to place.
    static func solids(from data: Data) -> [BRepHandle] {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("os3d-step-in-\(UUID().uuidString)")
            .appendingPathExtension("step")
        defer { try? FileManager.default.removeItem(at: url) }
        guard (try? data.write(to: url)) != nil else { return [] }
        return OCCTKernel.readSTEP(from: url)
    }

    /// Turn one imported solid into a body. Identity transform with the solid
    /// left where the file put it, matching how the extrude/primitive paths
    /// build B-rep bodies. Nil when the solid will not tessellate — a STEP
    /// file can hold a shape OCCT reads but cannot mesh, and half a body is
    /// worse than none.
    static func body(from handle: BRepHandle, name: String, revision: UInt64) -> Body? {
        var body = Body(
            id: BodyID(), name: name, transform: .identity, primitive: nil,
            render: RenderMesh(positions: [], normals: [], indices: []),
            revision: revision)
        guard body.adoptBRep(handle) else { return nil }
        return body
    }
}
