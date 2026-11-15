// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import FloeGameEditingCore
import FloeGameEditingUI
import FloeGameSpriteCore

struct SpriteFrameSidebar: View {
    @ObservedObject var model: SpriteEditorDocument
    @Environment(\.gameEditLocale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(SpriteUICopy.frames.text(locale)).font(.headline)
                    if let layout = model.layout {
                        Text(locale == .chinese
                             ? "\(layout.frameCount) 帧 · \(layout.preset.title.zh)"
                             : "\(layout.frameCount) frames · \(layout.preset.title.en)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                if model.hasUnsavedChanges {
                    Text(SpriteUICopy.edited.text(locale))
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.18), in: Capsule())
                        .accessibilityIdentifier("game.sprite.edited")
                }
            }
            .padding(10)
            Divider()
            if let layout = model.layout {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                        ForEach(layout.frameGroups()) { group in
                            Section {
                                ForEach(group.frameIndices, id: \.self) { index in
                                    frameRow(index, layout: layout)
                                }
                            } header: {
                                if let character = group.characterIndex {
                                    Text(locale == .chinese ? "角色 \(character + 1)" : "Character \(character + 1)")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .background(.thinMaterial)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(GameEditorSurfaces.sidebar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("game.sprite.frames")
    }

    private func frameRow(_ index: Int, layout: SpriteSheetLayout) -> some View {
        let selected = index == model.selectedFrameIndex
        return Button {
            model.selectFrame(index)
        } label: {
            HStack(spacing: 8) {
                SpriteFrameThumbnail(image: model.frameImage(at: index), size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(layout.descriptor(at: index)?.title(locale)
                         ?? (locale == .chinese ? "帧 \(index + 1)" : "Frame \(index + 1)"))
                        .font(.callout)
                        .lineLimit(1)
                    Text("\(layout.frameWidth) × \(layout.frameHeight) px")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .background(selected ? Color.accentColor.opacity(0.12) : Color.clear)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(layout.descriptor(at: index)?.title(locale) ?? "Frame \(index + 1)")
        .accessibilityIdentifier("game.sprite.frame.\(index)")
    }
}

struct SpriteFrameStrip: View {
    @ObservedObject var model: SpriteEditorDocument
    @Environment(\.gameEditLocale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(SpriteUICopy.frames.text(locale)).font(.caption.weight(.semibold))
                Spacer()
                if let frame = model.selectedFrame {
                    Text(frame.title(locale)).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            if let layout = model.layout {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 4) {
                        ForEach(0..<layout.frameCount, id: \.self) { index in
                            Button {
                                model.selectFrame(index)
                            } label: {
                                SpriteFrameThumbnail(image: model.frameImage(at: index), size: 44)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 5)
                                            .stroke(index == model.selectedFrameIndex
                                                    ? Color.accentColor : Color.clear,
                                                    lineWidth: 2))
                                    .frame(minWidth: 44, minHeight: 44)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(layout.descriptor(at: index)?.title(locale)
                                ?? (locale == .chinese ? "帧 \(index + 1)" : "Frame \(index + 1)"))
                            .accessibilityAddTraits(index == model.selectedFrameIndex ? .isSelected : [])
                            .accessibilityIdentifier("game.sprite.strip.frame.\(index)")
                        }
                    }
                    .padding(.horizontal, 10)
                }
                .frame(height: 54)
            }
        }
        .padding(.vertical, 4)
        .background(GameEditorSurfaces.sidebar)
    }
}
