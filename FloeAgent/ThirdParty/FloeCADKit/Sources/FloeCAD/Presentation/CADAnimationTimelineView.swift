//
//  CADAnimationTimelineView.swift
//  FloeCADKit
//
//  Native Present timeline: clip selection, play/pause/stop, scrub, loop,
//  speed, editable duration, camera and part tracks, keyframe selection,
//  move/delete, value editing, interpolation / timed-curve editing and the
//  turntable / explode-return presets. Authored changes go through the
//  document's ordinary undoable animation commands; playback, scrubbing and
//  preview stay transient.
//

#if canImport(SwiftUI) && canImport(RealityKit) && canImport(UIKit)
import SwiftUI

extension CADAnimationIssue {
    var localizedSummary: String {
        FloeCADStrings.text(localizationKey, detail)
    }
}

struct CADAnimationTimelineView: View {
    let document: FloeCADDocument
    let handle: CADPresentationHandle
    @Bindable var playback: CADAnimationPlaybackModel
    let state: CADAnimationLoadState
    let candidates: [CADAnimationTrackCandidate]
    let onChanged: () -> Void

    @State private var durationText = ""
    @State private var keyTimeText = ""
    @State private var errorMessage: String?
    @State private var selectedTrackID: UUID?
    @State private var selectedKeyframeID: UUID?
    @State private var curveRequest: CurveEditorRequest?
    @State private var valueRequest: ValueEditorRequest?
    @State private var deleteTrackRequest: CADAnimationTrack?

    private struct CurveEditorRequest: Identifiable {
        let id = UUID()
        let clipID: UUID
        let trackID: UUID
        let keyframeID: UUID
        let initial: CADAnimationTimingCurve
    }

    private struct ValueEditorRequest: Identifiable {
        let id = UUID()
        let clipID: UUID
        let trackID: UUID
        let keyframeID: UUID
        let camera: CADAnimationCameraValue?
        let instance: CADAnimationInstanceValue?
        let currentCamera: CADAnimationCameraValue?
        let baseline: CADAnimationInstanceValue?
    }

    private var activeClip: CADAnimationClip? {
        state.animation.activeClip
    }

    private var issues: [CADAnimationIssue] {
        state.issues + playback.issues
    }

    /// A corrupt, too-large or newer-schema payload is preserved read-only.
    /// The timeline must say so instead of offering to create a clip that the
    /// service will refuse (and must never look like an empty new animation).
    private var blockingIssue: CADAnimationIssue? {
        state.issues.first {
            $0.kind == .corruptData || $0.kind == .newerSchema
                || $0.kind == .tooLarge
        }
    }

    /// The explicitly selected row, even when the clip changed underneath it.
    private var selectedTrack: CADAnimationTrack? {
        guard let clip = activeClip, let id = selectedTrackID else { return nil }
        return clip.tracks.first { $0.id == id }
    }

    /// Selection falls back to the first track so the keyframe strip is never
    /// empty just because a track delete removed the previous row.
    private var resolvedTrack: CADAnimationTrack? {
        selectedTrack ?? activeClip?.tracks.first
    }

    private var selectedKeyframe: CADAnimationKeyframe? {
        guard let track = resolvedTrack, let id = selectedKeyframeID else { return nil }
        return track.keyframes.first { $0.id == id }
    }

    private var availableCandidates: [CADAnimationTrackCandidate] {
        guard let clip = activeClip else { return [] }
        let used = Set(clip.tracks.compactMap { $0.target.instanceID })
        return candidates.filter { !used.contains($0.instanceID) }
    }

