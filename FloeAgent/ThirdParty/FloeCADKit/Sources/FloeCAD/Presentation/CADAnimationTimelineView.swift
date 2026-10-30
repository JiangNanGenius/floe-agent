//
//  CADAnimationTimelineView.swift
//  FloeCADKit
//
//  Native Present timeline: clip selection, play/pause/stop, scrub, loop,
//  speed, editable duration, camera keyframe capture and the turntable /
//  explode-return presets. Authored changes go through the document's ordinary
//  undoable animation commands; playback and scrubbing stay transient.
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
    let onChanged: () -> Void

    @State private var durationText = ""
    @State private var errorMessage: String?

    private var activeClip: CADAnimationClip? {
        state.animation.activeClip
    }

    private var issues: [CADAnimationIssue] {
        state.issues + playback.issues
    }

    var body: some View {
        VStack(spacing: 8) {
            header
            if let clip = activeClip {
                transport(clip)
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
        .accessibilityIdentifier("CADAnimationTimeline")
        .onAppear { syncDurationText() }
        .onChange(of: activeClip?.id) { _, _ in syncDurationText() }
        .onChange(of: activeClip?.duration) { _, _ in syncDurationText() }
        .alert(FloeCADStrings.text("cad.animation.edit.failed", "Couldn't update the animation"),
               isPresented: Binding(get: { errorMessage != nil },
                                    set: { if !$0 { errorMessage = nil } })) {
            Button(FloeCADStrings.text("cad.ui.common.done", "Done")) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
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
                Button {
                    createClip()
                } label: {
                    Label(FloeCADStrings.text("cad.animation.newClip", "New clip"),
                          systemImage: "plus")
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

    // MARK: Editing

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

            Button {
                captureCameraKeyframe(clip)
            } label: {
                Label(FloeCADStrings.text("cad.animation.keyframe.add", "Keyframe"),
                      systemImage: "camera")
                    .font(.caption.weight(.medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityIdentifier("CADAnimationKeyframe")
        }
    }

    private var timeLabel: String {
        String(format: "%.2f / %.2f s", playback.time,
               activeClip?.duration ?? 0)
    }

    private func speedLabel(_ value: Double) -> String {
        value == floor(value) ? "\(Int(value))×" : "\(value)×"
    }

    // MARK: Actions

    private func syncDurationText() {
        guard let clip = activeClip else { durationText = ""; return }
        durationText = String(format: "%.1f", clip.duration)
    }

    private func createClip() {
        do {
            let clip = try document.createAnimationClip(
                name: nil, duration: nil)
            playback.attach(document: document, handle: handle, clipID: clip.id)
            onChanged()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func selectClip(_ id: UUID) {
        do {
            _ = try document.setActiveAnimationClip(id: id)
            playback.attach(document: document, handle: handle, clipID: id)
            onChanged()
        } catch {
            errorMessage = error.localizedDescription
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

    private func captureCameraKeyframe(_ clip: CADAnimationClip) {
        guard let camera = playback.cameraValueForKeyframe(handle: handle) else {
            errorMessage = FloeCADStrings.text(
                "cad.animation.keyframe.noCamera",
                "Show Present before adding a camera keyframe.")
            return
        }
        do {
            _ = try document.setAnimationCameraKeyframe(
                clipID: clip.id, time: playback.time, camera: camera)
            onChanged()
        } catch {
            errorMessage = error.localizedDescription
        }
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

#endif
