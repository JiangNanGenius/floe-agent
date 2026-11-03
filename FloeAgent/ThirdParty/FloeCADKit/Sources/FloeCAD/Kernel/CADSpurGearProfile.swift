// SPDX-License-Identifier: Apache-2.0 AND MIT
// The single-spur dimensional/root-arc definition is adapted from cq_gears
// e73874cf17a25447a99b1e7c22a4d5af38560e9c, spur_gear.py (meadiode, 2021).
// The involute-as-native-Bezier mapping follows RopleyIT/InvoluteGears
// 944b15b44639a954ccbd73241284879ae2f9fcef (Ropley Information Technology Ltd., 2020).
// Adaptations: straight teeth only; endpoint/tangent-exact Hermite subdivision
// with a conservative analytic remainder, native circular arcs, no Python/OCP.
// Complete retained notices are embedded in CADSpurGearAttribution and shown
// in the Parts panel. BRep curves are exact Beziers; their involute is APPROXIMATE.
import Foundation
import simd
import CryptoKit

nonisolated enum CADSpurGearProfile {
    struct Built {
        var outer: Profile
        var holes: [Profile]
        var flankSegments: Int
        var flankErrorBound: Double
        var baseJoinDisplacement: Double
        var firstToothFlankOrdinals: [Int]
    }
    static func build(_ s: CADSpurGearSpec, identity: UUID) throws -> Built {
        try s.validate()
        let rb = s.baseRadius, ra = s.tipRadius, rd = s.rootRadius
        let pitch = 2 * Double.pi / Double(s.teeth)
        let phase = .pi / (2 * Double(s.teeth)) + tan(s.pressureRadians) - s.pressureRadians
        let upper = sqrt(max(0,ra*ra/(rb*rb)-1))
        let lower = sqrt(max(0,max(rb,rd)*max(rb,rd)/(rb*rb)-1))
        func raw(_ u: Double) -> SIMD2<Double> { rb * SIMD2(cos(u)+u*sin(u),sin(u)-u*cos(u)) }
        // The upstream Bezier implementation also avoids the zero-speed
        // base endpoint. Bound that local transition rather than hiding it.
        var start = lower
        if start == 0 {
            start = min(0.01*upper,sqrt(s.maximumDeviation.value/(32*rb)))
            while simd_distance(raw(start),raw(0)) > s.maximumDeviation.value/8 { start /= 2 }
        }
        let displacement = simd_distance(raw(start),raw(lower))
        let span = upper-start
        let fourthDerivativeBound = rb*sqrt(9+upper*upper)
        let roundoff = rb*1e-12 + 1e-10
        var pieces = 1, level = 0
        func valueBound(_ h: Double) -> Double { sqrt(2)*fourthDerivativeBound*pow(h,4)/384 + roundoff }
        // Conservative derivative bound: Taylor remainder + both right-end
        // Hermite corrections <= (19/48) M4*h^3; use 1/2 for roundoff margin.
        let derivativeBudget = rb*tan(s.pressureRadians)*sin(0.05 * .pi/180)
        while valueBound(span/Double(pieces)) > s.maximumDeviation.value/4
                || 0.5*fourthDerivativeBound*pow(span/Double(pieces),3) > derivativeBudget {
            pieces *= 2; level += 1
            guard pieces <= 32 else { throw CADMechanicalFailure.invalid("The requested spur tolerance exceeds this backend's bounded profile budget.") }
        }
        guard (2*pieces+2)*s.teeth <= 4096 else { throw CADMechanicalFailure.invalid("The spur profile exceeds its bounded native edge budget.") }
        let c = cos(phase), q = sin(phase)
        func left(_ u: Double) -> SIMD2<Double> {
            let p = raw(u); return SIMD2(c*p.x+q*p.y,q*p.x-c*p.y)
        }
        func derivative(_ u: Double) -> SIMD2<Double> {
            let p = rb*u*SIMD2(cos(u),sin(u)); return SIMD2(c*p.x+q*p.y,q*p.x-c*p.y)
        }
        func rotate(_ p: SIMD2<Double>, _ a: Double) -> SIMD2<Double> {
            SIMD2(cos(a)*p.x-sin(a)*p.y,sin(a)*p.x+cos(a)*p.y)
        }
        func mirror(_ p: SIMD2<Double>) -> SIMD2<Double> { SIMD2(p.x,-p.y) }
        var cubics: [[SIMD2<Double>]] = []
        for i in 0..<pieces {
            let a = start+span*Double(i)/Double(pieces), b = start+span*Double(i+1)/Double(pieces), h = b-a
            // Cubic Hermite is represented exactly as four Bezier poles.
            cubics.append([left(a),left(a)+derivative(a)*(h/3),left(b)-derivative(b)*(h/3),left(b)])
        }
        let rootLeft = left(start), tipLeft = left(upper)
        guard atan2(tipLeft.y,tipLeft.x) > 1e-9, pitch-2*atan2(rootLeft.y,rootLeft.x) > 1e-9 else {
            throw CADMechanicalFailure.invalid("The requested spur has no positive tip or root gap.")
        }
        var segments: [Profile.Segment] = [], identities: [UUID] = [], ordinals: [Int] = []
        func append(_ segment: Profile.Segment, _ key: String, flank: Bool) {
            segments.append(segment); identities.append(boundaryID(identity,key))
            if flank && key.hasPrefix("tooth.0.") { ordinals.append(segments.count) }
        }
        for tooth in 0..<s.teeth {
            let angle = Double(tooth)*pitch, key = "tooth.\(tooth)."
            // CCW boundary: right root→tip, tip arc, left tip→root, gap arc.
            for i in 0..<pieces {
                let poles = cubics[i].map { rotate(mirror($0),angle) }
                append(.init(start:poles[0],end:poles[3],bezierPoles:poles),key+"right.\(level).\(i)",flank:true)
            }
            append(.init(start:rotate(mirror(tipLeft),angle),end:rotate(tipLeft,angle),
                mid:rotate(SIMD2(ra,0),angle)),key+"tip",flank:false)
            for i in (0..<pieces).reversed() {
                let poles = cubics[i].reversed().map { rotate($0,angle) }
                append(.init(start:poles[0],end:poles[3],bezierPoles:poles),key+"left.\(level).\(i)",flank:true)
            }
            append(.init(start:rotate(rootLeft,angle),end:rotate(mirror(rootLeft),angle+pitch),
                mid:rotate(SIMD2(rd*cos(pitch/2),rd*sin(pitch/2)),angle)),key+"root",flank:false)
        }
        let outer = Profile(loop:segments.map(\.start),kind:.polygonal,sourceEntityIDs:Set(identities),
            segments:segments,segmentEntityIDs:identities)
        let holes: [Profile]
        if s.boreDiameter.value > 0 {
            let r = s.boreDiameter.value/2
            holes = [Profile(loop:(0..<64).map { let a=Double($0)*2*Double.pi/64; return SIMD2(r*cos(a),r*sin(a)) },
                kind:.circle(center:.zero,radius:r),sourceEntityIDs:[boundaryID(identity,"bore")])]
        } else { holes = [] }
        return Built(outer:outer,holes:holes,flankSegments:pieces,flankErrorBound:valueBound(span/Double(pieces)),
            baseJoinDisplacement:displacement,firstToothFlankOrdinals:ordinals)
    }
    // Authored construction role/normalized interval, independent of native
    // face indices and tessellation. A subdivision-level change retires the
    // prior interval identity rather than silently retargeting a sibling.
    static func boundaryID(_ namespace: UUID, _ role: String) -> UUID {
        var bytes = Array(SHA256.hash(data:Data(("FloeCAD.SpurBoundary.v1|"+namespace.uuidString+"|"+role).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80; bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid:(bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }
}
