#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UIKit

/// The sheet owns its confirmation/dismissal. Preparing only creates a
/// recoverable value; Use Textures performs one atomic draft replacement.
struct CADTextureImportReviewView: View {
    let model: CADMaterialDraftModel
    let review: CADTextureImport.Review
    @State private var choices: [UUID: CADTextureImport.Choice] = [:]
    @State private var slots: [UUID: MaterialTextureSlot] = [:]
    @State private var budget: CADTextureImport.Budget?
    @State private var budgetError: String?
    @Environment(\.dismiss) private var dismiss

    private var selections: [CADTextureImport.Selection] {
        let allSlots = MaterialTextureSlot.allCases
        let start = allSlots.firstIndex(of: review.startingSlot) ?? 0
        return review.sources.enumerated().map { offset, source in
            .init(source: source,
                  slot: slots[source.id] ?? allSlots[(start + offset) % allSlots.count],
                  choice: choices[source.id] ?? (review.descriptors[offset].canKeepOriginal ? .original : .choose))
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if let prepared = model.preparedTextureImport {
                    readBackSection(prepared)
                } else {
                    choicesSection
                }
                budgetSection
                if let message = model.textureImportError ?? budgetError {
                    Section {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("CADTextureImportError")
                    }
                }
                Section {
                    if model.isImportingTextures {
                        ProgressView(FloeCADStrings.text("cad.textureImport.preparing", "Preparing preview…"))
                    } else if model.preparedTextureImport != nil {
                        Button(FloeCADStrings.text("cad.textureImport.revise", "Change import options")) {
                            model.reviseTextureImport()
                        }
                    } else {
                        Button(FloeCADStrings.text("cad.textureImport.preview", "Prepare preview")) {
                            model.prepareTextureImport(selections)
                        }
                        .disabled(budget?.fits != true || budgetError != nil)
                        .accessibilityIdentifier("CADTextureImportPrepare")
                    }
                } footer: {
                    Text(FloeCADStrings.text("cad.textureImport.copyNote", "Next, apply the material to your selection."))
                }
            }
            .navigationTitle(FloeCADStrings.text("cad.textureImport.title", "Import textures"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(FloeCADStrings.text("cad.ui.common.cancel", "Cancel")) {
                        model.cancelTextureImport()
                        dismiss()
                    }
                    .accessibilityIdentifier("CADTextureImportCancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(FloeCADStrings.text("cad.textureImport.use", "Use textures")) {
                        if model.acceptPreparedTextureImport() { dismiss() }
                    }
                    .disabled(model.preparedTextureImport == nil || model.isImportingTextures)
                    .accessibilityIdentifier("CADTextureImportUse")
                }
            }
            .task(id: selections) { refreshBudget() }
        }
        .interactiveDismissDisabled(model.isImportingTextures)
    }

    private var choicesSection: some View {
        Section {
            ForEach(Array(review.sources.enumerated()), id: \.element.id) { offset, source in
                let descriptor = review.descriptors[offset]
                VStack(alignment: .leading, spacing: 8) {
                    Text(source.name).font(.headline).lineLimit(2)
                    Text("\(descriptor.width) × \(descriptor.height) · \(descriptor.depth)-bit · \(Self.bytes(descriptor.encodedBytes))")
                        .font(.caption).foregroundStyle(.secondary)
                    if !descriptor.profile.isEmpty {
                        Text(descriptor.profile).font(.caption).foregroundStyle(.secondary)
                    }
                    Picker(FloeCADStrings.text("cad.textureImport.channel", "Texture channel"),
                           selection: slotBinding(source.id, offset: offset)) {
                        ForEach(MaterialTextureSlot.allCases, id: \.self) { slot in
                            Text(Self.slotTitle(slot)).tag(slot)
                        }
                    }
                    .pickerStyle(.menu)
                    .buttonStyle(.borderless)
                    .menuActionDismissBehavior(.enabled)
                    .accessibilityIdentifier("CADTextureImportChannel-\(offset)")
                    Picker(FloeCADStrings.text("cad.textureImport.option", "Import option"),
                           selection: choiceBinding(source.id, descriptor: descriptor)) {
                        Text(FloeCADStrings.text("cad.textureImport.choose", "Choose an option")).tag(CADTextureImport.Choice.choose)
                        if descriptor.canKeepOriginal {
                            Text(FloeCADStrings.text("cad.textureImport.original", "Keep original")).tag(CADTextureImport.Choice.original)
                        }
                        ForEach(CADTextureImport.Choice.allCases.filter { $0.maximumDimension != nil }, id: \.self) { choice in
                            Text(FloeCADStrings.format("cad.textureImport.pngSize", "8-bit PNG · up to %d px", choice.maximumDimension ?? 0)).tag(choice)
                        }
                    }
                    .pickerStyle(.menu)
                    .buttonStyle(.borderless)
                    .menuActionDismissBehavior(.enabled)
                    .accessibilityIdentifier("CADTextureImportChoice-\(offset)")
                }
                .disabled(model.isImportingTextures)
            }
        } footer: {
            Text(FloeCADStrings.text("cad.textureImport.conversionNote", "PNG conversion may reduce size and precision. Transparency is kept and photo orientation is applied. Color maps use sRGB; other channels keep their data values. Review the result before using it."))
        }
    }

    private func readBackSection(_ prepared: CADTextureImport.Prepared) -> some View {
        Section {
            ForEach(prepared.receipts) { receipt in
                HStack(alignment: .top, spacing: 12) {
                    if let image = UIImage(data: receipt.readBackPreviewPNG) {
                        Image(uiImage: image).resizable().scaledToFit()
                            .frame(width: 96, height: 96)
                            .background(.quaternary)
                            .accessibilityLabel(receipt.sourceName)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(receipt.sourceName).lineLimit(2)
                        Text(Self.slotTitle(receipt.slot)).font(.caption)
                        Text("\(receipt.width) × \(receipt.height) · \(Self.bytes(receipt.byteCount))")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(receipt.converted
                             ? FloeCADStrings.text("cad.textureImport.converted", "Converted PNG")
                             : FloeCADStrings.text("cad.textureImport.original", "Keep original"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text(FloeCADStrings.text("cad.textureImport.readBack", "Preview"))
        }
    }

    private var budgetSection: some View {
        Section {
            if let current = model.preparedTextureImport?.budget ?? budget {
                LabeledContent(FloeCADStrings.text("cad.textureImport.memoryUse", "Texture memory"),
                               value: "\(Self.bytes(current.residentBytes)) / \(Self.bytes(CADTextureImport.maximumResidentBytes))")
                DisclosureGroup(FloeCADStrings.text("cad.textureImport.details", "Details")) {
                    LabeledContent(FloeCADStrings.text("cad.textureImport.decoded", "Decoded images"), value: Self.bytes(current.decodedBytes))
                    LabeledContent(FloeCADStrings.text("cad.textureImport.resident", "Images with mip levels"), value: Self.bytes(current.residentBytes))
                    LabeledContent(FloeCADStrings.text("cad.textureImport.working", "Estimated import memory"), value: Self.bytes(current.workingBytes))
                }
            }
        } header: {
            Text(FloeCADStrings.text("cad.textureImport.budget", "Texture memory"))
        } footer: {
            Text(FloeCADStrings.text("cad.textureImport.budgetNote", "Includes textures already in use. Choose smaller sizes if needed."))
        }
    }

    private func refreshBudget() {
        do {
            let value = try model.estimateTextureImport(selections)
            budget = value
            budgetError = value.fits ? nil : CADTextureImport.Failure.memoryBudget.localizedDescription
        } catch {
            budget = nil
            budgetError = error.localizedDescription
        }
    }

    private func choiceBinding(_ id: UUID, descriptor: CADTextureImport.Descriptor) -> Binding<CADTextureImport.Choice> {
        Binding(get: { choices[id] ?? (descriptor.canKeepOriginal ? .original : .choose) },
                set: { choices[id] = $0 })
    }

    private func slotBinding(_ id: UUID, offset: Int) -> Binding<MaterialTextureSlot> {
        let cases = MaterialTextureSlot.allCases
        let start = cases.firstIndex(of: review.startingSlot) ?? 0
        return Binding(get: { slots[id] ?? cases[(start + offset) % cases.count] }, set: { slots[id] = $0 })
    }

    private static func bytes(_ value: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(value), countStyle: .memory)
    }

    private static func slotTitle(_ slot: MaterialTextureSlot) -> String {
        switch slot {
        case .baseColor: return FloeCADStrings.text("cad.material.texture.color", "Color map")
        case .roughness: return FloeCADStrings.text("cad.material.texture.roughness", "Roughness map")
        case .metallic: return FloeCADStrings.text("cad.material.texture.metallic", "Metallic map")
        case .normal: return FloeCADStrings.text("cad.material.texture.normal", "Normal map")
        case .emissive: return FloeCADStrings.text("cad.material.texture.emissive", "Emission map")
        case .opacity: return FloeCADStrings.text("cad.material.texture.opacity", "Opacity map")
        }
    }
}
#endif
