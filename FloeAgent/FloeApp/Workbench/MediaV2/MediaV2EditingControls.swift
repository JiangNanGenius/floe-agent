// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeWorkbench

extension MediaV2Session {
    var selectedLayerSet: Set<UUID> {
        if multipleLayerSelection { return selectedLayerIDs.intersection(Set(document.layers.map(\.id))) }
        return selectedLayerID.map { [$0] } ?? []
    }
    func layerDepth(_ layer: MediaPreparedLayer) -> Int {
        var depth = 0, parent = layer.parentID, visited = Set<UUID>()
        while let id = parent, visited.insert(id).inserted, let group = document.layer(id) {
            depth += 1; parent = group.parentID
        }
        return depth
    }
    func shiftLayer(_ layer: MediaPreparedLayer, by amount: Int) {
        let siblings = document.layers.filter { $0.parentID == layer.parentID }
        guard let index = siblings.firstIndex(where: { $0.id == layer.id }),
              siblings.indices.contains(index + amount),
              let position = document.layers.firstIndex(where: { $0.id == siblings[index + amount].id }) else { return }
        submit([.moveLayer(id: layer.id, expectedRevision: layer.revision, parentID: layer.parentID, index: position)])
    }
    func duplicateLayerActions(_ root: MediaPreparedLayer) -> (id: UUID, actions: [MediaPreparedAction]) {
        var ids: Set<UUID> = [root.id]
        while true {
            let children = Set(document.layers.filter { $0.parentID.map { ids.contains($0) } ?? false }.map(\.id))
            let next = ids.union(children)
            if next == ids { break }; ids = next
        }
        let mapping = Dictionary(uniqueKeysWithValues: ids.map { ($0, UUID()) })
        let sorted = document.layers.enumerated().filter { ids.contains($0.element.id) }.sorted {
            let a = layerDepth($0.element), b = layerDepth($1.element)
            return a == b ? $0.offset < $1.offset : a < b
        }.map(\.element)
        let actions = sorted.map { layer -> MediaPreparedAction in
            var copy = layer; copy.id = mapping[layer.id]!; copy.revision = 0; copy.isLocked = false
            copy.parentID = layer.parentID.flatMap { mapping[$0] ?? $0 }
            if var clip = copy.clip { clip.baseLayerID = mapping[clip.baseLayerID] ?? clip.baseLayerID; copy.clip = clip }
            if layer.id == root.id { copy.name += WorkbenchText.t(" 副本", " copy") }
            return .insertLayer(layer: copy, parentID: copy.parentID, index: nil)
        }
        return (mapping[root.id]!, actions)
    }
    func insertExistingAsset(_ asset: MediaAssetReference) {
        do {
            if project.kind == .image {
                guard asset.kind == .image else { throw MediaV2CommandError.invalidInput }
                addLayer(.raster(.init(source: .asset(asset.id))), name: asset.originalName)
            } else {
                let kind: MediaPreparedTrackKind = asset.kind == .audio ? .audio : .visual
                let track = document.trackGraph.tracks.first { $0.id == selectedTrackID && $0.kind == kind && !$0.isLocked }
                    ?? document.trackGraph.tracks.first { $0.kind == kind && !$0.isLocked }
                    ?? .init(kind: kind, name: asset.originalName)
                let seconds = asset.kind == .image ? 5 : asset.metadata?.durationSeconds ?? 0
                guard seconds > 0 else { throw MediaV2CommandError.invalidInput }
                var actions: [MediaPreparedAction] = []
                if document.trackGraph.track(track.id) == nil { actions.append(.insertTrack(track: track, index: nil)) }
                let clip = MediaPreparedClip(assetID: asset.id,
                    timelineRange: try Self.range(start: playhead, duration: seconds),
                    sourceRange: try Self.range(start: 0, duration: seconds))
                actions.append(.insertClip(trackID: track.id, clip: clip, index: nil))
                selectedTrackID = track.id; selectedClipID = clip.id; submit(actions)
            }
        } catch { diagnostic = error.localizedDescription }
    }

