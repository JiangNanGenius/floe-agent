// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import FloeGameEditingCore
import FloeGameEditingUI
import FloeGameSpriteCore

struct SpriteAnimationPreview: View {
    @ObservedObject var model: SpriteEditorDocument
    @Environment(\.gameEditLocale) private var locale
    @Environment(\.dynamicTypeSize) private var typeSize

    private var canAnimate: Bool {
        model.animationSequence?.isAnimatable == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(SpriteUICopy.animationPreview.text(locale)).font(.subheadline.weight(.semibold))
                    if let frame = model.layout?.descriptor(at: model.highlightedFrameIndex) {
                        Text(frame.title(locale))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if let sequence = model.animationSequence {
                    Text("\(sequence.frameCount) × \(Int(model.clampedFramesPerSecond.rounded())) fps")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    preview.frame(height: 144)
                    playButton
                    speedStepper
                }
            } else {
                HStack(spacing: 8) {
                    preview.frame(width: 112, height: 112)
                    VStack(alignment: .leading, spacing: 4) {
                        playButton
                        speedStepper
                    }
                    .frame(maxWidth: .infinity)
                }
            }

            if !canAnimate {
                Text(SpriteUICopy.oneFrame.text(locale))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: model.isPlaying) {
            await model.runPlaybackLoop()
        }
        .onDisappear {
            model.stopPlayback()
        }
    }

    private var preview: some View {
        ZStack {
            SpriteCheckerboard(square: 8)
            if let image = model.previewFrameImage {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
            } else {
                ProgressView()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary, lineWidth: 1))
        .accessibilityElement()
        .accessibilityLabel(SpriteUICopy.animationPreview.text(locale))
        .accessibilityIdentifier("game.sprite.animation.preview")
    }

    private var playButton: some View {
        Button {
            model.togglePlayback()
        } label: {
            Label {
                Text(model.isPlaying ? SpriteUICopy.stop.text(locale)
                                     : SpriteUICopy.play.text(locale))
            } icon: {
                Image(systemName: model.isPlaying ? "stop.fill" : "play.fill")
            }
            .frame(minWidth: 88, minHeight: 44)
        }
        .buttonStyle(.borderless)
        .disabled(!canAnimate)
        .accessibilityIdentifier("game.sprite.animation.play")
    }

    private var speedStepper: some View {
        Stepper(value: Binding(
            get: { model.framesPerSecond },
            set: { model.framesPerSecond = min(max($0, 1), 30) }),
            in: 1...30, step: 1) {
            Text("\(Int(model.clampedFramesPerSecond.rounded())) fps")
                .font(.caption.monospacedDigit())
                .frame(minWidth: 54, minHeight: 44)
        }
        .accessibilityIdentifier("game.sprite.animation.speed")
        .controlSize(.small)
    }
}
