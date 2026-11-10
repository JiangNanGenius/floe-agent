// SPDX-License-Identifier: MPL-2.0
import Foundation
import CryptoKit

/// Not a second project: this value and its edit history belong to one root
/// clip in the existing prepared document and its canonical journal.
public struct MediaPreparedCompound: Sendable,Codable,Hashable {
    public var anchorClipID:UUID
    public var name:String
    public var source:MediaPreparedDocument
    public var originalTracks:[MediaPreparedCompoundTrackPlacement]
    public var originalStart:MediaRationalTime
    public var proxy:MediaPreparedCompoundProxy
    public var needsRender:Bool
    /// Array breaks the value-type recursion (Clip -> Compound -> template Clip).
    public var outerTemplates:[MediaPreparedClip]
    public var outerVisualTemplate:MediaPreparedClip { outerTemplates[0] }
    public var outerAudioTemplate:MediaPreparedClip? { outerTemplates.count>1 ? outerTemplates[1]:nil }
}
public struct MediaPreparedCompoundTrackPlacement: Sendable,Codable,Hashable {
    public var id:UUID
    public var index:Int
    public var clipPositions:[UUID:Int]
}
public struct MediaPreparedCompoundProxy: Sendable,Codable,Hashable {
    public var video:MediaAssetReference
    public var audio:MediaAssetReference?
    public var sourceSHA256:String
    /// Exact native output signature; includes transparent-alpha mode and the
    /// complete source canvas (including optional color profile on new clients).
    public var settingsIdentity:String
    public var duration:MediaRationalTime
    public init(video:MediaAssetReference,audio:MediaAssetReference?,sourceSHA256:String,settingsIdentity:String,duration:MediaRationalTime) {
        self.video=video;self.audio=audio;self.sourceSHA256=sourceSHA256;self.settingsIdentity=settingsIdentity;self.duration=duration
    }
}
public struct MediaPreparedCompoundSelection: Sendable,Hashable {
    public var documentID:UUID
    public var revision:Int64
    public var clipIDs:Set<UUID>
    public var source:MediaPreparedDocument
    public var placements:[MediaPreparedCompoundTrackPlacement]
    public var originalStart:MediaRationalTime
    public var duration:MediaRationalTime
    public var insertionIndex:Int
    public var sourceSHA256:String
    public var inputSHA256:String
}
public enum MediaPreparedCompoundExpandMode: String,Sendable,Codable { case replace,restoreMutedCopy }

