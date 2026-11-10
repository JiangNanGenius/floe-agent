// SPDX-License-Identifier: MPL-2.0
import Foundation
import AVFoundation
import CoreMedia
import CryptoKit

/// Service-owned native renderer. It never replaces a saved proxy or edits a
/// document; the caller admits its verified result through the root coordinator.
public actor MediaPreparedCompoundProxyRenderer {
    public struct Limits:Sendable {
        public var maximumDurationSeconds:Double
        public var maximumPixels:Int
        public init(maximumDurationSeconds:Double=600,maximumPixels:Int=8_294_400) { self.maximumDurationSeconds=maximumDurationSeconds;self.maximumPixels=maximumPixels }
    }
    private var activeExports:[UUID:AVAssetExportSession]=[:]
    private let limits:Limits
    private let exporter=PreparedVideoExporter()
    private let mixer=PreparedVideoAudioMixer()
    public init(limits:Limits = .init()) { self.limits=limits }

    public func render(source:MediaPreparedDocument,assetURLs:[UUID:URL],rootURL:URL,minimumDurationSeconds:Double=0,cancellation:PreparedVideoCancellation,progress:@Sendable(Double)->Void={_ in}) async throws -> MediaPreparedCompoundProxy {
        try cancellation.check();try Task.checkCancellation()
        let root=rootURL.standardizedFileURL.resolvingSymlinksInPath()
        guard root.isFileURL,let canvas=source.canvas,canvas.width*canvas.height<=limits.maximumPixels else { throw PreparedVideoError.invalidPlan("compound canvas is outside the native proxy bound") }
        // Until the separately developed HDR-alpha encoding path is actually
        // qualified, refuse it rather than secretly baking an SDR proxy.
        if let fields=try JSONSerialization.jsonObject(with:JSONEncoder().encode(canvas)) as? [String:Any],let profile=fields["videoColorProfile"],!(profile is NSNull),profile as? String != "rec709" { throw PreparedVideoError.unsupportedCapability("HDR/color-profile transparent proxies require a compatible native encoder; keep editing or restore the source clips") }
        let pinned=try await pinAssets(source:source,assetURLs:assetURLs,root:root,cancellation:cancellation)
        var plan=try await renderPlan(source:source,assetURLs:assetURLs,cancellation:cancellation)
        let duration=max(source.trackGraph.totalDurationSeconds,minimumDurationSeconds)
        guard duration>0,duration.isFinite,duration<=limits.maximumDurationSeconds else { throw PreparedVideoError.cacheLimitExceeded("compound proxy duration exceeds the native bound") }
        let frames=Int64((duration*plan.frameRate.fps).rounded(.up))
        plan.duration=try plan.frameRate.time(forFrame:frames,timescale:plan.timeScale)
        plan.canvas.backgroundColor = .clear
        let settings=try PreparedVideoOutputSettings(width:(canvas.width+1)/2*2,height:(canvas.height+1)/2*2,frameRate:plan.frameRate,codec:.hevc,quality:0.95,preservesAlpha:true)
        let directory=root.appendingPathComponent("Assets/Compound-\(UUID().uuidString)",isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        var accepted=false
        defer { if !accepted { try? FileManager.default.removeItem(at:directory) } }
        let video=directory.appendingPathComponent("proxy.mov"),audio=directory.appendingPathComponent("proxy.wav")
        let chunkFrames=max(Int64(1),Int64((plan.frameRate.fps*10).rounded(.down)))
        var segments:[URL]=[]
        let format=AVAudioFormat(standardFormatWithSampleRate:48_000,channels:2)!
        var audioOutput:AVAudioFile?=try AVAudioFile(forWriting:audio,settings:format.settings,commonFormat:.pcmFormatFloat32,interleaved:false)
        var deliveredFrames:Int64=0
        var start:Int64=0
        while start<frames {
            try cancellation.check();try Task.checkCancellation()
            let end=min(frames,start+chunkFrames),window=try PreparedVideoFrameWindow(startFrame:start,endFrame:end,frameRate:plan.frameRate,timescale:plan.timeScale)
            let segment=directory.appendingPathComponent("segment-\(segments.count).mov")
            var silent=plan;silent.audio = .init()
            _ = try await exporter.renderWindow(plan:silent,window:window,settings:settings,destination:segment,overwrite:false,cancellation:cancellation,progress:{ _ in })
            segments.append(segment)
            let wav=directory.appendingPathComponent("audio-window.wav")
            if PreparedVideoAudioMixer.hasAudibleContent(plan:plan,window:window) {
                _ = try await mixer.mix(.init(plan:plan,window:window,sampleRate:48_000,channelCount:2,destination:wav,overwrite:true,tailFrames:0),cancellation:cancellation)
                let input=try AVAudioFile(forReading:wav,commonFormat:.pcmFormatFloat32,interleaved:false)
                guard input.processingFormat == format else { throw PreparedVideoError.audioFailure("compound audio format changed between windows") }
                let pcm=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:16_384)!
                while input.framePosition<input.length {
                    try cancellation.check();try Task.checkCancellation();try input.read(into:pcm,frameCount:AVAudioFrameCount(min(16_384,input.length-input.framePosition)))
                    guard pcm.frameLength>0 else { throw PreparedVideoError.audioFailure("compound audio read stopped early") }
                    try audioOutput!.write(from:pcm);deliveredFrames += Int64(pcm.frameLength)
                }
                try FileManager.default.removeItem(at:wav)
            } else {
                // The existing mixer correctly rejects an empty audible set.
                // A compound still needs an aligned silent proxy (including
                // gaps after an inner trim), written in bounded PCM chunks.
                let pcm=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:16_384)!
                for channel in 0..<Int(format.channelCount) { pcm.floatChannelData![channel].initialize(repeating:0,count:16_384) }
                var remaining=Int64((window.durationSeconds*48_000).rounded())
                while remaining>0 { try cancellation.check();try Task.checkCancellation();pcm.frameLength=AVAudioFrameCount(min(remaining,16_384));try audioOutput!.write(from:pcm);remaining -= Int64(pcm.frameLength);deliveredFrames += Int64(pcm.frameLength) }
            }
            start=end;progress(0.85*Double(start)/Double(frames))
        }
        if segments.count == 1 { try FileManager.default.moveItem(at:segments[0],to:video) }
        else { try await concatenate(segments,to:video,cancellation:cancellation) }
        for url in segments where FileManager.default.fileExists(atPath:url.path) { try FileManager.default.removeItem(at:url) }
        try cancellation.check();try Task.checkCancellation()
        // Final reopen uses the actual encoded file, not the writer receipt.
        let asset=AVURLAsset(url:video),tracks=try await asset.loadTracks(withMediaType:.video)
        guard let track=tracks.first else { throw PreparedVideoError.renderFailed("compound output is missing its video") }
        let descriptions=try await track.load(.formatDescriptions),size=try await track.load(.naturalSize),actualDuration=try await asset.load(.duration).seconds
        guard descriptions.contains(where:{(CMFormatDescriptionGetExtension($0,extensionKey:kCMFormatDescriptionExtension_ContainsAlphaChannel) as? Bool) == true}),Int(size.width)==settings.width,Int(size.height)==settings.height,abs(actualDuration-plan.duration.seconds)<max(0.05,1/plan.frameRate.fps) else { throw PreparedVideoError.renderFailed("compound video readback did not match its alpha, size or duration") }
        // Audio output is an AVAudioFile kept by this actor; its native frame
        // length is already durable before the file is admitted to the project.
        let expectedAudio=Int64((plan.duration.seconds*48_000).rounded())
        let nativeLength=audioOutput!.length;audioOutput=nil
        let audioReadback=try AVAudioFile(forReading:audio)
        guard abs(deliveredFrames-expectedAudio)<=Int64(segments.count+1),nativeLength==deliveredFrames,audioReadback.length==deliveredFrames else { throw PreparedVideoError.audioFailure("compound output audio is incomplete") }
        try await verifyPins(pinned,assetURLs:assetURLs,cancellation:cancellation)
        let videoPin=try filePin(video,cancellation:cancellation),audioPin=try filePin(audio,cancellation:cancellation)
        let relative=directory.path.dropFirst(root.path.count+1)
        let v=MediaAssetReference(kind:.video,relativePath:String(relative)+"/proxy.mov",originalName:"Compound.mov",byteCount:videoPin.bytes,contentHash:videoPin.hash,metadata:.init(width:settings.width,height:settings.height,durationSeconds:actualDuration,frameRate:plan.frameRate.fps,audioTracks:0,hasAlpha:true))
        let a=MediaAssetReference(kind:.audio,relativePath:String(relative)+"/proxy.wav",originalName:"Compound.wav",byteCount:audioPin.bytes,contentHash:audioPin.hash,metadata:.init(durationSeconds:Double(deliveredFrames)/48_000,audioTracks:1))
        let sourceHash=try MediaPreparedCompounds.sourceSignature(source)
        let receipt=MediaPreparedCompoundProxy(video:v,audio:a,sourceSHA256:sourceHash,settingsIdentity:settings.identity+":"+sourceHash,duration:try .seconds(plan.duration.seconds))
        accepted=true;progress(1);return receipt
    }
    /// Deletes only this renderer's unreferenced candidate folder after a
    /// failed/cancelled CAS. Never accepts a previous saved proxy as cleanup.
    public nonisolated static func discardUncommitted(_ proxy:MediaPreparedCompoundProxy,rootURL:URL,retaining document:MediaPreparedDocument) throws {
        guard document.asset(proxy.video.id) == nil,proxy.audio.map({document.asset($0.id) == nil}) ?? true else { throw PreparedVideoError.invalidPlan("the proxy is already referenced by the saved original") }
        let root=rootURL.standardizedFileURL.resolvingSymlinksInPath(),url=root.appendingPathComponent(proxy.video.relativePath).standardizedFileURL.resolvingSymlinksInPath()
        let folder=url.deletingLastPathComponent(),assets=root.appendingPathComponent("Assets").path
        guard folder.deletingLastPathComponent().path == assets,folder.lastPathComponent.hasPrefix("Compound-"),url.lastPathComponent == "proxy.mov" else { throw PreparedVideoError.invalidPlan("invalid uncommitted compound proxy") }
        if FileManager.default.fileExists(atPath:folder.path) { try FileManager.default.removeItem(at:folder) }
    }
    private func renderPlan(source:MediaPreparedDocument,assetURLs:[UUID:URL],cancellation:PreparedVideoCancellation) async throws -> PreparedVideoPlan {
        // Extract one explicitly bound container stream in the *render plan*,
        // keeping the persisted source snapshot byte-for-byte editable. No
        // host process, intermediate project or guessed first audio track.
        var renderSource=source,urls=assetURLs
        let linked=Set(source.trackGraph.tracks.flatMap(\.clips).compactMap(\.sourceVisualClipID))
        var aliases:[UUID:MediaAssetReference]=[:],audioTracks:[MediaPreparedTrack]=[]
        for ti in renderSource.trackGraph.tracks.indices where renderSource.trackGraph.tracks[ti].kind == .visual {
            let original=renderSource.trackGraph.tracks[ti]
            var sound:[MediaPreparedClip]=[]
            for ci in original.clips.indices {
                let clip=original.clips[ci]
                guard !clip.isMuted,!original.isMuted,!linked.contains(clip.id),clip.sourcePlayback?.holdSeconds == nil,let id=clip.assetID,let reference=source.asset(id),reference.kind == .video,let url=urls[id] else { continue }
                try cancellation.check();let tracks=try await AVURLAsset(url:url).loadTracks(withMediaType:.audio);try cancellation.check()
                guard tracks.count<=1 else { throw PreparedVideoError.unsupportedCapability("choose or extract a source audio track before nesting a multi-audio video") }
                guard !tracks.isEmpty else { continue }
                let alias:MediaAssetReference
                if let existing=aliases[id] { alias=existing } else {
                    var a=reference;a.id=UUID();a.kind = .audio;aliases[id]=a;alias=a;urls[a.id]=url;renderSource.assets.append(a)
                }
                renderSource.trackGraph.tracks[ti].clips[ci].isMuted=true
                var audio=MediaPreparedClip(assetID:alias.id,timelineRange:clip.timelineRange,sourceRange:clip.sourceRange,speed:clip.speed,isMuted:false,volume:clip.volume,fadeIn:clip.fadeIn,fadeOut:clip.fadeOut,sourceVisualClipID:clip.id,sourcePlayback:clip.sourcePlayback)
                audio.id=UUID();sound.append(audio)
            }
            if !sound.isEmpty { audioTracks.append(.init(kind:.audio,name:original.name,isMuted:false,volume:original.volume,clips:sound)) }
        }
        renderSource.trackGraph.tracks += audioTracks
        return try MediaPreparedVideoDocumentAdapter.resolve(renderSource,assetURLs:urls,includeAudio:true)
    }
    private struct FilePin:Sendable,Equatable { let hash:String;let bytes:Int64 }
    private func pinAssets(source:MediaPreparedDocument,assetURLs:[UUID:URL],root:URL,cancellation:PreparedVideoCancellation) async throws -> [UUID:FilePin] {
        var pins:[UUID:FilePin]=[:]
        for reference in source.assets {
            guard let supplied=assetURLs[reference.id],supplied.isFileURL else { throw PreparedVideoError.missingAsset(reference.id) }
            let url=supplied.standardizedFileURL.resolvingSymlinksInPath()
            guard url.path.hasPrefix(root.path+"/") else { throw PreparedVideoError.invalidPlan("compound source lies outside its original workspace") }
            let pin=try filePin(url,cancellation:cancellation)
            guard reference.contentHash.map({$0.lowercased()==pin.hash}) ?? true,reference.byteCount.map({$0==pin.bytes}) ?? true else { throw MediaPreparedCoreError.staleObject(.init(kind:.asset,id:reference.id)) }
            pins[reference.id]=pin
        }
        return pins
    }
    private func verifyPins(_ pins:[UUID:FilePin],assetURLs:[UUID:URL],cancellation:PreparedVideoCancellation) async throws {
        for (id,pin) in pins { guard let url=assetURLs[id],try filePin(url,cancellation:cancellation)==pin else { throw MediaPreparedCoreError.staleObject(.init(kind:.asset,id:id)) } }
    }
    private func filePin(_ url:URL,cancellation:PreparedVideoCancellation) throws -> FilePin {
        let input=try FileHandle(forReadingFrom:url);defer{try? input.close()};var digest=SHA256(),bytes:Int64=0
        while let data=try input.read(upToCount:1024*1024),!data.isEmpty { try cancellation.check();try Task.checkCancellation();digest.update(data:data);bytes += Int64(data.count) }
        return .init(hash:digest.finalize().map{String(format:"%02x",$0)}.joined(),bytes:bytes)
    }
    private func cancelExport(_ token:UUID) { activeExports[token]?.cancelExport() }
    private func concatenate(_ urls:[URL],to destination:URL,cancellation:PreparedVideoCancellation) async throws {
        let composition=AVMutableComposition()
        guard let target=composition.addMutableTrack(withMediaType:.video,preferredTrackID:kCMPersistentTrackID_Invalid) else { throw PreparedVideoError.renderFailed("cannot create compound proxy track") }
        var cursor=CMTime.zero
        for url in urls {
            try cancellation.check();try Task.checkCancellation();let source=AVURLAsset(url:url)
            guard let track=try await source.loadTracks(withMediaType:.video).first else { throw PreparedVideoError.renderFailed("compound segment is missing its video") }
            let range=try await track.load(.timeRange);try target.insertTimeRange(range,of:track,at:cursor);cursor=CMTimeAdd(cursor,range.duration)
        }
        guard let export=AVAssetExportSession(asset:composition,presetName:AVAssetExportPresetPassthrough) else { throw PreparedVideoError.renderFailed("native transparent composition is unavailable") }
        let token=UUID();activeExports[token]=export
        let monitor=Task { [weak self] in while !Task.isCancelled { if cancellation.isCancelled { await self?.cancelExport(token);return };try? await Task.sleep(for:.milliseconds(50)) } };defer { monitor.cancel();activeExports.removeValue(forKey:token) }
        try await export.export(to:destination,as:.mov);try cancellation.check();try Task.checkCancellation()
    }
}