    func snapTime(_ seconds: Double, excluding clipID: UUID? = nil) -> Double {
        let fps = max(1, document.trackGraph.frameRate?.seconds ?? 30)
        let framed = max(0, (seconds * fps).rounded() / fps)
        guard timelineSnap else { return max(0, seconds) }
        let tolerance = 7 / (35 * timelineZoom)
        var edges: [Double] = [0, playhead]
        for track in document.trackGraph.tracks {
            for clip in track.clips where clip.id != clipID {
                edges.append(clip.timelineRange.startSeconds)
                edges.append(clip.timelineRange.endSeconds)
            }
        }
        return edges.min(by: { abs($0 - framed) < abs($1 - framed) })
            .flatMap { abs($0 - framed) <= tolerance ? $0 : nil } ?? framed
    }

    /// Source range and timeline range remain linked through speed. Animation
    /// is sliced in local time, rather than left outside the new clip bounds.
    func trimmedClip(_ clip: MediaPreparedClip, sourceStart: Double, sourceDuration: Double,
                     timelineStart: Double? = nil) throws -> MediaPreparedClip {
        guard sourceStart.isFinite, sourceDuration.isFinite, sourceStart >= 0,
              sourceDuration > 0, clip.speed > 0 else { throw MediaV2CommandError.invalidInput }
        if let assetID = clip.assetID, let asset = document.asset(assetID), asset.kind != .image,
           let sourceLimit = asset.metadata?.durationSeconds,
           sourceStart + sourceDuration > sourceLimit + 0.001 { throw MediaV2CommandError.invalidInput }
        var next = clip
        let offset = clip.sourcePlayback?.isReversed == true
            ? (clip.sourceRange.endSeconds - sourceStart - sourceDuration) / clip.speed
            : (sourceStart - clip.sourceRange.startSeconds) / clip.speed
        let duration = clip.sourcePlayback?.holdSeconds != nil ? clip.timelineRange.durationSeconds : sourceDuration / clip.speed
        next.sourceRange = try Self.range(start: sourceStart, duration: sourceDuration)
        next.timelineRange = try Self.range(start: timelineStart ?? clip.timelineRange.startSeconds, duration: duration)
        next.keyframeTracks = try slicedKeyframes(clip.keyframeTracks, from: offset, duration: duration)
        if let fade = next.fadeIn { next.fadeIn = try Self.time(min(duration, fade.seconds)) }
        if let fade = next.fadeOut { next.fadeOut = try Self.time(min(duration, fade.seconds)) }
        if let transition = next.transitionDuration, transition.seconds > duration {
            next.transitionDuration = try Self.time(duration)
        }
        return next
    }
    func slicedKeyframes(_ tracks: [MediaKeyframeTrack], from offset: Double, duration: Double) throws -> [MediaKeyframeTrack] {
        try MediaAnimation.sliced(tracks,from:offset,duration:duration)
    }
    func trimActions(track: MediaPreparedTrack, clip: MediaPreparedClip, sourceStart: Double,
                     sourceDuration: Double, timelineStart: Double? = nil, ripple: Bool = false) throws -> [MediaPreparedAction] {
        let next = try trimmedClip(clip, sourceStart: sourceStart, sourceDuration: sourceDuration, timelineStart: timelineStart)
        var actions: [MediaPreparedAction] = [.replaceClip(trackID: track.id, clipID: clip.id, expectedRevision: clip.revision, clip: next)]
        if track.kind == .visual { actions.append(contentsOf: try linkedSourceAudioActions(for: next)) }
        if ripple {
            let delta = next.timelineRange.endSeconds - clip.timelineRange.endSeconds
            for later in track.clips where later.id != clip.id && later.timelineRange.startSeconds >= clip.timelineRange.endSeconds - 0.000_01 {
                var shifted = later
                shifted.timelineRange = try Self.range(start: max(0, later.timelineRange.startSeconds + delta), duration: later.timelineRange.durationSeconds)
                actions.append(.replaceClip(trackID: track.id, clipID: later.id, expectedRevision: later.revision, clip: shifted))
            }
        }
        return actions
    }
    func rollActions(track: MediaPreparedTrack, right: MediaPreparedClip, boundary: Double) throws -> [MediaPreparedAction] {
        let frame = 1 / max(1, document.trackGraph.frameRate?.seconds ?? 30)
        guard let left = track.clips.filter({ $0.id != right.id && $0.timelineRange.startSeconds < right.timelineRange.startSeconds })
            .max(by: { $0.timelineRange.startSeconds < $1.timelineRange.startSeconds }),
              abs(left.timelineRange.endSeconds - right.timelineRange.startSeconds) <= frame,
              left.leadingTransition == .none, right.leadingTransition == .none else { throw MediaV2CommandError.invalidInput }
        let delta = boundary - right.timelineRange.startSeconds
        let leftDuration = left.timelineRange.durationSeconds + delta
        let rightDuration = right.timelineRange.durationSeconds - delta
        guard leftDuration >= frame, rightDuration >= frame else { throw MediaV2CommandError.invalidInput }
        let nextLeft = try timelineTrimmedClip(left,offset:0,duration:leftDuration)
        let nextRight = try timelineTrimmedClip(right,offset:delta,duration:rightDuration,timelineStart:boundary)
        var actions: [MediaPreparedAction] = [.replaceClip(trackID: track.id, clipID: left.id, expectedRevision: left.revision, clip: nextLeft),
                .replaceClip(trackID: track.id, clipID: right.id, expectedRevision: right.revision, clip: nextRight)]
        if track.kind == .visual {
            actions.append(contentsOf:try linkedSourceAudioActions(for:nextLeft))
            actions.append(contentsOf:try linkedSourceAudioActions(for:nextRight))
        }
        return actions
    }
    private func timelineTrimmedClip(_ clip: MediaPreparedClip, offset: Double, duration: Double, timelineStart: Double? = nil) throws -> MediaPreparedClip {
        let source = try MediaSourcePlaybackMath.sourceTrim(sourceStart:clip.sourceRange.startSeconds,
            sourceDuration:clip.sourceRange.durationSeconds,speed:clip.speed,offset:offset,duration:duration,playback:clip.sourcePlayback)
        if let limit = clip.assetID.flatMap({document.asset($0)?.metadata?.durationSeconds}), source.start + source.duration > limit + 0.001 {
            throw MediaV2CommandError.invalidInput
        }
        var next = clip
        next.sourceRange = try Self.range(start:source.start,duration:source.duration)
        next.timelineRange = try Self.range(start:timelineStart ?? clip.timelineRange.startSeconds,duration:duration)
        next.keyframeTracks = try slicedKeyframes(clip.keyframeTracks,from:offset,duration:duration)
        if let fade = next.fadeIn { next.fadeIn = try Self.time(min(duration,fade.seconds)) }
        if let fade = next.fadeOut { next.fadeOut = try Self.time(min(duration,fade.seconds)) }
        if let transition = next.transitionDuration { next.transitionDuration = try Self.time(min(duration,transition.seconds)) }
        return next
    }
    func linkedSourceAudioActions(for clip: MediaPreparedClip, timeScale: Double = 1) throws -> [MediaPreparedAction] {
        try document.trackGraph.tracks.filter { $0.kind == .audio }.flatMap { track in
            try track.clips.filter { $0.sourceVisualClipID == clip.id }.map { source in
                var sound = source
                sound.timelineRange = clip.timelineRange; sound.sourceRange = clip.sourceRange
                sound.speed = clip.speed; sound.sourcePlayback = clip.sourcePlayback
                sound.fadeIn = try source.fadeIn.map { try Self.time(min(clip.timelineRange.durationSeconds, $0.seconds * timeScale)) }
                sound.fadeOut = try source.fadeOut.map { try Self.time(min(clip.timelineRange.durationSeconds, $0.seconds * timeScale)) }
                return .replaceClip(trackID: track.id, clipID: sound.id, expectedRevision: source.revision, clip: sound)
            }
        }
    }
    func timelineTrimTarget(_ seconds: Double, clip: MediaPreparedClip, leading: Bool) -> Double {
        let frame = 1 / max(1, document.trackGraph.frameRate?.seconds ?? 30)
        if clip.sourcePlayback?.holdSeconds != nil {
            return leading ? min(clip.timelineRange.endSeconds - frame,max(0,seconds)) : max(clip.timelineRange.startSeconds + frame,seconds)
        }
        let limit = clip.assetID.flatMap { document.asset($0)?.metadata?.durationSeconds }
        let reversed = clip.sourcePlayback?.isReversed == true
        let ceiling = limit ?? clip.sourceRange.endSeconds
        return MediaTimelineViewportMath.trimTarget(seconds, leading: leading,
            start: clip.timelineRange.startSeconds, end: clip.timelineRange.endSeconds,
            sourceStart: reversed ? max(0,ceiling - clip.sourceRange.endSeconds) : clip.sourceRange.startSeconds,
            sourceEnd: reversed ? ceiling - clip.sourceRange.startSeconds : clip.sourceRange.endSeconds,
            speed: clip.speed, assetDuration: limit, frameDuration: frame)
    }
    func trimTimelineEdge(track: MediaPreparedTrack, clip: MediaPreparedClip, leading: Bool, to seconds: Double, expectedRevision: Int64? = nil) {
        do {
            let target = timelineTrimTarget(snapTime(seconds, excluding: clip.id),clip:clip,leading:leading)
            let offset = leading ? target - clip.timelineRange.startSeconds : 0
            let duration = leading ? clip.timelineRange.endSeconds - target : target - clip.timelineRange.startSeconds
            let next = try timelineTrimmedClip(clip,offset:offset,duration:duration,timelineStart:leading ? target:nil)
            var actions: [MediaPreparedAction] = [.replaceClip(trackID:track.id,clipID:clip.id,expectedRevision:clip.revision,clip:next)]
            if track.kind == .visual { actions.append(contentsOf:try linkedSourceAudioActions(for:next)) }
            if !leading && rippleCurrentTrack {
                let delta = next.timelineRange.endSeconds - clip.timelineRange.endSeconds
                for later in track.clips where later.id != clip.id && later.timelineRange.startSeconds >= clip.timelineRange.endSeconds - 0.000_01 {
                    var moved = later
                    moved.timelineRange = try Self.range(start:max(0,later.timelineRange.startSeconds + delta),duration:later.timelineRange.durationSeconds)
                    actions.append(.replaceClip(trackID:track.id,clipID:later.id,expectedRevision:later.revision,clip:moved))
                    if track.kind == .visual { actions.append(contentsOf:try linkedSourceAudioActions(for:moved)) }
                }
            }
            commitTimelineGesture(actions,revision:expectedRevision ?? document.revision)
        } catch { diagnostic = error.localizedDescription }
    }

