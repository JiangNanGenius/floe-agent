// FloeWorkbench — Video timeline refinement tests (Build265).
import Foundation
import Testing
import FloeCore
@testable import FloeWorkbench

@Suite("Video timeline refinements")
struct VideoRefinementTests {
    private func clip(assetID: UUID = UUID(), trimStart: Double = 0, trimEnd: Double = 2,
                      speed: Double = 1) -> VideoClip {
        VideoClip(assetID: assetID, trimStart: trimStart, trimEnd: trimEnd, speed: speed)
    }

    private func timeline(_ clips: [VideoClip], captions: [CaptionSegment] = []) -> VideoTimeline {
        VideoTimeline(clips: clips, captions: captions)
    }

    @Test("timecode formats exact frame positions")
    func timecode() {
        #expect(MediaTimelineMath.timecode(seconds: 0, frameRate: 30) == "00:00:00:00")
        #expect(MediaTimelineMath.timecode(seconds: 61.5, frameRate: 30) == "00:01:01:15")
        #expect(MediaTimelineMath.timecode(seconds: 3661, frameRate: 30) == "01:01:01:00")
        #expect(MediaTimelineMath.timecode(seconds: 1.97, frameRate: 25) == "00:00:01:24")
    }

    @Test("frame stepping quantizes and clamps to the timeline")
    func frameStepping() {
        #expect(abs(MediaTimelineMath.frameStep(seconds: 1.0, deltaFrames: 1, frameRate: 30, duration: 10) - 1.0333333) < 0.0001)
        #expect(abs(MediaTimelineMath.frameStep(seconds: 1.0, deltaFrames: -1, frameRate: 30, duration: 10) - 0.9666666) < 0.0001)
        #expect(MediaTimelineMath.frameStep(seconds: 0, deltaFrames: -5, frameRate: 30, duration: 10) == 0)
        #expect(MediaTimelineMath.frameStep(seconds: 9.99, deltaFrames: 50, frameRate: 30, duration: 10) == 10)
    }

    @Test("snapping prefers clip edges within tolerance and keeps the input otherwise")
    func snapping() {
        let timeline = timeline([clip(trimStart: 0, trimEnd: 2), clip(trimStart: 0, trimEnd: 3)])
        let candidates = MediaTimelineMath.snapCandidates(timeline)
        #expect(candidates == [0, 0, 2, 2, 5])
        #expect(MediaTimelineMath.snap(seconds: 1.98, to: candidates, tolerance: 0.05) == 2)
        #expect(MediaTimelineMath.snap(seconds: 1.5, to: candidates, tolerance: 0.05) == 1.5)
        #expect(MediaTimelineMath.snap(seconds: 2.02, to: candidates, tolerance: 0.05) == 2)
    }

    @Test("cover time clamps into the timeline and rejects non-finite values")
    func coverTime() {
        let timeline = timeline([clip(trimEnd: 4)])
        #expect(MediaTimelineMath.coverTime(1.25, timeline: timeline) == 1.25)
        #expect(MediaTimelineMath.coverTime(-3, timeline: timeline) == 0)
        #expect(MediaTimelineMath.coverTime(99, timeline: timeline) == 4)
        #expect(MediaTimelineMath.coverTime(.nan, timeline: timeline) == nil)
        #expect(MediaTimelineMath.coverTime(nil, timeline: timeline) == nil)
    }

    @Test("caption shift keeps order, clamps to zero and drops off-timeline entries")
    func captionShift() {
        let captions = [
            CaptionSegment(start: 0, end: 1, text: "a"),
            CaptionSegment(start: 2, end: 3, text: "b"),
        ]
        let shifted = MediaTimelineMath.shiftCaptions(captions, by: 0.5, duration: 5)
        #expect(shifted[0].start == 0.5 && shifted[1].start == 2.5)
        let backwards = MediaTimelineMath.shiftCaptions(captions, by: -1, duration: 5)
        #expect(backwards.count == 2 && backwards[0].start == 0 && backwards[1].start == 1)
        let dropped = MediaTimelineMath.shiftCaptions(captions, by: 10, duration: 5)
        #expect(dropped.isEmpty)
        let unchanged = MediaTimelineMath.shiftCaptions(captions, by: 0, duration: 5)
        #expect(unchanged.count == 2)
    }

    @Test("export presets expose explicit resolution and frame rate")
    func exportPresets() {
        #expect(VideoExportPreset.landscape1080p.width == 1920 && VideoExportPreset.landscape1080p.height == 1080)
        #expect(VideoExportPreset.portrait1080p.width == 1080 && VideoExportPreset.portrait1080p.height == 1920)
        #expect(VideoExportPreset.square1080.width == VideoExportPreset.square1080.height)
        let options = VideoExportPreset.portrait1080p.options(frameRate: 24, codec: .hevc, fileName: "cover")
        #expect(options.width == 1080 && options.height == 1920 && options.frameRate == 24)
        let defaulted = VideoExportPreset.square1080.options(frameRate: nil, codec: .h264, fileName: "clip")
        #expect(defaulted.frameRate == 30)
    }