    var body: some View {
        VStack(spacing: 8) {
            header
            if let issue = blockingIssue {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                    Text(issue.localizedSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("CADAnimationUnavailable")
            } else if let clip = activeClip {
                transport(clip)
                trackBar(clip)
                if let track = resolvedTrack {
                    keyframeBar(clip, track)
                    if let keyframe = selectedKeyframe {
                        keyEditor(clip, track, keyframe)
                    }
                }
                editing(clip)
                if let issue = issues.first {
                    Label(issue.localizedSummary, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("CADAnimationIssue")
                }
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "film")
                        .foregroundStyle(.secondary)
                    Text(FloeCADStrings.text(
                        "cad.animation.empty",
                        "Add a clip to animate the camera or parts."))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button(FloeCADStrings.text("cad.animation.newClip", "New clip")) {
                        createClip()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16)
            .stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("CADAnimationTimeline")
        .onAppear {
            syncDurationText()
            reconcileSelection()
            syncKeyTimeText()
        }
        .onChange(of: activeClip?.id) { _, _ in
            selectedTrackID = nil
            selectedKeyframeID = nil
            syncDurationText()
            reconcileSelection()
            syncKeyTimeText()
        }
        .onChange(of: activeClip?.duration) { _, _ in syncDurationText() }
        .onChange(of: state) { _, _ in
            reconcileSelection()
            syncKeyTimeText()
        }
        .onChange(of: selectedKeyframeID) { _, _ in syncKeyTimeText() }
        .onChange(of: selectedKeyframe?.time) { _, _ in syncKeyTimeText() }
        .alert(FloeCADStrings.text("cad.animation.edit.failed", "Couldn't update the animation"),
               isPresented: Binding(get: { errorMessage != nil },
                                    set: { if !$0 { errorMessage = nil } })) {
            Button(FloeCADStrings.text("cad.ui.common.done", "Done")) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .sheet(item: $curveRequest) { request in
            CADAnimationCurveEditorView(initial: request.initial) { curve in
                applyCurve(request, curve: curve)
            }
        }
        .sheet(item: $valueRequest) { request in
            if let camera = request.camera {
                CADAnimationCameraValueEditorView(
                    initial: camera, current: request.currentCamera) { value in
                    applyValue(request, camera: value, instance: nil)
                }
            } else if let instance = request.instance {
                CADAnimationInstanceValueEditorView(
                    initial: instance, baseline: request.baseline) { value in
                    applyValue(request, camera: nil, instance: value)
                }
            }
        }
        .confirmationDialog(
            Text(FloeCADStrings.text("cad.animation.track.deleteTitle",
                                     "Delete this track?")),
            isPresented: Binding(get: { deleteTrackRequest != nil },
                                 set: { if !$0 { deleteTrackRequest = nil } }),
            titleVisibility: .visible,
            presenting: deleteTrackRequest
        ) { track in
            Button(FloeCADStrings.text("cad.animation.track.delete", "Delete track"),
                   role: .destructive) {
                deleteTrack(track)
                deleteTrackRequest = nil
            }
            Button(FloeCADStrings.text("cad.ui.common.cancel", "Cancel"),
                   role: .cancel) { deleteTrackRequest = nil }
        } message: { _ in
            Text(FloeCADStrings.text(
                "cad.animation.track.deleteMessage",
                "Its keyframes will be removed. You can undo this."))
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(state.animation.clips) { clip in
                    Button {
                        selectClip(clip.id)
                    } label: {
                        if clip.id == activeClip?.id {
                            Label(clip.name, systemImage: "checkmark")
                        } else {
                            Text(clip.name)
                        }
                    }
                }
                if !state.animation.clips.isEmpty { Divider() }
                if blockingIssue == nil {
                    Button {
                        createClip()
                    } label: {
                        Label(FloeCADStrings.text("cad.animation.newClip", "New clip"),
                              systemImage: "plus")
                    }
                }
            } label: {
                Label(activeClip?.name
                        ?? FloeCADStrings.text("cad.animation.noClip", "No clip"),
                      systemImage: "film")
                    .font(.callout.weight(.medium))
            }
            .accessibilityIdentifier("CADAnimationClipMenu")

            Spacer(minLength: 8)

            Text(timeLabel)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)

            if activeClip != nil {
                Toggle(isOn: Binding(get: { playback.loop },
                                     set: { playback.setLoop($0) })) {
                    Image(systemName: "repeat")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .accessibilityLabel(FloeCADStrings.text("cad.animation.loop", "Loop"))
                .accessibilityIdentifier("CADAnimationLoop")

                Menu {
                    ForEach([0.25, 0.5, 1.0, 1.5, 2.0], id: \.self) { value in
                        Button(speedLabel(value)) { playback.setSpeed(value) }
                    }
                } label: {
                    Text(speedLabel(playback.speed))
                        .font(.caption.weight(.medium))
                        .frame(minWidth: 34)
                }
                .accessibilityLabel(FloeCADStrings.text("cad.animation.speed", "Speed"))
                .accessibilityIdentifier("CADAnimationSpeed")
            }
        }
    }

    // MARK: Transport

    private func transport(_ clip: CADAnimationClip) -> some View {
        HStack(spacing: 8) {
            Button {
                playback.stop()
            } label: {
                Image(systemName: "stop.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel(FloeCADStrings.text("cad.animation.stop", "Stop"))
            .accessibilityIdentifier("CADAnimationStop")

            Button {
                playback.togglePlay()
            } label: {
                Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 20)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .accessibilityLabel(playback.isPlaying
                ? FloeCADStrings.text("cad.animation.pause", "Pause")
                : FloeCADStrings.text("cad.animation.play", "Play"))
            .accessibilityIdentifier("CADAnimationPlay")

            Slider(
                value: Binding(get: { min(max(playback.time, 0), clip.duration) },
                               set: { playback.scrub(to: $0) }),
                in: 0...max(clip.duration, 0.1))
                .accessibilityLabel(FloeCADStrings.text("cad.animation.timeline", "Timeline"))
                .accessibilityIdentifier("CADAnimationSlider")
        }
    }

    // MARK: Tracks

    private func trackBar(_ clip: CADAnimationClip) -> some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(clip.tracks.enumerated()), id: \.element.id) { index, track in
                        trackButton(track, index: index)
                    }
                }
            }
            addTrackMenu(clip)
            if let track = resolvedTrack {
                Menu {
                    Button(role: .destructive) {
                        deleteTrackRequest = track
                    } label: {
                        Label(FloeCADStrings.text("cad.animation.track.delete", "Delete track"),
                              systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .controlSize(.small)
                .accessibilityLabel(FloeCADStrings.text("cad.animation.track.more", "Track options"))
                .accessibilityIdentifier("CADAnimationTrackMenu")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("CADAnimationTracks")
    }

    @ViewBuilder
    private func trackButton(_ track: CADAnimationTrack, index: Int) -> some View {
        let isSelected = track.id == resolvedTrack?.id
        let label = Label(trackLabel(track),
                          systemImage: track.target.kind == .camera ? "camera" : "cube")
            .font(.caption.weight(.medium))
            .lineLimit(1)
        if isSelected {
            Button {
                selectTrack(track.id)
            } label: {
                label
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .accessibilityIdentifier("CADAnimationTrackRow-\(index)")
        } else {
            Button {
                selectTrack(track.id)
            } label: {
                label
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("CADAnimationTrackRow-\(index)")
        }
    }

    private func addTrackMenu(_ clip: CADAnimationClip) -> some View {
        let cameraExists = clip.cameraTrack != nil
        return Menu {
            Button {
                addCameraTrack(clip)
            } label: {
                Label(FloeCADStrings.text("cad.animation.track.camera", "Camera"),
                      systemImage: "camera")
            }
            .disabled(cameraExists)
            if !availableCandidates.isEmpty {
                Divider()
                ForEach(availableCandidates) { candidate in
                    Button {
                        addInstanceTrack(candidate, clip: clip)
                    } label: {
                        Label(candidate.name, systemImage: "cube")
                    }
                }
            }
        } label: {
            Label(FloeCADStrings.text("cad.animation.track.add", "Add track"),
                  systemImage: "plus")
                .font(.caption.weight(.medium))
        }
        .controlSize(.small)
        .accessibilityIdentifier("CADAnimationAddTrack")
    }

    // MARK: Keyframes

    private func keyframeBar(_ clip: CADAnimationClip,
                             _ track: CADAnimationTrack) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(trackLabel(track))
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Button {
                    addKeyframe(clip, track)
                } label: {
                    Label(FloeCADStrings.text("cad.animation.keyframe.addKey", "Add key"),
                          systemImage: "plus.diamond")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("CADAnimationAddKey")

                Button(role: .destructive) {
                    deleteSelectedKeyframe(clip, track)
                } label: {
                    Label(FloeCADStrings.text("cad.animation.keyframe.delete", "Delete key"),
                          systemImage: "trash")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(selectedKeyframe == nil)
                .accessibilityIdentifier("CADAnimationDeleteKey")
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if track.keyframes.isEmpty {
                        Text(FloeCADStrings.text(
                            "cad.animation.keyframe.none", "No keyframes yet"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(Array(track.keyframes.enumerated()), id: \.element.id) { index, keyframe in
                        keyframeButton(keyframe, index: index)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("CADAnimationKeyframes")
    }

    @ViewBuilder
    private func keyframeButton(_ keyframe: CADAnimationKeyframe, index: Int) -> some View {
        let isSelected = keyframe.id == selectedKeyframe?.id
        let label = VStack(spacing: 1) {
            Text(String(format: "%.2f", keyframe.time))
                .font(.caption.monospacedDigit())
            Text("s")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 44, minHeight: 34)
        if isSelected {
            Button {
                selectKeyframe(keyframe, movePlayhead: true)
            } label: {
                label
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .accessibilityValue(String(format: "%.3f", keyframe.time))
            .accessibilityIdentifier("CADAnimationKeyRow-\(index)")
        } else {
            Button {
                selectKeyframe(keyframe, movePlayhead: true)
            } label: {
                label
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityValue(String(format: "%.3f", keyframe.time))
            .accessibilityIdentifier("CADAnimationKeyRow-\(index)")
        }
    }

    // MARK: Keyframe editor

    private func keyEditor(_ clip: CADAnimationClip,
                           _ track: CADAnimationTrack,
                           _ keyframe: CADAnimationKeyframe) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text(FloeCADStrings.text("cad.animation.keyframe.time", "Time"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("0.0", text: $keyTimeText)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.decimalPad)
                    .frame(width: 62)
                    .multilineTextAlignment(.trailing)
                    .submitLabel(.done)
                    .onSubmit { commitKeyTime(clip, track, keyframe) }
                    .accessibilityIdentifier("CADAnimationKeyTime")

                Button {
                    commitKeyTime(clip, track, keyframe)
                } label: {
                    Image(systemName: "checkmark")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel(FloeCADStrings.text(
                    "cad.animation.keyframe.applyTime", "Apply time"))
                .accessibilityIdentifier("CADAnimationKeyTimeCommit")

                Button {
                    moveKeyframe(clip, track, keyframe, by: -0.1)
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel(FloeCADStrings.text(
                    "cad.animation.keyframe.earlier", "Earlier"))
                .accessibilityIdentifier("CADAnimationKeyEarlier")

                Button {
                    moveKeyframe(clip, track, keyframe, by: 0.1)
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel(FloeCADStrings.text(
                    "cad.animation.keyframe.later", "Later"))
                .accessibilityIdentifier("CADAnimationKeyLater")

                Spacer(minLength: 4)

                interpolationMenu(clip, track, keyframe)

                Button {
                    valueRequest = makeValueRequest(clip, track, keyframe)
                } label: {
                    Label(FloeCADStrings.text("cad.animation.keyframe.editValue", "Value"),
                          systemImage: "slider.horizontal.3")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("CADAnimationEditValue")
            }
        }
    }

    private func interpolationMenu(_ clip: CADAnimationClip,
                                   _ track: CADAnimationTrack,
                                   _ keyframe: CADAnimationKeyframe) -> some View {
        Menu {
            Button {
                setInterpolation(.linear, curve: nil, clip: clip,
                                 track: track, keyframe: keyframe)
            } label: {
                interpolationOption(
                    FloeCADStrings.text("cad.animation.interpolation.linear", "Linear"),
                    current: keyframe.timingCurve == nil
                        && keyframe.interpolation == .linear)
            }
            Button {
                setInterpolation(.easeInOut, curve: nil, clip: clip,
                                 track: track, keyframe: keyframe)
            } label: {
                interpolationOption(
                    FloeCADStrings.text("cad.animation.interpolation.easeInOut", "Ease in/out"),
                    current: keyframe.timingCurve == nil
                        && keyframe.interpolation == .easeInOut)
            }
            Divider()
            Button {
                curveRequest = CurveEditorRequest(
                    clipID: clip.id, trackID: track.id,
                    keyframeID: keyframe.id,
                    initial: keyframe.timingCurve ?? .defaultCurve)
            } label: {
                Label(FloeCADStrings.text("cad.animation.curve.edit", "Custom curve…"),
                      systemImage: keyframe.timingCurve == nil
                        ? "point.topleft.down.curvedto.point.bottomright.up"
                        : "checkmark")
            }
        } label: {
            Label(interpolationLabel(keyframe), systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                .font(.caption.weight(.medium))
        }
        .controlSize(.small)
        .accessibilityIdentifier("CADAnimationInterpolation")
    }

    @ViewBuilder
    private func interpolationOption(_ title: String, current: Bool) -> some View {
        if current {
            Label(title, systemImage: "checkmark")
        } else {
            Text(title)
        }
    }

    // MARK: Duration / presets

    private func editing(_ clip: CADAnimationClip) -> some View {
        HStack(spacing: 8) {
            Text(FloeCADStrings.text("cad.animation.duration", "Duration"))
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("5.0", text: $durationText)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.decimalPad)
                .frame(width: 58)
                .multilineTextAlignment(.trailing)
                .submitLabel(.done)
                .onSubmit { commitDuration(clip) }
                .accessibilityIdentifier("CADAnimationDuration")

            Spacer(minLength: 4)

            Menu {
                Button {
                    applyReveal()
                } label: {
                    Label(FloeCADStrings.text("cad.animation.preset.reveal", "Reveal"), systemImage: "video")
                }.accessibilityIdentifier("CADAnimationRevealPreset")
                Button {
                    applyTurntable()
                } label: {
                    Label(FloeCADStrings.text("cad.animation.preset.turntable", "Turntable"),
                          systemImage: "rotate.3d")
                }
                Button {
                    applyExplode()
                } label: {
                    Label(FloeCADStrings.text("cad.animation.preset.explode",
                                              "Explode and return"),
                          systemImage: "arrow.up.left.and.arrow.down.right")
                }
            } label: {
                Label(FloeCADStrings.text("cad.animation.preset", "Preset"),
                      systemImage: "sparkles")
                    .font(.caption.weight(.medium))
            }
            .accessibilityIdentifier("CADAnimationPreset")

            if resolvedTrack?.target.kind == .camera {
                Button {
                    captureCameraKeyframe(clip)
                } label: {
                    Label(FloeCADStrings.text("cad.animation.keyframe.capture",
                                              "Capture view"),
                          systemImage: "camera")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("CADAnimationKeyframe")
            }
        }
    }

    private var timeLabel: String {
        String(format: "%.2f / %.2f s", playback.time,
               activeClip?.duration ?? 0)
    }

    private func speedLabel(_ value: Double) -> String {
        value == floor(value) ? "\(Int(value))×" : "\(value)×"
    }

    private func interpolationLabel(_ keyframe: CADAnimationKeyframe) -> String {
        if keyframe.timingCurve != nil {
            return FloeCADStrings.text("cad.animation.interpolation.custom",
                                       "Custom curve")
        }
        return FloeCADStrings.text(keyframe.interpolation.titleKey,
                                   keyframe.interpolation == .linear ? "Linear" : "Ease in/out")
    }

    private func trackLabel(_ track: CADAnimationTrack) -> String {
        switch track.target.kind {
        case .camera:
            return FloeCADStrings.text("cad.animation.track.camera", "Camera")
        case .instance:
            if let id = track.target.instanceID,
               let candidate = candidates.first(where: { $0.instanceID == id }) {
                return candidate.name
            }
            if track.target.instanceID != nil {
                return FloeCADStrings.text("cad.animation.track.missingPart",
                                           "Missing part")
            }
            return FloeCADStrings.text("cad.animation.track.part", "Part")
        }
    }

    // MARK: Selection / sync

    private func syncDurationText() {
        guard let clip = activeClip else { durationText = ""; return }
        durationText = String(format: "%.1f", clip.duration)
    }

    private func syncKeyTimeText() {
        guard let keyframe = selectedKeyframe else { keyTimeText = ""; return }
        keyTimeText = String(format: "%.2f", keyframe.time)
    }

    private func reconcileSelection() {
        guard let clip = activeClip else {
            selectedTrackID = nil
            selectedKeyframeID = nil
            return
        }
        if let id = selectedTrackID, !clip.tracks.contains(where: { $0.id == id }) {
            selectedTrackID = nil
        }
        if selectedTrackID == nil {
            selectedTrackID = (clip.cameraTrack ?? clip.tracks.first)?.id
        }
        let track = clip.tracks.first(where: { $0.id == selectedTrackID })
            ?? clip.tracks.first
        guard let track else {
            selectedKeyframeID = nil
            return
        }
        if let id = selectedKeyframeID, !track.keyframes.contains(where: { $0.id == id }) {
            selectedKeyframeID = nil
        }
        if selectedKeyframeID == nil, !track.keyframes.isEmpty {
            selectedKeyframeID = track.keyframes.min {
                abs($0.time - playback.time) < abs($1.time - playback.time)
            }?.id
        }
    }

    // MARK: Actions

    private func createClip() {
        do {
            let clip = try document.createAnimationClip(
                name: nil, duration: nil)
            selectedTrackID = nil
            selectedKeyframeID = nil
            playback.attach(document: document, handle: handle, clipID: clip.id)
            onChanged()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func selectClip(_ id: UUID) {
        do {
            _ = try document.setActiveAnimationClip(id: id)
            selectedTrackID = nil
            selectedKeyframeID = nil
            playback.attach(document: document, handle: handle, clipID: id)
            onChanged()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func selectTrack(_ id: UUID) {
        selectedTrackID = id
        selectedKeyframeID = nil
        reconcileSelection()
        syncKeyTimeText()
    }

    private func selectKeyframe(_ keyframe: CADAnimationKeyframe, movePlayhead: Bool) {
        selectedKeyframeID = keyframe.id
        if movePlayhead {
            playback.scrub(to: keyframe.time)
        }
        syncKeyTimeText()
    }

    private func addCameraTrack(_ clip: CADAnimationClip) {
        do {
            let track = try document.addAnimationTrack(clipID: clip.id, target: .camera)
            selectedTrackID = track.id
            selectedKeyframeID = nil
            onChanged()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func addInstanceTrack(_ candidate: CADAnimationTrackCandidate,
                                  clip: CADAnimationClip) {
        do {
            let track = try document.addAnimationTrack(
                clipID: clip.id,
                target: .instance(candidate.instanceID,
                                  sourceBodyID: candidate.sourceBodyID))
            selectedTrackID = track.id
            selectedKeyframeID = nil
            onChanged()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteTrack(_ track: CADAnimationTrack) {
        guard let clip = activeClip else { return }
        do {
            _ = try document.deleteAnimationTrack(clipID: clip.id, trackID: track.id)
            selectedTrackID = nil
            selectedKeyframeID = nil
            onChanged()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func addKeyframe(_ clip: CADAnimationClip, _ track: CADAnimationTrack) {
        if let existing = track.keyframes.first(where: {
            abs($0.time - playback.time) < 1e-6
        }) {
            selectKeyframe(existing, movePlayhead: false)
            return
        }
        do {
            let keyframe: CADAnimationKeyframe
            switch track.target.kind {
            case .camera:
                guard let camera = currentCameraValue(for: clip) else {
                    errorMessage = FloeCADStrings.text(
                        "cad.animation.keyframe.noCamera",
                        "Show Present before adding a camera keyframe.")
                    return
                }
                keyframe = try document.setAnimationKeyframe(
                    clipID: clip.id, trackID: track.id, time: playback.time,
                    camera: camera, replace: false)
            case .instance:
                guard let value = instanceValue(for: track, at: playback.time) else {
                    errorMessage = FloeCADStrings.text(
                        "cad.animation.issue.missingInstance",
                        "An animated part is no longer in the assembly.")
                    return
                }
                keyframe = try document.setAnimationKeyframe(
                    clipID: clip.id, trackID: track.id, time: playback.time,
                    instance: value, replace: false)
            }
            selectedKeyframeID = keyframe.id
            onChanged()
        } catch let error as CADDocumentError where error.code == "animation_keyframe_exists" {
            if let existing = track.keyframes.first(where: {
                abs($0.time - playback.time) < 1e-6
            }) {
                selectKeyframe(existing, movePlayhead: false)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteSelectedKeyframe(_ clip: CADAnimationClip,
                                        _ track: CADAnimationTrack) {
        guard let keyframe = selectedKeyframe,
              track.keyframes.contains(where: { $0.id == keyframe.id }) else { return }
        do {
            _ = try document.removeAnimationKeyframe(
                clipID: clip.id, trackID: track.id, keyframeID: keyframe.id)
            selectedKeyframeID = nil
            onChanged()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func moveKeyframe(_ clip: CADAnimationClip,
                              _ track: CADAnimationTrack,
                              _ keyframe: CADAnimationKeyframe,
                              by delta: Double) {
        let target = min(max(keyframe.time + delta, 0), clip.duration)
        guard abs(target - keyframe.time) > 1e-9 else { return }
        do {
            _ = try document.moveAnimationKeyframe(
                clipID: clip.id, trackID: track.id,
                keyframeID: keyframe.id, to: target)
            selectedKeyframeID = keyframe.id
            playback.scrub(to: target)
            onChanged()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func commitKeyTime(_ clip: CADAnimationClip,
                               _ track: CADAnimationTrack,
                               _ keyframe: CADAnimationKeyframe) {
        guard let value = Double(keyTimeText.replacingOccurrences(of: ",", with: ".")),
              value.isFinite else {
            syncKeyTimeText()
            return
        }
        do {
            _ = try document.moveAnimationKeyframe(
                clipID: clip.id, trackID: track.id,
                keyframeID: keyframe.id, to: value)
            selectedKeyframeID = keyframe.id
            playback.scrub(to: min(max(value, 0), clip.duration))
            onChanged()
        } catch {
            errorMessage = error.localizedDescription
            syncKeyTimeText()
        }
    }

    private func captureCameraKeyframe(_ clip: CADAnimationClip) {
        guard let track = clip.cameraTrack else { return }
        if let keyframe = selectedKeyframe,
           resolvedTrack?.id == track.id,
           track.keyframes.contains(where: { $0.id == keyframe.id }) {
            guard let camera = currentCameraValue(for: clip) else {
                errorMessage = FloeCADStrings.text(
                    "cad.animation.keyframe.noCamera",
                    "Show Present before adding a camera keyframe.")
                return
            }
            do {
                _ = try document.setAnimationKeyframe(
                    clipID: clip.id, trackID: track.id, keyframeID: keyframe.id,
                    time: keyframe.time, interpolation: keyframe.interpolation,
                    timingCurve: keyframe.timingCurve, clearTimingCurve: false,
                    camera: camera, replace: true)
                selectedKeyframeID = keyframe.id
                onChanged()
            } catch {
                errorMessage = error.localizedDescription
            }
        } else {
            addKeyframe(clip, track)
        }
    }

    private func commitDuration(_ clip: CADAnimationClip) {
        guard let value = Double(durationText.replacingOccurrences(of: ",", with: ".")) else {
            syncDurationText()
            return
        }
        do {
            _ = try document.updateAnimationClip(id: clip.id, duration: value)
            playback.attach(document: document, handle: handle, clipID: clip.id)
            onChanged()
        } catch {
            errorMessage = error.localizedDescription
            syncDurationText()
        }
    }

    private func setInterpolation(_ interpolation: CADAnimationInterpolation,
                                  curve: CADAnimationTimingCurve?,
                                  clip: CADAnimationClip,
                                  track: CADAnimationTrack,
                                  keyframe: CADAnimationKeyframe) {
        do {
            _ = try document.setAnimationKeyframe(
                clipID: clip.id, trackID: track.id, keyframeID: keyframe.id,
                time: keyframe.time, interpolation: interpolation,
                timingCurve: curve, clearTimingCurve: curve == nil,
                camera: track.target.kind == .camera ? keyframe.camera : nil,
                instance: track.target.kind == .instance ? keyframe.instance : nil,
                replace: true)
            selectedKeyframeID = keyframe.id
            onChanged()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func applyCurve(_ request: CurveEditorRequest,
                            curve: CADAnimationTimingCurve) {
        do {
            let state = document.animationLoadState()
            guard state.animation.activeClip?.id == request.clipID,
                  let clip = state.animation.clip(withID: request.clipID),
                  let track = clip.tracks.first(where: { $0.id == request.trackID }),
                  let keyframe = track.keyframes.first(where: {
                      $0.id == request.keyframeID
                  }) else {
                throw CADDocumentError(
                    code: "animation_stale_selection",
                    message: FloeCADStrings.text(
                        "cad.animation.keyframe.stale",
                        "That keyframe is no longer in this clip. Select it again."))
            }
            _ = try document.setAnimationKeyframe(
                clipID: clip.id, trackID: track.id, keyframeID: keyframe.id,
                time: keyframe.time, interpolation: keyframe.interpolation,
                timingCurve: curve, clearTimingCurve: false,
                camera: track.target.kind == .camera ? keyframe.camera : nil,
                instance: track.target.kind == .instance ? keyframe.instance : nil,
                replace: true)
            selectedKeyframeID = keyframe.id
            onChanged()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func applyValue(_ request: ValueEditorRequest,
                            camera: CADAnimationCameraValue?,
                            instance: CADAnimationInstanceValue?) {
        do {
            let state = document.animationLoadState()
            guard state.animation.activeClip?.id == request.clipID,
                  let clip = state.animation.clip(withID: request.clipID),
                  let track = clip.tracks.first(where: { $0.id == request.trackID }),
                  let keyframe = track.keyframes.first(where: {
                      $0.id == request.keyframeID
                  }) else {
                throw CADDocumentError(
                    code: "animation_stale_selection",
                    message: FloeCADStrings.text(
                        "cad.animation.keyframe.stale",
                        "That keyframe is no longer in this clip. Select it again."))
            }
            _ = try document.setAnimationKeyframe(
                clipID: clip.id, trackID: track.id, keyframeID: keyframe.id,
                time: keyframe.time, interpolation: keyframe.interpolation,
                timingCurve: keyframe.timingCurve, clearTimingCurve: false,
                camera: camera, instance: instance, replace: true)
            selectedKeyframeID = keyframe.id
            onChanged()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func makeValueRequest(_ clip: CADAnimationClip,
                                  _ track: CADAnimationTrack,
                                  _ keyframe: CADAnimationKeyframe) -> ValueEditorRequest {
        var currentCamera: CADAnimationCameraValue?
        var baseline: CADAnimationInstanceValue?
        switch track.target.kind {
        case .camera:
            currentCamera = playback.cameraValueForKeyframe(handle: handle)
        case .instance:
            if let id = track.target.instanceID {
                baseline = candidates.first(where: { $0.instanceID == id })?.baseline
                    ?? document.animationSceneContext().instances[id]?.baseline
            }
        }
        return ValueEditorRequest(
            clipID: clip.id, trackID: track.id, keyframeID: keyframe.id,
            camera: track.target.kind == .camera ? keyframe.camera : nil,
            instance: track.target.kind == .instance ? keyframe.instance : nil,
            currentCamera: currentCamera,
            baseline: baseline)
    }

    private func currentCameraValue(for clip: CADAnimationClip) -> CADAnimationCameraValue? {
        if let camera = playback.cameraValueForKeyframe(handle: handle) {
            return camera
        }
        if let camera = (try? document.evaluateAnimation(
            clipID: clip.id, time: playback.time))?.camera {
            return camera
        }
        let context = document.animationSceneContext()
        guard context.boundsMinMM != nil, context.boundsMaxMM != nil else { return nil }
        return CADAnimationCameraValue.fitted(
            boundsMinMM: context.boundsMinMM,
            boundsMaxMM: context.boundsMaxMM)
    }

    private func instanceValue(for track: CADAnimationTrack,
                               at time: Double) -> CADAnimationInstanceValue? {
        guard let clip = activeClip, let id = track.target.instanceID else { return nil }
        if let evaluation = try? document.evaluateAnimation(clipID: clip.id, time: time),
           let value = evaluation.instances[id] {
            return value
        }
        if let baseline = candidates.first(where: { $0.instanceID == id })?.baseline {
            return baseline
        }
        return document.animationSceneContext().instances[id]?.baseline
    }

    private func applyReveal() {
        do {
            let clip = try document.applyAnimationPreset(.reveal, clipID: activeClip?.id,
                camera: playback.cameraValueForKeyframe(handle: handle))
            playback.attach(document: document, handle: handle, clipID: clip.id)
            onChanged()
        } catch { errorMessage = error.localizedDescription }
    }

    private func applyTurntable() {
        do {
            let base = playback.cameraValueForKeyframe(handle: handle)
            let clip = try document.applyAnimationPreset(
                .turntable,
                clipID: activeClip?.id,
                camera: base)
            playback.attach(document: document, handle: handle, clipID: clip.id)
            onChanged()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func applyExplode() {
        do {
            let clip = try document.applyAnimationPreset(
                .explodeReturn,
                clipID: activeClip?.id)
            playback.attach(document: document, handle: handle, clipID: clip.id)
            onChanged()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Timing-curve editor

private struct CADAnimationCurveEditorView: View {
    let onSave: (CADAnimationTimingCurve) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var x1: Double
    @State private var y1: Double
    @State private var x2: Double
    @State private var y2: Double

    init(initial: CADAnimationTimingCurve,
         onSave: @escaping (CADAnimationTimingCurve) -> Void) {
        self.onSave = onSave
        _x1 = State(initialValue: initial.x1)
        _y1 = State(initialValue: initial.y1)
        _x2 = State(initialValue: initial.x2)
        _y2 = State(initialValue: initial.y2)
    }

    private var curve: CADAnimationTimingCurve {
        CADAnimationTimingCurve(x1: x1, y1: y1, x2: x2, y2: y2)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    curvePreview
                        .frame(height: 150)
                        .accessibilityIdentifier("CADAnimationCurvePreview")
                    Text(FloeCADStrings.text(
                        "cad.animation.curve.note",
                        "The curve applies from this key to the next key."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Section(FloeCADStrings.text("cad.animation.curve.start", "Start handle")) {
                    curveSlider(
                        title: FloeCADStrings.text("cad.animation.curve.y", "Speed"),
                        value: $y1, range: 0...1,
                        identifier: "CADAnimationCurveY1")
                    curveSlider(
                        title: FloeCADStrings.text("cad.animation.curve.x", "Time"),
                        value: $x1, range: 0...1,
                        identifier: "CADAnimationCurveX1")
                }
                Section(FloeCADStrings.text("cad.animation.curve.end", "End handle")) {
                    curveSlider(
                        title: FloeCADStrings.text("cad.animation.curve.y", "Speed"),
                        value: $y2, range: 0...1,
                        identifier: "CADAnimationCurveY2")
                    curveSlider(
                        title: FloeCADStrings.text("cad.animation.curve.x", "Time"),
                        value: $x2, range: 0...1,
                        identifier: "CADAnimationCurveX2")
                }
                Section {
                    Button(FloeCADStrings.text("cad.animation.curve.reset", "Reset")) {
                        x1 = CADAnimationTimingCurve.defaultCurve.x1
                        y1 = CADAnimationTimingCurve.defaultCurve.y1
                        x2 = CADAnimationTimingCurve.defaultCurve.x2
                        y2 = CADAnimationTimingCurve.defaultCurve.y2
                    }
                    .accessibilityIdentifier("CADAnimationCurveReset")
                }
            }
            .navigationTitle(FloeCADStrings.text("cad.animation.curve.title", "Timing curve"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(FloeCADStrings.text("cad.animation.curve.cancel", "Cancel")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(FloeCADStrings.text("cad.animation.curve.done", "Done")) {
                        onSave(curve)
                        dismiss()
                    }
                    .disabled(!curve.isValid)
                    .accessibilityIdentifier("CADAnimationCurveDone")
                }
            }
        }
        .accessibilityIdentifier("CADAnimationCurveEditor")
    }

    private var curvePreview: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let height = max(proxy.size.height, 1)
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: height * 0.5))
                    path.addLine(to: CGPoint(x: width, y: height * 0.5))
                    path.move(to: CGPoint(x: width * 0.5, y: 0))
                    path.addLine(to: CGPoint(x: width * 0.5, y: height))
                }
                .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
                Path { path in
                    for index in 0...40 {
                        let progress = Double(index) / 40
                        let value = curve.progress(progress)
                        let point = CGPoint(
                            x: progress * width,
                            y: height * (1 - (value + 0.2) / 1.4))
                        if index == 0 {
                            path.move(to: point)
                        } else {
                            path.addLine(to: point)
                        }
                    }
                }
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5,
                                                              lineCap: .round,
                                                              lineJoin: .round))
            }
            .clipped()
        }
    }

    private func curveSlider(title: String,
                             value: Binding<Double>,
                             range: ClosedRange<Double>,
                             identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.2f", value.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
                .accessibilityIdentifier(identifier)
        }
    }
}

// MARK: - Camera value editor

private struct CADAnimationCameraValueEditorView: View {
    let current: CADAnimationCameraValue?
    let onSave: (CADAnimationCameraValue) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var targetX: Double
    @State private var targetY: Double
    @State private var targetZ: Double
    @State private var distance: Double
    @State private var azimuth: Double
    @State private var elevation: Double
    @State private var fov: Double

    init(initial: CADAnimationCameraValue,
         current: CADAnimationCameraValue?,
         onSave: @escaping (CADAnimationCameraValue) -> Void) {
        self.current = current
        self.onSave = onSave
        _targetX = State(initialValue: initial.target.x)
        _targetY = State(initialValue: initial.target.y)
        _targetZ = State(initialValue: initial.target.z)
        _distance = State(initialValue: initial.distance)
        _azimuth = State(initialValue: initial.azimuthRadians * 180 / .pi)
        _elevation = State(initialValue: initial.elevationRadians * 180 / .pi)
        _fov = State(initialValue: initial.fovYDegrees)
    }

    private var value: CADAnimationCameraValue {
        CADAnimationCameraValue(
            target: SIMD3(targetX, targetY, targetZ),
            distance: distance,
            azimuthRadians: azimuth * .pi / 180,
            elevationRadians: elevation * .pi / 180,
            fovYDegrees: fov)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(FloeCADStrings.text(
                    "cad.animation.value.target", "Target (metres)")) {
                    numberRow("X", value: $targetX, identifier: "CADAnimationValueTargetX")
                    numberRow("Y", value: $targetY, identifier: "CADAnimationValueTargetY")
                    numberRow("Z", value: $targetZ, identifier: "CADAnimationValueTargetZ")
                }
                Section(FloeCADStrings.text(
                    "cad.animation.value.camera", "Camera")) {
                    numberRow(FloeCADStrings.text("cad.animation.value.distance", "Distance (metres)"),
                              value: $distance, identifier: "CADAnimationValueDistance")
                    numberRow(FloeCADStrings.text("cad.animation.value.azimuth", "Azimuth (degrees)"),
                              value: $azimuth, identifier: "CADAnimationValueAzimuth")
                    numberRow(FloeCADStrings.text("cad.animation.value.elevation", "Elevation (degrees)"),
                              value: $elevation, identifier: "CADAnimationValueElevation")
                    numberRow(FloeCADStrings.text("cad.animation.value.fov", "Field of view (degrees)"),
                              value: $fov, identifier: "CADAnimationValueFOV")
                }
                if let current {
                    Section {
                        Button(FloeCADStrings.text(
                            "cad.animation.keyframe.capture", "Use current view")) {
                            targetX = current.target.x
                            targetY = current.target.y
                            targetZ = current.target.z
                            distance = current.distance
                            azimuth = current.azimuthRadians * 180 / .pi
                            elevation = current.elevationRadians * 180 / .pi
                            fov = current.fovYDegrees
                        }
                        .accessibilityIdentifier("CADAnimationValueUseCurrent")
                    }
                }
                Section {
                    Text(FloeCADStrings.text(
                        "cad.animation.value.invalid",
                        "Values outside the supported range are refused."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(FloeCADStrings.text(
                "cad.animation.value.title.camera", "Camera value"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(FloeCADStrings.text("cad.animation.value.cancel", "Cancel")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(FloeCADStrings.text("cad.animation.value.save", "Save")) {
                        onSave(value)
                        dismiss()
                    }
                    .disabled(!value.isValid)
                    .accessibilityIdentifier("CADAnimationValueSave")
                }
            }
        }
        .accessibilityIdentifier("CADAnimationValueEditor")
    }

    private func numberRow(_ title: String, value: Binding<Double>,
                           identifier: String) -> some View {
        LabeledContent(title) {
            TextField(title, value: value, format: .number.precision(.fractionLength(0...6)))
                .keyboardType(.numbersAndPunctuation)
                .multilineTextAlignment(.trailing)
                .submitLabel(.done)
                .accessibilityIdentifier(identifier)
        }
    }
}

// MARK: - Part value editor

private struct CADAnimationInstanceValueEditorView: View {
    let baseline: CADAnimationInstanceValue?
    let onSave: (CADAnimationInstanceValue) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var translationX: Double
    @State private var translationY: Double
    @State private var translationZ: Double
    @State private var rotationX: Double
    @State private var rotationY: Double
    @State private var rotationZ: Double

    init(initial: CADAnimationInstanceValue,
         baseline: CADAnimationInstanceValue?,
         onSave: @escaping (CADAnimationInstanceValue) -> Void) {
        self.baseline = baseline
        self.onSave = onSave
        _translationX = State(initialValue: initial.translationMM.x)
        _translationY = State(initialValue: initial.translationMM.y)
        _translationZ = State(initialValue: initial.translationMM.z)
        let euler = CADAnimationQuaternion.eulerDegrees(from: initial.rotation)
        _rotationX = State(initialValue: euler.x)
        _rotationY = State(initialValue: euler.y)
        _rotationZ = State(initialValue: euler.z)
    }

    private var value: CADAnimationInstanceValue {
        CADAnimationInstanceValue(
            translationMM: SIMD3(translationX, translationY, translationZ),
            rotation: CADAnimationQuaternion.fromEulerDegrees(
                SIMD3(rotationX, rotationY, rotationZ)))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(FloeCADStrings.text(
                    "cad.animation.value.translation", "Position (millimetres)")) {
                    numberRow("X", value: $translationX,
                              identifier: "CADAnimationValueTranslationX")
                    numberRow("Y", value: $translationY,
                              identifier: "CADAnimationValueTranslationY")
                    numberRow("Z", value: $translationZ,
                              identifier: "CADAnimationValueTranslationZ")
                }
                Section(FloeCADStrings.text(
                    "cad.animation.value.rotation", "Rotation (degrees)")) {
                    numberRow("X", value: $rotationX,
                              identifier: "CADAnimationValueRotationX")
                    numberRow("Y", value: $rotationY,
                              identifier: "CADAnimationValueRotationY")
                    numberRow("Z", value: $rotationZ,
                              identifier: "CADAnimationValueRotationZ")
                }
                if let baseline {
                    Section {
                        Button(FloeCADStrings.text(
                            "cad.animation.value.useBaseline", "Use current placement")) {
                            translationX = baseline.translationMM.x
                            translationY = baseline.translationMM.y
                            translationZ = baseline.translationMM.z
                            let euler = CADAnimationQuaternion.eulerDegrees(
                                from: baseline.rotation)
                            rotationX = euler.x
                            rotationY = euler.y
                            rotationZ = euler.z
                        }
                        .accessibilityIdentifier("CADAnimationValueUseBaseline")
                    }
                }
                Section {
                    Text(FloeCADStrings.text(
                        "cad.animation.value.invalid",
                        "Values outside the supported range are refused."))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(FloeCADStrings.text(
                "cad.animation.value.title.part", "Part value"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(FloeCADStrings.text("cad.animation.value.cancel", "Cancel")) {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(FloeCADStrings.text("cad.animation.value.save", "Save")) {
                        onSave(value)
                        dismiss()
                    }
                    .disabled(!value.isValid)
                    .accessibilityIdentifier("CADAnimationValueSave")
                }
            }
        }
        .accessibilityIdentifier("CADAnimationValueEditor")
    }

    private func numberRow(_ title: String, value: Binding<Double>,
                           identifier: String) -> some View {
        LabeledContent(title) {
            TextField(title, value: value, format: .number.precision(.fractionLength(0...6)))
                .keyboardType(.numbersAndPunctuation)
                .multilineTextAlignment(.trailing)
                .submitLabel(.done)
                .accessibilityIdentifier(identifier)
        }
    }
}

#endif