public enum MediaPreparedCompounds {
    public static let schemaVersion=3
    public static func sourceSignature(_ document:MediaPreparedDocument) throws -> String {
        // UI/global revision and dates do not change pixels. Everything else,
        // including source asset generations, playback, effects and full canvas,
        // remains bound. No enumeration that could drop a new optional field.
        var value=document;value.revision=0;value.createdAt=Date(timeIntervalSince1970:0);value.updatedAt=value.createdAt
        struct Generation:Codable { var id:String;var revision:UInt64 }
        struct Signature:Codable { var document:MediaPreparedDocument;var generations:[Generation] }
        let generations=value.assets.sorted{$0.id.uuidString<$1.id.uuidString}.map{Generation(id:$0.id.uuidString,revision:value.assetRevisions?[$0.id] ?? 0)}
        value.assetRevisions=nil // UUID-keyed dictionaries encode as unordered arrays.
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        return SHA256.hash(data:try encoder.encode(Signature(document:value,generations:generations))).map{String(format:"%02x",$0)}.joined()
    }
    public static func source(clipID:UUID,in root:MediaPreparedDocument) throws -> MediaPreparedDocument {
        guard let value=root.trackGraph.clip(id:clipID)?.clip.compound,value.anchorClipID == clipID else {
            throw MediaPreparedCoreError.invalidOperation("The compound clip is no longer available")
        }
        var source=value.source
        source.assets=try source.assets.map { old in
            guard let current=root.asset(old.id) else { throw MediaPreparedCoreError.staleObject(.init(kind:.asset,id:old.id)) };return current
        }
        source.assetRevisions=Dictionary(uniqueKeysWithValues:source.assets.map{($0.id,root.assetRevisions?[$0.id] ?? 0)})
        source.revision=root.revision;source.updatedAt=root.updatedAt
        return source
    }
    public static func isProxyCurrent(clipID:UUID,in root:MediaPreparedDocument) throws -> Bool {
        guard let value=root.trackGraph.clip(id:clipID)?.clip.compound else { return false }
        let signature=try sourceSignature(source(clipID:clipID,in:root))
        return !value.needsRender && value.proxy.sourceSHA256 == signature
    }
    public static func validate(_ root:MediaPreparedDocument) throws {
        for track in root.trackGraph.tracks {
            for clip in track.clips {
                if let owner=clip.compoundAudioOwnerID {
                    guard root.schemaVersion>=schemaVersion,track.kind == .audio,clip.sourceVisualClipID == owner,root.trackGraph.clip(id:owner)?.clip.compound != nil else { throw MediaPreparedCoreError.invalidDocument("compound audio has no saved anchor") }
                }
                guard let value=clip.compound else { continue }
                guard root.schemaVersion >= schemaVersion,root.kind == .video,track.kind == .visual,
                      value.anchorClipID == clip.id,value.source.id == root.id,value.source.kind == .video,
                      value.source.schemaVersion == MediaPreparedSchema.documentVersion,
                      !value.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,value.name.utf8.count<=1024,
                      !value.source.trackGraph.tracks.contains(where:{$0.clips.contains(where:{$0.compound != nil})}),
                      value.source.assets.allSatisfy({root.asset($0.id) != nil}),
                      value.proxy.video.id == clip.assetID,value.proxy.video.kind == .video,
                      root.asset(value.proxy.video.id) == value.proxy.video,
                      value.proxy.audio.map({$0.kind == .audio && root.asset($0.id) == $0}) ?? true,
                      isHash(value.proxy.sourceSHA256),value.proxy.video.contentHash.map(isHash) ?? false,
                      value.proxy.audio.map({$0.contentHash.map(isHash) ?? false}) ?? true,
                      value.proxy.duration.value>0,value.proxy.duration.timescale>0,
                      value.originalStart.value>=0,value.originalStart.timescale>0,
                      (1...2).contains(value.outerTemplates.count),value.outerTemplates.allSatisfy({$0.compound == nil}),
                      value.outerVisualTemplate.compound == nil,value.outerVisualTemplate.id == clip.id,
                      value.outerAudioTemplate?.compound == nil,
                      Set(value.originalTracks.map(\.id)).count == value.originalTracks.count,
                      value.originalTracks.allSatisfy({$0.index>=0 && $0.clipPositions.values.allSatisfy{$0>=0}}) else {
                    throw MediaPreparedCoreError.invalidDocument("compound source/proxy binding is invalid")
                }
                try MediaPreparedIntegrity.validate(value.source)
            }
        }
    }
    private static func isHash(_ value:String)->Bool { value.count == 64 && value.allSatisfy(\.isHexDigit) }
    public static func selection(clipIDs:Set<UUID>,in root:MediaPreparedDocument) throws -> MediaPreparedCompoundSelection {
        try MediaPreparedIntegrity.validate(root)
        guard root.kind == .video,!clipIDs.isEmpty,clipIDs.count<=MediaPreparedSchema.maximumClips else { throw MediaPreparedCoreError.invalidOperation("Select video clips to make a compound clip") }
        var ids=clipIDs
        for id in clipIDs { guard root.trackGraph.clip(id:id) != nil else { throw MediaPreparedCoreError.unknownObject(.init(kind:.clip,id:id)) } }
        // Explicit existing source-audio bindings only. Never guess a first track.
        for track in root.trackGraph.tracks { for clip in track.clips { if let visual=clip.sourceVisualClipID,clipIDs.contains(visual) { ids.insert(clip.id) } } }
        let selected=root.trackGraph.tracks.flatMap(\.clips).filter{ids.contains($0.id)}
        guard selected.allSatisfy({$0.compound == nil}),let start=selected.map({$0.timelineRange.startSeconds}).min(),let end=selected.map({$0.timelineRange.endSeconds}).max(),end>start,
              root.trackGraph.tracks.count<=MediaPreparedSchema.maximumTracks-2 else { throw MediaPreparedCoreError.invalidOperation("Nested compounds or the track limit prevent this operation") }
        let visualIndices=root.trackGraph.tracks.indices.filter { i in root.trackGraph.tracks[i].kind == .visual && root.trackGraph.tracks[i].clips.contains{ids.contains($0.id)} }
        guard let first=visualIndices.first,let last=visualIndices.last else { throw MediaPreparedCoreError.invalidOperation("Include at least one video or title clip") }
        func overlaps(_ clip:MediaPreparedClip)->Bool { clip.timelineRange.startSeconds<end && clip.timelineRange.endSeconds>start }
        for i in first...last where root.trackGraph.tracks[i].kind != .audio {
            if root.trackGraph.tracks[i].clips.contains(where:{!ids.contains($0.id) && overlaps($0)}) { throw MediaPreparedCoreError.invalidOperation("Include the overlapping clips between the selected video tracks to preserve their stacking order") }
        }
        // Captions are composited above visual tracks. Baking selected captions
        // below an unselected higher visual would change the result.
        if root.trackGraph.tracks.contains(where:{$0.kind == .caption && $0.clips.contains{ids.contains($0.id)}}),root.trackGraph.tracks.indices.contains(where:{$0>last && root.trackGraph.tracks[$0].kind == .visual && root.trackGraph.tracks[$0].clips.contains(where:{!ids.contains($0.id) && overlaps($0)})}) { throw MediaPreparedCoreError.invalidOperation("Include the overlapping upper video clips before nesting captions") }
        var source=root;source.schemaVersion=MediaPreparedSchema.documentVersion;source.layers=[];source.trackGraph.tracks=[];source.trackGraph.masterVolume=1;source.trackGraph.masterMuted=false;source.trackGraph.coverTime=nil
        var placements:[MediaPreparedCompoundTrackPlacement]=[]
        for (i,track) in root.trackGraph.tracks.enumerated() {
            let picked=track.clips.filter{ids.contains($0.id)};guard !picked.isEmpty else { continue }
            guard !track.isLocked else { throw MediaPreparedCoreError.lockedObject(.init(kind:.track,id:track.id)) }
            for (ci,clip) in track.clips.enumerated() {
                if clip.leadingTransition != .none,ci>0,ids.contains(clip.id) != ids.contains(track.clips[ci-1].id) { throw MediaPreparedCoreError.invalidOperation("Include both sides of the transition before nesting") }
            }
            var inner=track;inner.clips=try picked.map { clip in var c=clip;c.timelineRange.start=try .seconds(c.timelineRange.startSeconds-start,timescale:c.timelineRange.start.timescale);return c }
            source.trackGraph.tracks.append(inner)
            placements.append(.init(id:track.id,index:i,clipPositions:Dictionary(uniqueKeysWithValues:track.clips.enumerated().filter{ids.contains($0.element.id)}.map{($0.element.id,$0.offset)})))
        }
        let assetIDs=Set(source.trackGraph.tracks.flatMap(\.clips).compactMap(\.assetID))
        source.assets=root.assets.filter{assetIDs.contains($0.id)};source.assetRevisions=Dictionary(uniqueKeysWithValues:source.assets.map{($0.id,root.assetRevisions?[$0.id] ?? 0)})
        if let id=source.sourceAssetID,!assetIDs.contains(id) { source.sourceAssetID=nil }
        try MediaPreparedIntegrity.validate(source)
        return try .init(documentID:root.id,revision:root.revision,clipIDs:ids,source:source,placements:placements,originalStart:.seconds(start),duration:.seconds(end-start),insertionIndex:first,sourceSHA256:sourceSignature(source),inputSHA256:sourceSignature(source))
    }
    public static func creationOperations(selection:MediaPreparedCompoundSelection,proxy:MediaPreparedCompoundProxy,name:String,anchorID:UUID=UUID(),in root:MediaPreparedDocument) throws -> [MediaPreparedOperation] {
        guard root.id == selection.documentID,root.revision == selection.revision,proxy.sourceSHA256 == selection.sourceSHA256,
              proxy.duration.seconds+0.00001>=selection.duration.seconds else { throw MediaPreparedCoreError.documentChanged }
        let current=try Self.selection(clipIDs:selection.clipIDs,in:root)
        guard current.sourceSHA256 == selection.inputSHA256 else { throw MediaPreparedCoreError.documentChanged }
        let range=try MediaTimeRange(start:selection.originalStart,duration:selection.duration),sourceRange=try MediaTimeRange(start:.seconds(0),duration:selection.duration)
        var visual=MediaPreparedClip(id:anchorID,assetID:proxy.video.id,timelineRange:range,sourceRange:sourceRange)
        var audio=proxy.audio.map { MediaPreparedClip(assetID:$0.id,timelineRange:range,sourceRange:sourceRange,sourceVisualClipID:anchorID) }
        audio?.compoundAudioOwnerID=anchorID
        let template=visual
        visual.compound = .init(anchorClipID:anchorID,name:name,source:selection.source,originalTracks:selection.placements,originalStart:selection.originalStart,proxy:proxy,needsRender:false,outerTemplates:[template]+(audio.map{[$0]} ?? []))
        var ops:[MediaPreparedOperation]=selection.source.assets.filter{root.asset($0.id) == nil}.map{.init(action:.insertAsset($0))}
        ops.append(.init(action:.insertAsset(proxy.video)))
        if let audio=proxy.audio { ops.append(.init(action:.insertAsset(audio))) }
        for track in root.trackGraph.tracks { for clip in track.clips where selection.clipIDs.contains(clip.id) { ops.append(.init(action:.removeClip(trackID:track.id,clipID:clip.id,expectedRevision:clip.revision))) } }
        ops.append(.init(action:.insertTrack(track:.init(kind:.visual,name:name,clips:[visual]),index:selection.insertionIndex)))
        if let audio { ops.append(.init(action:.insertTrack(track:.init(kind:.audio,name:name,clips:[audio]),index:nil))) }
        return ops
    }
    static func operationIDs(_ operations:[MediaPreparedOperation]) throws -> [UUID] {
        var ids:[UUID]=[]
        for op in operations { ids.append(op.id);if case .editCompound(_,_,let inner)=op.action {
            guard !inner.contains(where:{if case .editCompound = $0.action { return true };return false}) else { throw MediaPreparedCoreError.invalidOperation("recursive compound edits are not supported") }
            ids.append(contentsOf:inner.map(\.id))
        } }
        return ids
    }
    static func innerEditOperations(clipID:UUID,expectedRevision:UInt64,operations:[MediaPreparedOperation],in root:MediaPreparedDocument) throws -> [MediaPreparedOperation] {
        guard let located=root.trackGraph.clip(id:clipID),var compound=located.clip.compound,located.clip.revision == expectedRevision else { throw MediaPreparedCoreError.staleObject(.init(kind:.clip,id:clipID)) }
        guard !operations.contains(where:{if case .editCompound = $0.action { return true };return false}) else { throw MediaPreparedCoreError.invalidOperation("recursive compound edits are not supported") }
        var inner=try source(clipID:clipID,in:root)
        let mutation=try MediaPreparedEngine.apply(operations,to:&inner)
        guard !mutation.isEmpty else { return [] }
        guard !inner.trackGraph.tracks.contains(where:{$0.clips.contains{$0.compound != nil}}) else { throw MediaPreparedCoreError.invalidOperation("nested compounds are not supported") }
        var ops:[MediaPreparedOperation]=[]
        for asset in inner.assets {
            if let old=root.asset(asset.id) {
                if old != asset { ops.append(.init(action:.replaceAsset(expected:old,expectedRevision:root.assetRevisions?[asset.id] ?? 0,replacement:asset))) }
            } else { ops.append(.init(action:.insertAsset(asset))) }
        }
        compound.source=inner;compound.needsRender=true
        var anchor=located.clip;anchor.compound=compound
        ops.append(.init(action:.replaceClip(trackID:located.track.id,clipID:clipID,expectedRevision:expectedRevision,clip:anchor)))
        return ops
    }
    public static func replacementProxyOperations(clipID:UUID,proxy:MediaPreparedCompoundProxy,in root:MediaPreparedDocument) throws -> [MediaPreparedOperation] {
        guard let located=root.trackGraph.clip(id:clipID),var compound=located.clip.compound,
              proxy.sourceSHA256 == (try sourceSignature(source(clipID:clipID,in:root))),proxy.duration.seconds+0.00001>=located.clip.sourceRange.endSeconds else { throw MediaPreparedCoreError.documentChanged }
        guard located.clip.videoTracking == nil,located.clip.stabilization == nil else { throw MediaPreparedCoreError.invalidOperation("Clear or re-analyze outer motion after updating the compound; the previous result is preserved") }
        if let grade=located.clip.videoGrade,let fields=try JSONSerialization.jsonObject(with:JSONEncoder().encode(grade)) as? [String:Any],fields["colorMatch"] != nil { throw MediaPreparedCoreError.invalidOperation("Outer color matching is bound to the previous proxy; keep the result or restore the editable sources before re-sampling") }
        let linkedDuration=root.trackGraph.tracks.flatMap(\.clips).filter{$0.compoundAudioOwnerID == clipID}.map{$0.sourceRange.endSeconds}.max() ?? 0
        guard proxy.duration.seconds+0.00001>=linkedDuration else { throw MediaPreparedCoreError.documentChanged }
        var ops=[MediaPreparedOperation(action:.insertAsset(proxy.video))]
        if let audio=proxy.audio { ops.append(.init(action:.insertAsset(audio))) }
        compound.source=try source(clipID:clipID,in:root);compound.proxy=proxy;compound.needsRender=false
        var anchor=located.clip;anchor.assetID=proxy.video.id;anchor.compound=compound // preserve every outer adjustment/trim.
        ops.append(.init(action:.replaceClip(trackID:located.track.id,clipID:clipID,expectedRevision:located.clip.revision,clip:anchor)))
        for track in root.trackGraph.tracks { for clip in track.clips where clip.compoundAudioOwnerID == clipID {
            guard let audio=proxy.audio else { continue };var updated=clip;updated.assetID=audio.id
            ops.append(.init(action:.replaceClip(trackID:track.id,clipID:clip.id,expectedRevision:clip.revision,clip:updated)))
        } }
        return ops
    }
    public static func deleteOperations(clipID:UUID,in root:MediaPreparedDocument) throws -> [MediaPreparedOperation] {
        guard let anchor=root.trackGraph.clip(id:clipID),anchor.clip.compound != nil else { throw MediaPreparedCoreError.invalidOperation("Select a compound clip") }
        var ops=[MediaPreparedOperation(action:.removeClip(trackID:anchor.track.id,clipID:clipID,expectedRevision:anchor.clip.revision))]
        for track in root.trackGraph.tracks { for clip in track.clips where clip.compoundAudioOwnerID == clipID { ops.append(.init(action:.removeClip(trackID:track.id,clipID:clip.id,expectedRevision:clip.revision))) } }
        return ops
    }
    public static func duplicateOperations(clipID:UUID,in root:MediaPreparedDocument) throws -> [MediaPreparedOperation] {
        guard let anchor=root.trackGraph.clip(id:clipID),var compound=anchor.clip.compound else { throw MediaPreparedCoreError.invalidOperation("Select a compound clip") }
        var copy=anchor.clip;copy.id=UUID();copy.revision=0;copy.timelineRange.start=try .seconds(anchor.clip.timelineRange.endSeconds,timescale:copy.timelineRange.start.timescale)
        compound.anchorClipID=copy.id;compound.outerTemplates[0].id=copy.id
        compound.outerTemplates[0].timelineRange.start=copy.timelineRange.start
        var audioOps:[MediaPreparedOperation]=[]
        for track in root.trackGraph.tracks { for clip in track.clips where clip.compoundAudioOwnerID == clipID {
            var sound=clip;sound.id=UUID();sound.revision=0;sound.sourceVisualClipID=copy.id;sound.compoundAudioOwnerID=copy.id
            sound.timelineRange.start=try .seconds(clip.timelineRange.startSeconds+anchor.clip.timelineRange.durationSeconds,timescale:sound.timelineRange.start.timescale)
            if compound.outerTemplates.count>1 { compound.outerTemplates[1].id=sound.id;compound.outerTemplates[1].sourceVisualClipID=copy.id;compound.outerTemplates[1].compoundAudioOwnerID=copy.id;compound.outerTemplates[1].timelineRange.start=sound.timelineRange.start }
            audioOps.append(.init(action:.insertClip(trackID:track.id,clip:sound,index:nil)))
        } }
        copy.compound=compound
        return [.init(action:.insertClip(trackID:anchor.track.id,clip:copy,index:nil))]+audioOps
    }
    static func validateModelInnerEdits(_ operations:[MediaPreparedOperation],in root:MediaPreparedDocument) throws {
        for operation in operations { guard case .editCompound(let id,_,let edits)=operation.action else { continue }
            let before=try source(clipID:id,in:root);var draft=before
            let mutation=try MediaPreparedEngine.apply(edits,to:&draft)
            for change in mutation.changes { guard let state=change.before else { continue };switch state {
            case .layer(let value):if value.isLocked { throw MediaPreparedCoreError.lockedObject(change.ref) }
            case .track(let value):if value.isLocked { throw MediaPreparedCoreError.lockedObject(change.ref) }
            case .clip(let trackID,_):if before.trackGraph.track(trackID)?.isLocked != false { throw MediaPreparedCoreError.lockedObject(change.ref) }
            default:break
            } }
        }
    }
    public static func expansionOperations(clipID:UUID,mode:MediaPreparedCompoundExpandMode,in root:MediaPreparedDocument) throws -> [MediaPreparedOperation] {
        guard let located=root.trackGraph.clip(id:clipID),let compound=located.clip.compound else { throw MediaPreparedCoreError.invalidOperation("Select a compound clip") }
        let inner=try source(clipID:clipID,in:root)
        let offset=located.clip.timelineRange.startSeconds
        let linked=root.trackGraph.tracks.flatMap{t in t.clips.filter{$0.compoundAudioOwnerID == clipID}.map{(t,$0)}}
        if mode == .replace {
            guard inner.canvas == root.canvas,inner.trackGraph.masterVolume == 1,!inner.trackGraph.masterMuted,
                  !inner.trackGraph.tracks.contains(where:{$0.kind == .caption && !$0.clips.isEmpty}) || inner.trackGraph.captionStyle == root.trackGraph.captionStyle else {
                throw MediaPreparedCoreError.invalidOperation("The inner canvas, mix or caption style differs. Keep the result and restore a muted source copy instead")
            }
            func matches(_ clip:MediaPreparedClip,_ template:MediaPreparedClip)->Bool { var a=clip,b=template;a.compound=nil;b.compound=nil;a.revision=0;b.revision=0;a.assetID=nil;b.assetID=nil;a.timelineRange.start=b.timelineRange.start;return a == b }
            guard matches(located.clip,compound.outerVisualTemplate),inner.trackGraph.totalDurationSeconds<=located.clip.timelineRange.durationSeconds+0.00001,
                  linked.allSatisfy({pair in compound.outerAudioTemplate.map{matches(pair.1,$0)} ?? false}) else {
                throw MediaPreparedCoreError.invalidOperation("Outer trims or effects cannot be distributed safely. Keep the compound and restore a muted editable copy instead")
            }
        }
        var ops:[MediaPreparedOperation]=[]
        if mode == .replace {
            ops.append(.init(action:.removeClip(trackID:located.track.id,clipID:clipID,expectedRevision:located.clip.revision)))
            for (track,clip) in linked { ops.append(.init(action:.removeClip(trackID:track.id,clipID:clip.id,expectedRevision:clip.revision))) }
        }
        let copiedIDs=Dictionary(uniqueKeysWithValues:inner.trackGraph.tracks.flatMap(\.clips).map{($0.id,mode == .restoreMutedCopy ? UUID():$0.id)})
        for sourceTrack in inner.trackGraph.tracks {
            var restored=sourceTrack
            restored.clips=try sourceTrack.clips.map{clip in var c=clip;c.id=copiedIDs[clip.id]!;if let id=c.sourceVisualClipID { c.sourceVisualClipID=copiedIDs[id] };c.timelineRange.start=try .seconds(clip.timelineRange.startSeconds+offset,timescale:clip.timelineRange.start.timescale);return c}
            if mode == .restoreMutedCopy { restored.id=UUID();restored.isMuted=true;restored.isLocked=false;ops.append(.init(action:.insertTrack(track:restored,index:nil)));continue }
            if let existing=root.trackGraph.track(sourceTrack.id) {
                guard existing.kind == sourceTrack.kind,!existing.isLocked else { throw MediaPreparedCoreError.invalidOperation("The original track changed. Restore a muted copy to keep both versions") }
                let flagsEqual=existing.name == restored.name && existing.isMuted == restored.isMuted && existing.volume == restored.volume
                guard flagsEqual || existing.clips.isEmpty else { throw MediaPreparedCoreError.invalidOperation("The original track now contains other clips. Restore a muted copy to keep their track settings") }
                guard !restored.clips.contains(where:{a in existing.clips.contains{b in a.timelineRange.startSeconds<b.timelineRange.endSeconds && b.timelineRange.startSeconds<a.timelineRange.endSeconds}}) else { throw MediaPreparedCoreError.invalidOperation("Restored clips would overlap later edits. Restore a muted copy instead") }
                if !flagsEqual { ops.append(.init(action:.updateTrackFlags(id:existing.id,expectedRevision:existing.revision,name:restored.name,isMuted:restored.isMuted,isLocked:nil,volume:restored.volume))) }
                for clip in restored.clips { ops.append(.init(action:.insertClip(trackID:existing.id,clip:clip,index:nil))) }
            } else {
                restored.isLocked=false;ops.append(.init(action:.insertTrack(track:restored,index:compound.originalTracks.first(where:{$0.id == sourceTrack.id})?.index)))
            }
        }
        return ops
    }
}
