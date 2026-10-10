//
//  STLExporter.swift
//  openshape3d
//
//  Binary STL export. Transforms are baked into world space and all bodies
//  merge into one file. Convention: 1 model unit = 1 mm (STL is unitless;
//  slicers assume mm).
//

import Foundation
import Euclid

nonisolated enum STLExporter {
    static func binarySTL(bodies: [Body]) -> Data {
        var polygons = [Euclid.Polygon]()
        for body in bodies {
            let world = body.euclidMesh().transformed(by: body.transform.euclid)
            polygons.append(contentsOf: EuclidBridge.triangles(of: world))
        }
        return Euclid.Mesh(polygons).stlData()
    }
}