    func commitTimelineGesture(_ actions:[MediaPreparedAction],revision:Int64) {
        Task { do { _ = try await apply(actions.map{.init(action:$0)},expectedRevision:revision) }
            catch { diagnostic = error.localizedDescription } }
    }

    func keyframeValue(for property: String, in clip: MediaPreparedClip) -> Double {
        let track = clip.keyframeTracks.first { $0.property == property || $0.property == "transform." + property }
        let local = max(0, playhead - clip.timelineRange.startSeconds)
        return track.flatMap { evaluatedKeyframe($0, at: local) }
            ?? (property == "scale" || property == "opacity" ? 1 : property == "centerX" || property == "centerY" ? 0.5 : 0)
    }
    func evaluatedKeyframe(_ track: MediaKeyframeTrack, at localTime: Double) -> Double? {
        let name = track.property.replacingOccurrences(of: "transform.", with: "")
        guard let property = PreparedVideoAnimatableProperty(rawValue: name) else { return nil }
        do {
            let keys = try track.keyframes.map { try MediaAnimation.preparedKey($0,timescale:90_000) }
            return try PreparedVideoFrameEvaluator.interpolate(track: .init(property: property, keyframes: keys),
                at: PreparedVideoTime(seconds: max(0, localTime), timescale: 90_000))
        } catch { return nil }
    }
    func removeKeyframe(property: String, time: MediaRationalTime) {
        guard let selected = selectedClip else { return }
        var tracks = selected.clip.keyframeTracks
        for index in tracks.indices where tracks[index].property == property {
            tracks[index].keyframes.removeAll { abs($0.time.seconds - time.seconds) < 0.000_01 }
        }
        tracks.removeAll { $0.keyframes.isEmpty }
        submit([.replaceClipKeyframes(trackID: selected.track.id, clipID: selected.clip.id,
            expectedRevision: selected.clip.revision, keyframeTracks: tracks)])
    }
    func shiftCaptions(by seconds: Double) throws {
        guard seconds.isFinite else { throw MediaV2CommandError.invalidInput }
        var actions: [MediaPreparedAction] = []
        for track in document.trackGraph.tracks where track.kind == .caption {
            for clip in track.clips {
                let start = clip.timelineRange.startSeconds + seconds
                guard start >= 0 else { throw MediaV2CommandError.invalidInput }
                var next = clip; next.timelineRange = try Self.range(start: start, duration: clip.timelineRange.durationSeconds)
                actions.append(.replaceClip(trackID: track.id, clipID: clip.id, expectedRevision: clip.revision, clip: next))
            }
        }
        guard !actions.isEmpty else { throw MediaV2CommandError.missingSelection }
        submit(actions)
    }

