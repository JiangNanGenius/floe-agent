// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import AVFoundation
import CryptoKit
import FloeWorkbench

extension MediaV2Session {
    func providerTranscribe(input: MediaV2ToolInput,actor: MediaPreparedActorKind,base: Int64,
                            authority: MediaV2ProviderAuthority) async throws -> MediaV2ToolReceipt {
        let fenced = try requireProviderSelection(input,actor:actor)
        let selected = input.objectID.flatMap { document.trackGraph.clip(id:$0) } ?? (input.objectID == nil && fenced ? selectedClip : nil)
        guard project.kind == .video,let selected,selected.track.kind == .visual || selected.track.kind == .audio,
              !selected.track.isLocked,let assetID = selected.clip.assetID,let asset = document.asset(assetID),
              asset.kind == .video || asset.kind == .audio,
              selected.clip.sourcePlayback?.isReversed != true,selected.clip.sourcePlayback?.holdSeconds == nil,
              let source = try resolvedAssets()[assetID] else { throw MediaV2CommandError.missingSelection }
        providerStatus = WorkbenchText.t("正在准备片段音频…", "Preparing clip audio…")
        let digest = try await MediaV2ProviderSourceDigest.shared.digest(source)
        if let expected = asset.contentHash,expected != digest { throw MediaPreparedCoreError.documentChanged }
        let excerpt = MediaV2ProviderExcerptWriter()
        defer { Task { await excerpt.close() } }
        let url = try await withTaskCancellationHandler {
            try await excerpt.export(source:source,root:root,start:selected.clip.sourceRange.startSeconds,duration:selected.clip.sourceRange.durationSeconds)
        } onCancel: { Task { await excerpt.cancel() } }
        try await authority.authorize(capability:.transcription,projectID:id,revision:base)
        guard try await MediaV2ProviderSourceDigest.shared.digest(source) == digest else { throw MediaPreparedCoreError.documentChanged }
        providerStatus = WorkbenchText.t("正在转写片段…", "Transcribing clip…")
        let segments = try await MediaV2ProviderBridge.transcribeFile(url,authority:authority)
        try await authority.authorize(capability:.transcription,projectID:id,revision:base)
        guard document.revision == base,try await MediaV2ProviderSourceDigest.shared.digest(source) == digest else { throw MediaPreparedCoreError.documentChanged }
        let clips = try MediaCaptionTransformation.transcribedClips(segments.map { .init(start:$0.start,end:$0.end,text:$0.text) },source:selected.clip)
        let track = MediaPreparedTrack(kind:.caption,name:WorkbenchText.t("转写字幕", "Transcribed captions"),clips:clips)
        providerStatus = WorkbenchText.t("正在保存字幕…", "Saving captions…")
        let commit = try await apply([.init(action:.insertTrack(track:track,index:nil))],expectedRevision:base,actor:actor)
        selectedTrackID = track.id;selectedClipID = clips.first?.id
        return .init(documentID:document.id,revision:document.revision,toolID:"video.transcribe",groupID:commit.groupID,selectionOnly:false)
    }
    func providerTranslate(input: MediaV2ToolInput,actor: MediaPreparedActorKind,base: Int64,
                           authority: MediaV2ProviderAuthority) async throws -> MediaV2ToolReceipt {
        let fenced = try requireProviderSelection(input,actor:actor)
        guard project.kind == .video,let language = input.text?.trimmingCharacters(in:.whitespacesAndNewlines),!language.isEmpty,language.utf8.count<=128 else { throw MediaV2CommandError.invalidInput }
        let sourceClips: [MediaPreparedClip]
        let name: String
        if let object = input.objectID {
            if let track = document.trackGraph.track(object),track.kind == .caption,!track.isLocked { sourceClips=track.clips;name=track.name }
            else if let found = document.trackGraph.clip(id:object),found.track.kind == .caption,!found.track.isLocked { sourceClips=[found.clip];name=found.track.name }
            else { throw MediaV2CommandError.missingSelection }
        } else if fenced,let track = selectedTrack,track.kind == .caption,!track.isLocked {
            sourceClips = selectedClip.map { [$0.clip] } ?? track.clips;name = track.name
        } else { throw MediaV2CommandError.missingSelection }
        guard !sourceClips.isEmpty,sourceClips.count<=20_000,sourceClips.allSatisfy({!($0.captionText?.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ?? true)}),
              sourceClips.reduce(0,{$0+($1.captionText?.utf8.count ?? 0)})<=8*1_024*1_024 else {
            throw MediaPreparedCoreError.invalidOperation(WorkbenchText.t("请选择含文字的字幕轨或更少的字幕片段。", "Select a text caption track or fewer caption clips."))
        }
        providerStatus = WorkbenchText.t("正在翻译字幕…", "Translating captions…")
        let source = sourceClips.map { MediaV2ProviderBridge.CaptionText(id:$0.id,text:$0.captionText!) }
        try await authority.authorize(capability:.translation,projectID:id,revision:base)
        let result = try await MediaV2ProviderBridge.translateCaptions(source,language:language,authority:authority)
        try await authority.authorize(capability:.translation,projectID:id,revision:base)
        let clips = try MediaCaptionTransformation.translatedClips(result.map{.init(sourceID:$0.id,text:$0.text)},source:sourceClips,language:language)
        let track = MediaPreparedTrack(kind:.caption,name:name+" · "+language,clips:clips)
        providerStatus = WorkbenchText.t("正在保存翻译…", "Saving translation…")
        let commit = try await apply([.init(action:.insertTrack(track:track,index:nil))],expectedRevision:base,actor:actor)
        selectedTrackID=track.id;selectedClipID=clips.first?.id
        return .init(documentID:document.id,revision:document.revision,toolID:"video.translate",groupID:commit.groupID,selectionOnly:false)
    }
}