    @Test("duplicateClip inserts a fresh copy after the original")
    func duplicateCommand() throws {
        var project = MediaProject(kind: .video, name: "V", videoTimeline: VideoTimeline())
        let asset = MediaAssetReference(kind: .video, relativePath: "clip.mp4", originalName: "clip.mp4")
        try MediaTransactions.apply(.addAsset(asset), to: &project)
        let original = clip(assetID: asset.id, trimStart: 0.5, trimEnd: 2.5, speed: 1.5)
        try MediaTransactions.apply(.appendClip(original), to: &project)
        try MediaTransactions.apply(.duplicateClip(id: original.id), to: &project)
        let clips = try #require(project.videoTimeline?.clips)
        #expect(clips.count == 2)
        #expect(clips[0].id == original.id)
        #expect(clips[1].id != original.id)
        #expect(clips[1].trimStart == original.trimStart && clips[1].trimEnd == original.trimEnd)
        #expect(clips[1].speed == original.speed)
        #expect(MediaTransactions.undo(&project))
        #expect(project.videoTimeline?.clips.count == 1)
    }

    @Test("cover/caption-style/shift commands validate and apply atomically")
    func coverAndCaptionCommands() throws {
        let videoAsset = MediaAssetReference(kind: .video, relativePath: "clip.mp4", originalName: "clip.mp4")
        var project = MediaProject(kind: .video, name: "V",
                                   videoTimeline: VideoTimeline(clips: [clip(assetID: videoAsset.id, trimEnd: 5)]))
        try MediaTransactions.apply(.addAsset(videoAsset), to: &project)
        try MediaTransactions.apply(.setCover(time: 2.5), to: &project)
        #expect(project.videoTimeline?.coverTime == 2.5)
        #expect(throws: (any Error).self) {
            try MediaTransactions.apply(.setCover(time: 500), to: &project)
        }
        try MediaTransactions.apply(.shiftCaptions(bySeconds: 1), to: &project)
        var style = CaptionStyle()
        style.alignment = .center
        style.respectsSafeArea = true
        try MediaTransactions.apply(.setCaptionStyle(style), to: &project)
        #expect(project.videoTimeline?.captionStyle.alignment == .center)
        #expect(project.videoTimeline?.captionStyle.respectsSafeArea == true)
        #expect(throws: (any Error).self) {
            try MediaTransactions.apply(.shiftCaptions(bySeconds: .infinity), to: &project)
        }
    }

    @Test("timeline model round-trips cover time and caption style fields")
    func videoModelCodable() throws {
        var timeline = VideoTimeline(clips: [clip(trimEnd: 3)])
        timeline.coverTime = 1.5
        timeline.captionStyle.alignment = .trailing
        timeline.captionStyle.respectsSafeArea = false
        let data = try JSONEncoder().encode(timeline)
        let decoded = try JSONDecoder().decode(VideoTimeline.self, from: data)
        #expect(decoded.coverTime == 1.5)
        #expect(decoded.captionStyle.alignment == .trailing)
        #expect(decoded.captionStyle.respectsSafeArea == false)
    }

    @Test("trim/speed keep source, timeline and caption mappings consistent")
    func trimSpeedSubtitleMapping() throws {
        // Clip: source 2...6s at 2× speed → 2s of timeline content.
        var fast = clip(trimStart: 2, trimEnd: 6, speed: 2)
        let asset = MediaAssetReference(kind: .video, relativePath: "a.mp4", originalName: "a.mp4",
                                        metadata: .init(durationSeconds: 8))
        var project = MediaProject(kind: .video, name: "V",
                                   assets: [asset],
                                   videoTimeline: VideoTimeline(clips: [fast]))
        // Trim the right edge by one source second: 2...5s at 2× → 1.5s timeline.
        try MediaTransactions.apply(.updateClip(id: fast.id, trimStart: nil, trimEnd: 5,
                                                speed: nil, volume: nil, isMuted: nil,
                                                rotationDegrees: nil, crop: .unchanged,
                                                leadingTransition: nil, transitionDuration: nil),
                                    to: &project)
        let trimmed = try #require(project.videoTimeline?.clips.first)
        #expect(trimmed.trimEnd == 5)
        let placed = MediaTimelineMath.placeClips([trimmed])
        #expect(placed.count == 1)
        #expect(abs(placed[0].duration - 1.5) < 0.001)
        // Playhead→source mapping honors the trim AND the speed.
        #expect(MediaTimelineMath.sourceTime(for: placed[0], timeline: 0.5) == 3.0)
        // Captions after the retimed clip shift by the duration delta (−0.5s).
        let captions = [CaptionSegment(start: 0.2, end: 0.9, text: "in"),
                        CaptionSegment(start: 2.0, end: 2.8, text: "after")]
        let retimed = MediaTimelineMath.retimeCaptions(captions, clipAfter: placed[0], previousDuration: 2.0)
        #expect(abs(retimed[0].start - 0.2) < 0.001)
        #expect(abs(retimed[1].start - 1.5) < 0.001)
        // Crossfade windows still land inside the retimed clip.
        let windows = MediaTimelineMath.dissolveWindows(placed)
        #expect(windows.count == placed.filter { $0.clip.leadingTransition == .crossDissolve }.count)
    }
}
