// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import CoreGraphics
@testable import FloeWorkbench

@Suite("M15 real native Bezier boolean geometry",.serialized)
struct MediaNativeVectorGeometryTests {
    private let canvas=MediaCanvas(width:200,height:160)
    private func rectangle(_ x:Double,_ y:Double,_ w:Double,_ h:Double) -> MediaVectorSubpath {
        .init(points:[.init(point:.init(x:x,y:y)),.init(point:.init(x:x+w,y:y)),.init(point:.init(x:x+w,y:y+h)),.init(point:.init(x:x,y:y+h))],isClosed:true)
    }
    private func layer(_ shape:MediaVectorPath) -> MediaPreparedLayer { .init(name:"Shape",content:.vectorPaths(shape)) }
    private func absolute(_ packed:MediaPackedVector) throws -> CGPath {
        var transform=packed.canvasSpace.transform.cgAffineTransform
        return try #require(try MediaNativeVectorGeometry.cgPath(packed.path,canvas:packed.canvasSpace.referenceCanvas).copy(using:&transform))
    }
    @Test func fourOperationsUseActualFilledAreasNotBoundingBoxes() throws {
        let a=layer(.init(subpaths:[rectangle(0.1,0.1,0.5,0.5)])),b=layer(.init(subpaths:[rectangle(0.4,0.3,0.5,0.5)]))
        let doc=MediaPreparedDocument(id:UUID(),kind:.image,name:"Boolean",canvas:canvas,layers:[a,b])
        let locations=[CGPoint(x:30,y:130),CGPoint(x:100,y:90),CGPoint(x:170,y:50),CGPoint(x:190,y:10)]
        let expected:[MediaVectorBooleanOperation:[Bool]]=[.union:[true,true,true,false],.subtract:[true,false,false,false],.intersect:[false,true,false,false],.xor:[true,false,true,false]]
        for operation in MediaVectorBooleanOperation.allCases {
            let packed=try #require(try MediaNativeVectorGeometry.boolean([a.id,b.id],in:doc,operation:operation)),path=try absolute(packed)
            #expect(locations.map{path.contains($0)}==expected[operation])
        }
    }
    @Test func evenOddHolesAndCurvedBoundariesSurviveTheNativeOperation() throws {
        let ring=layer(.init(subpaths:[rectangle(0.1,0.1,0.8,0.8),rectangle(0.3,0.3,0.4,0.4)],fillRule:.evenOdd))
        let small=layer(.init(subpaths:[rectangle(0.45,0.45,0.1,0.1)]))
        let doc=MediaPreparedDocument(id:UUID(),kind:.image,name:"Holes",canvas:canvas,layers:[ring,small])
        let packed=try #require(try MediaNativeVectorGeometry.boolean([ring.id,small.id],in:doc,operation:.union)),path=try absolute(packed)
        #expect(path.contains(.init(x:100,y:80)) && !path.contains(.init(x:70,y:80)) && path.contains(.init(x:30,y:80)))
        let circle=CGPath(ellipseIn:.init(x:20,y:20,width:100,height:100),transform:nil)
        let vector=try #require(try MediaNativeVectorGeometry.packed(circle,canvas:canvas,fill:"#3366FF"))
        #expect(vector.path.subpaths.flatMap(\.points).contains{$0.controlIn != nil || $0.controlOut != nil})
        let restored=try absolute(vector)
        #expect(!restored.contains(.init(x:22,y:22)) && restored.contains(.init(x:70,y:70)))
    }
    @Test func packingRetainsActualOffCanvasGeometryAndClosingCurveControls() throws {
        let path=CGMutablePath();path.move(to:.init(x:-30,y:40));path.addCurve(to:.init(x:40,y:40),control1:.init(x:-20,y:110),control2:.init(x:30,y:110));path.closeSubpath()
        let packed=try #require(try MediaNativeVectorGeometry.packed(path,canvas:canvas,fill:"#FF0000")),restored=try absolute(packed)
        #expect(abs(restored.boundingBox.minX-path.boundingBox.minX)<1e-8 && abs(restored.boundingBox.maxY-path.boundingBox.maxY)<1e-8)
        #expect(packed.path.subpaths.flatMap(\.points).allSatisfy{(0...1).contains($0.point.x) && (0...1).contains($0.point.y)})
        let closed=MediaVectorPath(subpaths:[.init(points:[.init(point:.init(x:0.2,y:0.2),controlIn:.init(x:0,y:0.5)),.init(point:.init(x:0.8,y:0.2),controlOut:.init(x:1,y:0.5))],isClosed:true)])
        let actual=try MediaNativeVectorGeometry.cgPath(closed,canvas:canvas)
        #expect(actual.contains(.init(x:100,y:105)))
    }
    @Test func transformedPathsUseTheRealCanvasSpaceAndDisjointIntersectionIsTrulyEmpty() throws {
        var a=layer(.init(subpaths:[rectangle(0.1,0.1,0.2,0.2)])),b=layer(.init(subpaths:[rectangle(0.7,0.7,0.1,0.1)]))
        a.canvasSpace = .init(referenceCanvas:canvas,transform:.init(a:1,d:1,tx:20,ty:-10))
        let doc=MediaPreparedDocument(id:UUID(),kind:.image,name:"Placed",canvas:canvas,layers:[a,b])
        let path=try MediaNativeVectorGeometry.placedPath(a,in:doc)
        #expect(path.contains(.init(x:50,y:120)) && !path.contains(.init(x:25,y:130)))
        #expect(try MediaNativeVectorGeometry.boolean([a.id,b.id],in:doc,operation:.intersect)==nil)
        var locked=doc;locked.layers[0].isLocked=true
        #expect(throws:(any Error).self) { try MediaNativeVectorGeometry.boolean([a.id,b.id],in:locked,operation:.union) }
        var masked=doc;masked.layers[0].mask = .init(vector:.init(inverted:true))
        #expect(throws:(any Error).self) { try MediaNativeVectorGeometry.boolean([a.id,b.id],in:masked,operation:.union) }
    }
}