/// Source hashing and excerpt encoding never block the main actor. Only URLs
/// and value results cross actors; each worker owns its descriptors/lifetime.
private actor MediaV2ProviderSourceDigest {
    static let shared = MediaV2ProviderSourceDigest()
    func digest(_ url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom:url);defer { try? file.close() }
        var hasher = SHA256(),count: Int64 = 0
        while true {
            try Task.checkCancellation()
            guard let data = try file.read(upToCount:1_048_576),!data.isEmpty else { break }
            count += Int64(data.count)
            guard count<=4_294_967_296 else { throw MediaPreparedCoreError.limitsExceeded("source exceeds 4 GiB verification limit") }
            hasher.update(data:data)
        }
        return hasher.finalize().map { String(format:"%02x",$0) }.joined()
    }
}
actor MediaV2ProviderExcerptWriter {
    private var temporary: MediaV2ImportTemporaryFile?
    private var activeExport: AVAssetExportSession?
    func export(source: URL,root: URL,start: Double,duration: Double) async throws -> URL {
        try Task.checkCancellation()
        let asset=AVURLAsset(url:source)
        guard !(try await asset.loadTracks(withMediaType:.audio)).isEmpty,
              let export=AVAssetExportSession(asset:asset,presetName:AVAssetExportPresetAppleM4A) else { throw MediaV2CommandError.invalidInput }
        let temporary=try MediaV2ImportTemporaryFile(root:root,fileExtension:"m4a");self.temporary=temporary
        export.timeRange=CMTimeRange(start:CMTime(seconds:start,preferredTimescale:90_000),duration:CMTime(seconds:duration,preferredTimescale:90_000))
        activeExport=export;defer { activeExport=nil }
        try await export.export(to:temporary.url,as:.m4a)
        try Task.checkCancellation();return temporary.url
    }
    func cancel() { activeExport?.cancelExport() }
    func close() { activeExport?.cancelExport();activeExport=nil;temporary=nil }
}
#endif
