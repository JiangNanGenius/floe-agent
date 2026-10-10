//
//  BooleanCandidacy.swift
//  openshape3d
//
//  Which bodies the tool commit may run mesh CSG against. Found 2026-09-05
//  with a LiDAR room scan (102,749 open triangles): Extrude's automatic
//  boolean scan intersected the tool with EVERY body to decide union vs
//  subtract, then unioned into the scan and made it watertight — well over
//  a minute on the main thread, which a device's watchdog reports as a
//  crash. Analytic (B-rep) bodies are always candidates; a mesh-only body is
//  one only while it is small enough for Euclid's BSP CSG to finish in a
//  blink. Anything heavier is scenery: Auto makes a new body next to it and
//  an explicit boolean against it is refused with a message.
//

import Foundation

nonisolated enum BooleanCandidacy {
    /// Mesh-only bodies above this many triangles never enter a CSG.
    static let meshTriangleCap = 50_000

    static func allows(_ body: Body) -> Bool {
        body.brep != nil || body.render.triangleCount <= meshTriangleCap
    }

    static func heavyBodies(in bodies: [Body]) -> [Body] {
        bodies.filter { !allows($0) }
    }

    static func refusalMessage(for body: Body) -> String {
        let count = body.render.triangleCount.formatted()
        return "“\(body.name)” is an imported mesh with \(count) triangles — too heavy for a "
            + "boolean. Choose New Body to build next to it, or simplify the mesh before importing."
    }
}
