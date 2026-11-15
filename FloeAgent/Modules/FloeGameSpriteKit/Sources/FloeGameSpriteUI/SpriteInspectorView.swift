// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import Foundation
import FloeGameEditingCore
import FloeGameEditingUI
import FloeGameSpriteCore

struct SpriteInspectorView: View {
    @ObservedObject var model: SpriteEditorDocument
    var scrolls: Bool = true
    @Environment(\.gameEditLocale) private var locale
    @Environment(\.dynamicTypeSize) private var typeSize

    @State private var columnsText = ""
    @State private var rowsText = ""
    @State private var showRotationDialog = false

    var body: some View {
        Group {
            if scrolls {
                ScrollView { content }
            } else {
                content
            }
        }
        .background(GameEditorSurfaces.sidebar)
        .onAppear { synchronizeGridFields() }
        .onChange(of: model.layout) { _, _ in synchronizeGridFields() }
        .confirmationDialog(
            locale == .chinese ? "旋转整张图集？" : "Rotate the whole sheet?",
            isPresented: $showRotationDialog,
            titleVisibility: .visible) {
                Button(SpriteUICopy.rotateRight.text(locale)) {
                    Task { await model.rotateClockwise() }
                }
                Button(SpriteUICopy.rotateLeft.text(locale)) {
                    Task { await model.rotateCounterclockwise() }
                }
                Button(SpriteUICopy.cancel.text(locale), role: .cancel) { }
            } message: {
                Text(SpriteUICopy.rotateWarning.text(locale))
            }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("game.sprite.inspector")
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            colorSection
            Divider()
            brushSection
            Divider()
            gridSection
            Divider()
            SpriteAnimationPreview(model: model)
            Divider()
            transformSection
            Divider()
            infoSection
        }
        .padding(12)
        .font(.callout)
        .buttonBorderShape(.roundedRectangle(radius: 8))
    }

    // MARK: - Color and brush

    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ColorPicker(selection: Binding(
                    get: { SpriteColorBridge.color(model.color) },
                    set: { model.setColorRGB(SpriteColorBridge.rgba($0)) }),
                    supportsOpacity: false) {
                    Text(SpriteUICopy.color.text(locale))
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("game.sprite.color")
                Text("#\(model.color.hexString)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                Text(SpriteUICopy.opacity.text(locale)).font(.caption)
                Slider(value: Binding(
                    get: { Double(model.color.alpha) },
                    set: { model.setColorAlpha(UInt8(min(max($0, 0), 255).rounded())) }),
                    in: 0...255)
                    .accessibilityIdentifier("game.sprite.opacity")
                Text("\(model.color.alpha)")
                    .font(.caption2.monospacedDigit())
                    .frame(minWidth: 32, alignment: .trailing)
            }
            .frame(minHeight: 44)
        }
    }

    private var brushSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(SpriteUICopy.tools.text(locale)).font(.subheadline.weight(.semibold))
            Stepper(value: Binding(
                get: { model.brushSize },
                set: { model.brushSize = min(max($0, 1), 8) }),
                in: 1...8) {
                HStack {
                    Text(SpriteUICopy.brushSize.text(locale))
                    Spacer()
                    Text("\(model.clampedBrushSize) px")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .frame(minHeight: 44)
            }
            .accessibilityIdentifier("game.sprite.brushSize")

            Toggle(isOn: $model.fingerDrawingEnabled) {
                Text(SpriteUICopy.fingerDrawing.text(locale))
                    .frame(minHeight: 44)
            }
            .accessibilityIdentifier("game.sprite.fingerDrawing.toggle")
            .help(SpriteUICopy.fingerDrawingHelp.text(locale))
            if !model.fingerDrawingEnabled {
                Text(locale == .chinese ? "手指移动画布，Pencil 绘制。" : "Finger navigates; Pencil draws.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            Toggle(isOn: $model.showsGrid) {
                Text(SpriteUICopy.grid.text(locale))
                    .frame(minHeight: 44)
            }
            .accessibilityIdentifier("game.sprite.grid.toggle")
        }
    }

    // MARK: - Frame grid

    private var gridSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent(SpriteUICopy.preset.text(locale)) {
                Picker(SpriteUICopy.preset.text(locale), selection: presetBinding) {
                    Text(locale == .chinese ? "自定义" : "Custom").tag(SpriteSheetPreset.custom)
                    ForEach(SpriteSheetPreset.allCases.filter { $0 != .custom }, id: \.self) { preset in
                        Text(presetName(preset)).tag(preset)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(minHeight: 44)
                .accessibilityIdentifier("game.sprite.preset")
            }

            if let layout = model.layout, layout.preset.supportsFullSheet {
                Picker(SpriteUICopy.scope.text(locale), selection: scopeBinding) {
                    ForEach(SpriteSheetScope.allCases, id: \.self) { scope in
                        Text(scope.title.text(locale)).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .frame(minHeight: 44)
                .accessibilityIdentifier("game.sprite.scope")
            }

            if let layout = model.layout {
                Text(locale == .chinese
                     ? "图片 \(layout.pixelSize.width) × \(layout.pixelSize.height) · 帧 \(layout.frameWidth) × \(layout.frameHeight) · \(layout.columns) 列 × \(layout.rows) 行"
                     : "Image \(layout.pixelSize.width) × \(layout.pixelSize.height) · frame \(layout.frameWidth) × \(layout.frameHeight) · \(layout.columns) × \(layout.rows)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("game.sprite.grid.summary")
            }

            if typeSize.isAccessibilitySize {
                VStack(spacing: 8) {
                    columnsField
                    rowsField
                    gridButtons
                }
            } else {
                HStack(spacing: 8) {
                    columnsField
                    rowsField
                }
                gridButtons
            }
            Button {
                Task { await model.addSelectedFrameAsAsset() }
            } label: {
                Label(locale == .chinese ? "提取当前帧为素材" : "Add frame as asset",
                      systemImage: "square.and.arrow.down.on.square")
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderless)
            .disabled(!model.canEditImage || model.activeStroke != nil)
            .accessibilityIdentifier("game.sprite.frame.addAsset")
            Text(SpriteUICopy.customGridHelp.text(locale))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var columnsField: some View {
        HStack(spacing: 8) {
            Text(locale == .chinese ? "列" : "Cols").foregroundStyle(.secondary)
            TextField(SpriteUICopy.columns.text(locale), text: $columnsText)
            .textFieldStyle(.roundedBorder)
            .frame(minHeight: 44)
            #if os(iOS)
            .keyboardType(.numberPad)
            #endif
            .accessibilityIdentifier("game.sprite.grid.columns")
        }
    }

    private var rowsField: some View {
        HStack(spacing: 8) {
            Text(locale == .chinese ? "行" : "Rows").foregroundStyle(.secondary)
            TextField(SpriteUICopy.rows.text(locale), text: $rowsText)
            .textFieldStyle(.roundedBorder)
            .frame(minHeight: 44)
            #if os(iOS)
            .keyboardType(.numberPad)
            #endif
            .accessibilityIdentifier("game.sprite.grid.rows")
        }
    }

    @ViewBuilder private var gridButtons: some View {
        if typeSize.isAccessibilitySize {
            VStack(spacing: 8) {
                applyGridButton
                detectGridButton
            }
        } else {
            HStack(spacing: 8) {
                applyGridButton
                detectGridButton
            }
        }
    }

    private var applyGridButton: some View {
        Button {
            guard let columns = Int(columnsText), let rows = Int(rowsText) else { return }
            model.applyCustomGrid(columns: columns, rows: rows)
        } label: {
            Label(locale == .chinese ? "应用" : "Apply", systemImage: "checkmark")
                .frame(minWidth: 88, minHeight: 44)
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("game.sprite.grid.apply")
    }

    private var detectGridButton: some View {
        Button {
            model.useDetectedLayout()
        } label: {
            Label(locale == .chinese ? "自动识别" : "Detect", systemImage: "viewfinder")
                .frame(minWidth: 88, minHeight: 44)
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier("game.sprite.grid.detect")
    }

    private var presetBinding: Binding<SpriteSheetPreset> {
        Binding(
            get: { model.layout?.preset ?? .custom },
            set: { preset in
                if preset == .custom {
                    guard let layout = model.layout else { return }
                    model.applyCustomGrid(columns: layout.columns, rows: layout.rows)
                } else {
                    let preferredScope: SpriteSheetScope =
                        preset.supportsFullSheet && model.layout?.scope == .fullSheet
                        ? .fullSheet : .character
                    model.applyPreset(preset, scope: preferredScope)
                }
            })
    }

    private var scopeBinding: Binding<SpriteSheetScope> {
        Binding(
            get: { model.layout?.scope ?? .character },
            set: { scope in
                guard let preset = model.layout?.preset, preset != .custom else { return }
                model.applyPreset(preset, scope: scope)
            })
    }

    private func synchronizeGridFields() {
        guard let layout = model.layout else { return }
        columnsText = "\(layout.columns)"
        rowsText = "\(layout.rows)"
    }

    // MARK: - Transform

    private func presetName(_ preset: SpriteSheetPreset) -> String {
        switch preset {
        case .custom: return locale == .chinese ? "自定义" : "Custom"
        case .rpgMakerXP: return "RPG Maker XP"
        case .rpgMakerVX: return "RPG Maker VX"
        case .rpgMakerVXAce: return "RPG Maker VX Ace"
        case .rpgMakerMV: return "RPG Maker MV"
        case .rpgMakerMZ: return "RPG Maker MZ"
        }
    }

    private var transformSection: some View {
        DisclosureGroup(locale == .chinese ? "图像操作" : "Image actions") {
            LazyVGrid(columns: transformColumns, spacing: 8) {
                transformButton(SpriteUICopy.flipH, systemImage: "arrow.left.and.right") {
                    Task { await model.flipHorizontally() }
                }
                .accessibilityIdentifier("game.sprite.flipH")
                transformButton(SpriteUICopy.flipV, systemImage: "arrow.up.and.down") {
                    Task { await model.flipVertically() }
                }
                .accessibilityIdentifier("game.sprite.flipV")
                transformButton(SpriteUICopy.rotateLeft, systemImage: "rotate.left") {
                    showRotationDialog = true
                }
                .accessibilityIdentifier("game.sprite.rotateLeft")
                transformButton(SpriteUICopy.rotateRight, systemImage: "rotate.right") {
                    showRotationDialog = true
                }
                .accessibilityIdentifier("game.sprite.rotateRight")
            }
            Text(SpriteUICopy.rotateWarning.text(locale))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var transformColumns: [GridItem] {
        typeSize.isAccessibilitySize
            ? [GridItem(.flexible())]
            : [GridItem(.flexible()), GridItem(.flexible())]
    }

    private func transformButton(_ title: GameEditCopy, systemImage: String,
                                 action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label {
                Text(title.text(locale))
            } icon: {
                Image(systemName: systemImage)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderless)
        .disabled(!model.canEditImage || model.image == nil)
    }

    // MARK: - Info

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let image = model.image {
                Text(locale == .chinese
                     ? "PNG \(image.width) × \(image.height) · \(ByteCountFormatter.string(fromByteCount: Int64(image.byteCount), countStyle: .memory))"
                     : "PNG \(image.width) × \(image.height) · \(ByteCountFormatter.string(fromByteCount: Int64(image.byteCount), countStyle: .memory))")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("game.sprite.image.info")
            }
        }
    }
}