    /// Viewport crop points are converted into the currently displayed source
    /// rectangle. AI callers retain the existing normalized source contract.
    func sourceCrop(for layer: MediaPreparedLayer, canvasPoints: [ImageFreehandStroke.Point]) throws -> NormalizedRect {
        guard let canvas = document.canvas, canvasPoints.count == 2,
              case .raster(let raster) = layer.content else { throw MediaV2CommandError.missingSelection }
        let old = raster.crop ?? .init(x: 0, y: 0, width: 1, height: 1)
        guard case .asset(let id) = raster.source,
              let metadata = document.asset(id)?.metadata,
              let pixelWidth = metadata.width, let pixelHeight = metadata.height,
              pixelWidth > 0, pixelHeight > 0 else { throw MediaV2CommandError.unavailable }
        let sourceW = Double(pixelWidth) * old.width
        let sourceH = Double(pixelHeight) * old.height
        let fit = min(Double(canvas.width) / sourceW, Double(canvas.height) / sourceH)
        let width = sourceW * fit, height = sourceH * fit
        let rotation = -layer.transform.rotationDegrees * .pi / 180
        let scale = layer.transform.scale
        guard width > 0, height > 0, scale > 0 else { throw MediaV2CommandError.invalidInput }
        let a = canvasPoints[0], b = canvasPoints[1]
        let corners = [a, .init(x: b.x, y: a.y), b, .init(x: a.x, y: b.y)]
        let mapped = corners.map { point -> ImageFreehandStroke.Point in
            let dx = (point.x - layer.transform.centerX) * Double(canvas.width)
            let dy = (point.y - layer.transform.centerY) * Double(canvas.height)
            var x = (dx * cos(rotation) - dy * sin(rotation)) / scale
            var y = (dx * sin(rotation) + dy * cos(rotation)) / scale
            if layer.transform.flipX == true { x = -x }; if layer.transform.flipY == true { y = -y }
            return .init(x: old.x + min(1, max(0, x / width + 0.5)) * old.width,
                         y: old.y + min(1, max(0, y / height + 0.5)) * old.height)
        }
        let minX = mapped.map(\.x).min()!, minY = mapped.map(\.y).min()!
        let maxX = mapped.map(\.x).max()!, maxY = mapped.map(\.y).max()!
        guard maxX - minX > 0.0001, maxY - minY > 0.0001 else { throw MediaV2CommandError.invalidInput }
        return .init(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}
#endif
