// SPDX-License-Identifier: MPL-2.0
import Foundation
import simd
import OCCTShim

/// Analytic lines/arcs/conics enter the existing OCCT wire/prism builder.
/// No offset/unfolder is approximated with a sampled display mesh.
nonisolated enum CADMechanicalKernel {
    struct Output {
        var handle: BRepHandle
        var history: ShapeAncestry
        var outer: Profile
        var holes: [Profile]
        var placement: Transform3D
        var suffix: String
    }
    static func build(_ definition: CADMechanicalDefinition, placement: Transform3D) throws -> [Output] {
        try definition.validate(); try CADMechanicalDefinition.validatePlacement(placement)
        guard OCCTKernel.useOCCTAsSourceOfTruth else { throw CADMechanicalFailure.invalid("The exact manufacturing kernel is unavailable.") }
        func prism(_ outer: Profile, _ holes: [Profile], _ length: Double,
                   _ frame: Transform3D, _ suffix: String) throws -> Output {
            let history = OCCTShapeHistory()
            guard let solid = OCCTKernel.extrudeShape(outerLoop:outer.loop,outerConic:OCCTKernel.ConicSpec(outer.kind),
                holes:holes.map { .init(loop:$0.loop,conic:OCCTKernel.ConicSpec($0.kind),segments:$0.segments) },
                zMin:0,zMax:length,origin:.zero,xAxis:SIMD3(1,0,0),yAxis:SIMD3(0,1,0),normal:SIMD3(0,0,1),
                outerSegments:outer.segments,history:history), solid.containsSolid else {
                throw CADMechanicalFailure.invalid("OCCT could not construct the exact manufacturing solid.")
            }
            let health = OCCTKernel.healthReportDictionary(for:solid,runBOPCheck:true)
            guard health["valid"] as? Bool == true,
                  (health["counts"] as? [String:Int])?["solids"] == 1,
                  health["openFreeWires"] as? Int == 0, health["closedFreeWires"] as? Int == 0,
                  OCCTKernel.volume(solid) > 1e-8 else {
                throw CADMechanicalFailure.invalid("The manufacturing solid failed its native closed-solid check.")
            }
            return Output(handle:solid,history:ShapeAncestry(history),outer:outer,holes:holes,placement:frame,suffix:suffix)
        }
        if let s = definition.sheet {
            let r = s.innerRadius.value, t = s.thickness.value, a = s.flangeA.value, b = s.flangeB.value
            let theta = s.bendDegrees.value * .pi / 180, center = SIMD2<Double>(0,r)
            func bend(_ radius: Double, _ angle: Double) -> SIMD2<Double> {
                center + SIMD2(sin(angle),-cos(angle)) * radius
            }
            let direction = SIMD2(cos(theta),sin(theta))
            let i0 = bend(r,0), i1 = bend(r,theta), o0 = bend(r+t,0), o1 = bend(r+t,theta)
            let il = i0 - SIMD2(a,0), ol = o0 - SIMD2(a,0), ie = i1 + direction*b, oe = o1 + direction*b
            let points = [il,ol,o0,o1,oe,ie,i1,i0]
            var segments: [Profile.Segment] = []
            for index in points.indices {
                let middle: SIMD2<Double>? = index == 2 ? bend(r+t,theta/2) : index == 6 ? bend(r,theta/2) : nil
                segments.append(.init(start:points[index],end:points[(index+1)%points.count],mid:middle))
            }
            let folded = Profile(loop:points,kind:.polygonal,sourceEntityIDs:[definition.id],segments:segments)
            let formed = try prism(folded,[],s.width.value,placement,FloeCADStrings.text("cad.mechanical.formedBody","Formed"))
            // A true curved wall is mandatory; reject a native polyline fallback.
            let radii = OCCTKernel.faceInfo(formed.handle).compactMap { info -> Double? in
                guard case let .cylindrical(radius)? = info.signature?.kind else { return nil }; return radius
            }
            guard radii.contains(where:{ abs($0-r) < 1e-7 }), radii.contains(where:{ abs($0-r-t) < 1e-7 }) else {
                throw CADMechanicalFailure.invalid("The bend did not retain both exact cylindrical surfaces.")
            }
            let expected = s.width.value * (t*(a+b) + theta*(r*t+t*t/2))
            guard abs(OCCTKernel.volume(formed.handle)-expected) <= max(1e-5,expected*1e-7) else {
                throw CADMechanicalFailure.invalid("The bend solid does not match its analytic section.")
            }
            let blank = rectangle(width:s.blankLength,depth:t,id:definition.id)
            var offset = Transform3D.identity
            offset.translation = SIMD3(max(a,r+t+b)+20,0,0)
            let flat = try prism(blank,[],s.width.value,placement.composed(onto:offset),FloeCADStrings.text("cad.mechanical.flatBody","Flat blank"))
            return [formed,flat]
        }
        return try definition.members.enumerated().map { index, m in
            let outer: Profile, holes: [Profile]
            switch m.profile {
            case .flatBar:
                outer = rectangle(width:m.width.value,depth:m.depth.value,id:m.id); holes = []
            case .rectangularTube:
                outer = rectangle(width:m.width.value,depth:m.depth.value,id:m.id)
                holes = [rectangle(width:m.width.value-2*m.wall.value,depth:m.depth.value-2*m.wall.value,
                    id:m.innerBoundaryID,origin:SIMD2(m.wall.value,m.wall.value))]
            case .roundBar:
                outer = circle(diameter:m.width.value,id:m.id); holes = []
            case .roundTube:
                outer = circle(diameter:m.width.value,id:m.id)
                holes = [circle(diameter:m.width.value-2*m.wall.value,id:m.innerBoundaryID)]
            }
            let output = try prism(outer,holes,m.length.value,placement.composed(onto:m.placement),FloeCADStrings.format("cad.mechanical.memberBody","Member %@",index+1))
            let expected = m.sectionArea*m.length.value
            guard abs(OCCTKernel.volume(output.handle)-expected) <= max(1e-5,expected*1e-7) else {
                throw CADMechanicalFailure.invalid("The stock solid does not match its analytic section.")
            }
            return output
        }
    }
    private static func rectangle(width: Double, depth: Double, id: UUID, origin: SIMD2<Double> = .zero) -> Profile {
        Profile(loop:[origin,origin+SIMD2(width,0),origin+SIMD2(width,depth),origin+SIMD2(0,depth)],
                kind:.polygonal,sourceEntityIDs:[id])
    }
    private static func circle(diameter: Double, id: UUID) -> Profile {
        let r = diameter/2
        return Profile(loop:(0..<64).map { let a = Double($0)*2*Double.pi/64; return SIMD2(cos(a)*r,sin(a)*r) },
                       kind:.circle(center:.zero,radius:r),sourceEntityIDs:[id])
    }
    /// Native planar end faces, not tessellation bounds or the stored length.
    static func measuredLength(_ solid: BRepHandle) throws -> Double {
        let ends = OCCTKernel.faceInfo(solid).filter {
            $0.signature?.kind == .planar && abs(abs($0.normal.z)-1) < 1e-8
        }.map(\.centroid.z)
        guard let lower = ends.min(), let upper = ends.max(), upper-lower > 1e-8 else {
            throw CADMechanicalFailure.invalid("The actual stock no longer has two perpendicular end planes.")
        }
        return upper-lower
    }
}
