// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import AVFoundation
@testable import FloeWorkbench

@Suite("Prepared video retimed source audio", .serialized)
struct MediaRetimedAudioTests {
    @Test func sourceRateProducesActualFastAndSlowPCMWithExactTimelineDuration() async throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("media-retime-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer{try? FileManager.default.removeItem(at:root)}
        let format=try #require(AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:48_000,channels:1,interleaved:false))
        let buffer=try #require(AVAudioPCMBuffer(pcmFormat:format,frameCapacity:48_000));buffer.frameLength=48_000
        for i in 0..<48_000{buffer.floatChannelData![0][i]=Float(i)/48_000*0.4}
        let source=root.appendingPathComponent("source.wav")
        do{let file=try AVAudioFile(forWriting:source,settings:format.settings);try file.write(from:buffer)}
        for speed in [0.5,1.0,2.0] {
            let seconds=1/speed,id=UUID(),range=try PreparedVideoTimeRange(startSeconds:0,durationSeconds:seconds,timescale:600)
            let clip=PreparedVideoAudioClip(id:UUID(),assetID:id,timelineRange:range,sourceRange:try .init(startSeconds:0,durationSeconds:1,timescale:600),speed:speed)
            let plan=try PreparedVideoPlan(id:.init(projectID:UUID(),revision:1),timeScale:600,frameRate:.init(numerator:30,denominator:1),duration:.init(seconds:seconds,timescale:600),canvas:.init(width:16,height:16),assets:[.init(id:id,url:source,kind:.audio,duration:try .init(seconds:1,timescale:600))],visualTracks:[.init(id:UUID(),name:"Solid reference",clips:[.init(id:UUID(),content:.graphic(.init(shape:.rectangle,width:1,height:1,fillColor:.black)),timelineRange:range)])],audio:.init(tracks:[.init(id:UUID(),name:"Source",clips:[clip])]))
            let window=try PreparedVideoFrameWindow(range:range,frameRate:plan.frameRate)
            let destination=root.appendingPathComponent("rate-\(speed).wav")
            let receipt=try await PreparedVideoAudioMixer().mix(.init(plan:plan,window:window,sampleRate:48_000,channelCount:1,destination:destination))
            let expected=Int(seconds*48_000)
            #expect(receipt.deliveredFrames==expected && abs(receipt.durationSeconds-seconds)<0.00001)
            let output=try AVAudioFile(forReading:destination)
            #expect(output.length==AVAudioFramePosition(expected))
            let result=try #require(AVAudioPCMBuffer(pcmFormat:output.processingFormat,frameCapacity:AVAudioFrameCount(expected)));try output.read(into:result)
            for fraction in [0.2,0.4,0.7] {
                let frame=Int(Double(expected)*fraction),actual=result.floatChannelData![0][frame]
                #expect(abs(actual-Float(fraction)*0.4)<0.015,"Wrong source mapping at speed \(speed), frame \(frame): \(actual)")
            }
            if let evidence=ProcessInfo.processInfo.environment["FLOE_MEDIA_EXECUTION_EVIDENCE_DIR"] {
                let folder=URL(fileURLWithPath:evidence,isDirectory:true);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
                try Data(contentsOf:destination).write(to:folder.appendingPathComponent(destination.lastPathComponent),options:.atomic)
            }
        }
    }
    @Test func oldAudioClipJSONRetainsOneXAndInvalidRatesAreRejected() throws {
        let range=try PreparedVideoTimeRange(startSeconds:0,durationSeconds:1,timescale:600),id=UUID()
        let legacy=PreparedVideoAudioClip(id:UUID(),assetID:id,timelineRange:range,sourceRange:range)
        let reopened=try JSONDecoder().decode(PreparedVideoAudioClip.self,from:JSONEncoder().encode(legacy))
        #expect(reopened.speed==nil)
        for speed in [0,Double.infinity,17] {
            #expect(throws:PreparedVideoError.self){try PreparedVideoPlan(id:.init(projectID:UUID(),revision:1),timeScale:600,frameRate:.init(numerator:30,denominator:1),duration:.init(seconds:1,timescale:600),canvas:.init(width:16,height:16),assets:[.init(id:id,url:URL(fileURLWithPath:"/unresolved.wav"),kind:.audio,duration:try .init(seconds:1,timescale:600))],visualTracks:[.init(id:UUID(),name:"Solid reference",clips:[.init(id:UUID(),content:.graphic(.init(shape:.rectangle,width:1,height:1,fillColor:.black)),timelineRange:range)])],audio:.init(tracks:[.init(id:UUID(),name:"Source",clips:[.init(id:UUID(),assetID:id,timelineRange:range,sourceRange:range,speed:speed)])]))}
        }
    }
}
