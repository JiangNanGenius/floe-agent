// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import CoreGraphics
import CoreImage
@testable import FloeWorkbench

@Suite("M48 native frame scope measurements")
struct MediaVideoScopesTests {
    func image(width:Int,height:Int,pixels:[UInt8]) throws -> CGImage {
        let provider = try #require(CGDataProvider(data:Data(pixels) as CFData))
        let colorSpace = try #require(CGColorSpace(name:CGColorSpace.sRGB))
        return try #require(CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,
            space:colorSpace,bitmapInfo:.init(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent))
    }
    @Test func knownCodeValuesProduceExactWaveformAndChromaBins() throws {
        let pixels: [UInt8] = [0,0,0,255, 0,0,0,255, 255,255,255,255, 255,255,255,255]
        let input = try image(width:4,height:1,pixels:pixels)
        let snapshot = try MediaVideoScopeSnapshot.measure(input,documentID:UUID(),revision:4,timelineSeconds:0.25)
        #expect(snapshot.sampledPixels == 4 && snapshot.waveform.count == 8192 && snapshot.vectorscope.count == 4096)
        #expect(snapshot.waveform[0] == 1 && snapshot.waveform[16] == 1)
        #expect(snapshot.waveform[127*64+32] == 1 && snapshot.waveform[127*64+48] == 1)
        #expect(snapshot.vectorscope[32*64+32] == 4)
        let alpha = try image(width:2,height:1,pixels:[128,0,0,128, 0,0,0,0])
        let red = try MediaVideoScopeSnapshot.measure(alpha,documentID:UUID(),revision:0,timelineSeconds:0)
        #expect(red.sampledPixels == 1 && red.waveform[27*64] == 1)
        #expect(red.vectorscope[63*64+24] == 1)
        #expect(red.waveform.reduce(0,+) == 1 && red.vectorscope.reduce(0,+) == 1)
    }
    @Test func actualRenderedFrameHasBoundedDurableStructuredMeasurements() async throws {
        let rate = try PreparedVideoFrameRate(numerator:30,denominator:1)
        let range = try PreparedVideoTimeRange(startSeconds:0,durationSeconds:1,timescale:600)
        let plan = try PreparedVideoPlan(id:.init(projectID:UUID(),revision:9),timeScale:600,frameRate:rate,duration:range.duration,
            canvas:.init(width:1024,height:512),assets:[],visualTracks:[.init(id:UUID(),name:"Native red",clips:[
                .init(id:UUID(),content:.graphic(.init(shape:.rectangle,width:1,height:1,fillColor:try .init(hex:"#FF0000"))),timelineRange:range)])])
        let frame = try await PreparedVideoFrameRenderer().renderFrame(plan:plan,frameIndex:10,settings:.init(width:1024,height:512,frameRate:rate))
        let snapshot = try MediaVideoScopeSnapshot.measure(frame.image,documentID:plan.id.projectID,revision:plan.id.revision,timelineSeconds:frame.time.seconds)
        #expect(snapshot.sampleWidth == 256 && snapshot.sampleHeight == 128 && snapshot.sampledPixels == 32768)
        #expect(snapshot.vectorscope[63*64+24] == 32768)
        #expect(snapshot.waveform.reduce(0,+) == UInt32(snapshot.sampledPixels))
        let json = try JSONEncoder().encode(snapshot)
        #expect(json.count < 128*1024)
        #expect(try JSONDecoder().decode(MediaVideoScopeSnapshot.self,from:json) == snapshot)
        if let dir = ProcessInfo.processInfo.environment["FLOE_MEDIA_EXECUTION_EVIDENCE_DIR"] {
            let root = URL(fileURLWithPath:dir,isDirectory:true);try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            try json.write(to:root.appendingPathComponent("M48-scopes.json"),options:.atomic)
            try #require(WorkbenchPNG.encode(frame.image)).write(to:root.appendingPathComponent("M48-source-frame.png"),options:.atomic)
        }
        #expect(throws:MediaPreparedCoreError.self) { try MediaVideoScopeSnapshot.measure(frame.image,documentID:UUID(),revision:0,timelineSeconds:Double.nan) }
    }
}
