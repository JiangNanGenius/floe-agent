// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import AVFoundation
@testable import FloeWorkbench

@Suite("M51 M52 native audio processing products", .serialized)
struct MediaAudioProcessingTests {
    func source(_ root:URL,amplitude:Float = 0.4) throws -> URL {
        let format = try #require(AVAudioFormat(commonFormat:.pcmFormatFloat32,sampleRate:48_000,channels:1,interleaved:false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat:format,frameCapacity:48_000));buffer.frameLength = 48_000
        for i in 0..<48_000 { buffer.floatChannelData![0][i] = amplitude*Float(sin(2*Double.pi*200*Double(i)/48_000)) + amplitude*0.5*Float(sin(2*Double.pi*5000*Double(i)/48_000)) }
        let path = root.appendingPathComponent("source-\(amplitude).wav")
        do { let file = try AVAudioFile(forWriting:path,settings:format.settings);try file.write(from:buffer) }
        return path
    }
    func mix(_ source:URL,root:URL,name:String,eq:[PreparedVideoEQBand] = [],dynamics:PreparedVideoDynamics? = nil,limiter:PreparedVideoLimiter? = nil) async throws -> [Float] {
        let id = UUID(),range = try PreparedVideoTimeRange(startSeconds:0,durationSeconds:1,timescale:600)
        let clip = PreparedVideoAudioClip(id:UUID(),assetID:id,timelineRange:range,sourceRange:range)
        let plan = try PreparedVideoPlan(id:.init(projectID:UUID(),revision:1),timeScale:600,frameRate:.init(numerator:30,denominator:1),duration:range.duration,canvas:.init(width:16,height:16),
            assets:[.init(id:id,url:source,kind:.audio,duration:range.duration)],visualTracks:[.init(id:UUID(),name:"Reference",clips:[.init(id:UUID(),content:.graphic(.init(shape:.rectangle,width:1,height:1,fillColor:.black)),timelineRange:range)])],
            audio:.init(tracks:[.init(id:UUID(),name:name,eqBands:eq,dynamics:dynamics,limiter:limiter,clips:[clip])]))
        let destination = root.appendingPathComponent(name+".wav")
        let receipt = try await PreparedVideoAudioMixer().mix(.init(plan:plan,window:.init(range:range,frameRate:plan.frameRate),sampleRate:48_000,channelCount:1,destination:destination))
        #expect(receipt.deliveredFrames == 48_000)
        let file = try AVAudioFile(forReading:destination)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat:file.processingFormat,frameCapacity:48_000));try file.read(into:buffer)
        if let path = ProcessInfo.processInfo.environment["FLOE_MEDIA_EXECUTION_EVIDENCE_DIR"] {
            let folder = URL(fileURLWithPath:path,isDirectory:true);try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
            try Data(contentsOf:destination).write(to:folder.appendingPathComponent(destination.lastPathComponent),options:.atomic)
        }
        return Array(UnsafeBufferPointer(start:buffer.floatChannelData![0],count:Int(buffer.frameLength)))
    }
    func amplitude(_ samples:[Float],frequency:Double) -> Double {
        var real = 0.0,imaginary = 0.0
        for i in 12_000..<36_000 { let angle = 2*Double.pi*frequency*Double(i)/48_000;real += Double(samples[i])*cos(angle);imaginary += Double(samples[i])*sin(angle) }
        return hypot(real,imaginary)/12_000
    }
    @Test func equalizerChangesMeasuredFrequencyContentInActualPCM() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("media-eq-\(UUID())");try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer { try? FileManager.default.removeItem(at:root) }
        let input = try source(root),plain = try await mix(input,root:root,name:"M51-original")
        let equalized = try await mix(input,root:root,name:"M51-equalized",eq:[.init(frequency:500,gain:-18,filter:.lowShelf)])
        #expect(amplitude(equalized,frequency:200)<amplitude(plain,frequency:200)*0.35)
        #expect(amplitude(equalized,frequency:5000)>amplitude(plain,frequency:5000)*0.8)
    }
    @Test func compressorAndNativePeakLimiterProduceActualBoundedPCM() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("media-dynamics-\(UUID())");try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true);defer { try? FileManager.default.removeItem(at:root) }
        let input = try source(root,amplitude:0.8),plain = try await mix(input,root:root,name:"M52-original")
        let compressed = try await mix(input,root:root,name:"M52-compressed",dynamics:.init(threshold:-30,headRoom:5))
        let limited = try await mix(input,root:root,name:"M52-limited",limiter:.init(ceilingDB:-6))
        func rms(_ s:[Float]) -> Double { sqrt(s[12_000..<36_000].reduce(0.0) { $0+Double($1*$1) }/24_000) }
        #expect(rms(compressed)<rms(plain)*0.65)
        #expect(limited.allSatisfy { $0.isFinite } && limited.map { abs($0) }.max()! <= 0.53)
        #expect(rms(limited)>0.1)
        let quiet = try source(root,amplitude:0.05),quietPlain = try await mix(quiet,root:root,name:"M52-quiet-original")
        let quietLimited = try await mix(quiet,root:root,name:"M52-quiet-limited",limiter:.init(ceilingDB:-6))
        #expect(abs(rms(quietLimited)-rms(quietPlain))<0.002)
    }
    @Test func audioProcessingPersistsUndoAndUsesIndependentClipEffectPaths() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("audio-fx-history-\(UUID())");defer { try? FileManager.default.removeItem(at:root) }
        let project = MediaProject(kind:.video,name:"Audio",canvas:.init(width:32,height:32,frameRate:30)),store = MediaProjectStore(directory:root),coordinator = MediaPreparedCoordinator(store:store)
        try await store.save(project);_ = try await coordinator.upgradeDocument(id:project.id)
        let asset = MediaAssetReference(kind:.audio,relativePath:"audio.wav",originalName:"Audio"),picture = MediaAssetReference(kind:.image,relativePath:"image.png",originalName:"Picture")
        let range = try MediaTimeRange(start:.init(value:0,timescale:600),duration:.init(value:600,timescale:600))
        let a = MediaPreparedClip(assetID:asset.id,timelineRange:range,sourceRange:range)
        var b = a;b.id = UUID()
        let track = MediaPreparedTrack(kind:.audio,name:"Audio",clips:[a,b])
        let visual = MediaPreparedTrack(kind:.visual,name:"Picture",clips:[.init(assetID:picture.id,timelineRange:range,sourceRange:range)])
        _ = try await coordinator.applyUserOperations([.init(action:.insertAsset(asset)),.init(action:.insertAsset(picture)),.init(action:.insertTrack(track:track,index:nil)),.init(action:.insertTrack(track:visual,index:nil))],to:project.id)
        let current = try await coordinator.loadDocument(id:project.id)
        var edited = try #require(current.trackGraph.clip(id:a.id)?.clip)
        edited.audioProcessing = .init(eqBands:[.init(frequency:80,gain:-6,filter:.lowShelf)],dynamics:.init(threshold:-20),limiter:.init(ceilingDB:-1))
        let commit = try await coordinator.applyUserOperations([.init(action:.replaceClip(trackID:track.id,clipID:a.id,expectedRevision:edited.revision,clip:edited))],to:project.id)
        let reopened = try await MediaPreparedCoordinator(store:MediaProjectStore(directory:root)).loadDocument(id:project.id)
        #expect(reopened.trackGraph.clip(id:a.id)?.clip.audioProcessing == edited.audioProcessing)
        let plan = try MediaPreparedVideoDocumentAdapter.resolve(reopened,assetURLs:[asset.id:root.appendingPathComponent("audio.wav"),picture.id:root.appendingPathComponent("image.png")])
        #expect(plan.audio.tracks.count == 2)
        #expect(plan.audio.tracks.first { $0.clips.contains { $0.id == a.id } }?.limiter?.ceilingDB == -1)
        #expect(plan.audio.tracks.first { $0.clips.contains { $0.id == b.id } }?.eqBands.isEmpty == true)
        _ = try await coordinator.undoGroup(commit.groupID,in:project.id)
        #expect(try await coordinator.loadDocument(id:project.id).trackGraph.clip(id:a.id)?.clip.audioProcessing == nil)
        _ = try await coordinator.redoGroup(commit.groupID,in:project.id)
        #expect(try await coordinator.loadDocument(id:project.id).trackGraph.clip(id:a.id)?.clip.audioProcessing == edited.audioProcessing)
        #expect(try JSONDecoder().decode(MediaPreparedClip.self,from:JSONEncoder().encode(a)).audioProcessing == nil)
        #expect(throws:MediaPreparedCoreError.self) { try MediaAudioProcessing(limiter:.init(attackTime:0)).validate() }
        let partial = try JSONDecoder().decode(MediaAudioProcessing.self,from:Data(#"{"eqBands":[{"frequency":1000,"gain":-3}],"dynamics":{"threshold":-18},"limiter":{"ceilingDB":-6}}"#.utf8))
        try partial.validate()
        #expect(partial.eqBands[0].bandwidth == 1 && partial.eqBands[0].filter == .parametric)
        #expect(partial.dynamics?.attackTime == 0.005 && partial.limiter?.attackTime == 0.001)
        do {
            _ = try JSONDecoder().decode(MediaAudioProcessing.self,from:Data(#"{"limiter":{"ceillingDB":-6}}"#.utf8))
            Issue.record("Misspelled limiter field was silently ignored")
        } catch DecodingError.dataCorrupted(let context) {
            #expect(context.codingPath.map(\.stringValue) == ["limiter","ceillingDB"])
        }

    }
}
