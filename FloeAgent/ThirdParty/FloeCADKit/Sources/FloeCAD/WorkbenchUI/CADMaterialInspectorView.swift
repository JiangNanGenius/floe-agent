//
//  CADMaterialInspectorView.swift
//  FloeCADKit
//
//  Native material inspector: target, surface, textures, mapping and the
//  shared material library. Draft-only editing with a live viewport preview;
//  Apply commits one undoable change and Cancel restores the previous look.
//  Library browsing never mutates the document.
//

#if canImport(SwiftUI) && canImport(UIKit) && canImport(PhotosUI)
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Tabs

private enum CADMaterialLibraryTab: String, CaseIterable, Identifiable {
    case personal
    case document
    case builtIn

    var id: String { rawValue }

    var title: String {
        switch self {
        case .personal:
            return FloeCADStrings.text("cad.material.library.personal", "My Materials")
        case .document:
            return FloeCADStrings.text("cad.material.library.document", "This Document")
        case .builtIn:
            return FloeCADStrings.text("cad.material.library.builtIn", "Built-in")
        }
    }
}

// MARK: - Inspector

struct CADMaterialInspectorView: View {
    @State private var model: CADMaterialDraftModel
    @State private var libraryTab: CADMaterialLibraryTab = .personal
    @State private var searchText = ""
    @State private var pendingTextureSlot: MaterialTextureSlot?
    @State private var photoItem: PhotosPickerItem?
    @State private var showPhotoPicker = false
    @State private var showTextureFileImporter = false
    @State private var showLibraryImporter = false
    @State private var showLibraryExporter = false
    @State private var pendingDeletion: PendingDeletion?
    @State private var renameTarget: PendingRename?
    @State private var renameText = ""
    @State private var exportedPack: MaterialPackDocument?
    @State private var disclosure: Set<String> = []

    @Environment(\.dismiss) private var dismiss
    private let onApplied: () -> Void

    init(document: FloeCADDocument,
         target: CADMaterialTarget,
         previewSink: CADMaterialPreviewSink?,
         onApplied: @escaping () -> Void) {
        let model = CADMaterialDraftModel(document: document, target: target)
        model.previewSink = previewSink
        _model = State(initialValue: model)
        self.onApplied = onApplied
    }

    private struct PendingDeletion: Identifiable {
        let id = UUID()
        let definition: CADMaterialDefinition
        let isPersonal: Bool
    }

    private struct PendingRename: Identifiable {
        let id = UUID()
        let definition: CADMaterialDefinition
        let isPersonal: Bool
    }

    var body: some View {
        NavigationStack {
            Form {
                targetSection
                surfaceSection
                texturesSection
                mappingSection
                librarySection
                issueSection
            }
            .navigationTitle(FloeCADStrings.text("cad.ui.tool.material", "Material"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(FloeCADStrings.text("cad.ui.common.cancel", "Cancel")) {
                        model.cancel()
                        dismiss()
                    }
                    .accessibilityIdentifier("CADMaterialCancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(FloeCADStrings.text("cad.ui.common.apply", "Apply")) {
                        model.apply()
                        if model.errorMessage == nil {
                            onApplied()
                            dismiss()
                        }
                    }
                    .disabled(!model.canApply)
                    .accessibilityIdentifier("CADMaterialApply")
                }
            }
            .onDisappear {
                model.endPreviewOnly()
                model.stopObserving()
            }
            .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem,
                          matching: .images)
            .fileImporter(isPresented: $showTextureFileImporter,
                          allowedContentTypes: [.png, .jpeg, .image],
                          allowsMultipleSelection: false) { result in
                loadTextureFile(result)
            }
            .fileImporter(isPresented: $showLibraryImporter,
                          allowedContentTypes: [.json, .data],
                          allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first, let failure = model.importPersonalPack(from: url) {
                        model.setExternalError(failure)
                    }
                case .failure:
                    model.setExternalError(FloeCADStrings.text(
                        "cad.material.error.readPack",
                        "That material pack could not be read."))
                }
            }
            .fileExporter(isPresented: $showLibraryExporter,
                          document: exportedPack,
                          contentType: .json,
                          defaultFilename: "Floe Materials") { _ in
                exportedPack = nil
            }
            .onChange(of: photoItem) { _, item in
                guard let item, let slot = pendingTextureSlot else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        model.setTexture(slot: slot, data: data,
                                         displayName: item.itemIdentifier)
                    } else {
                        model.setExternalError(FloeCADStrings.text(
                            "cad.material.error.image",
                            "Choose a PNG or JPEG image no larger than 8 MB."))
                    }
                    photoItem = nil
                    pendingTextureSlot = nil
                }
            }
            .alert(item: $pendingDeletion) { pending in
                Alert(
                    title: Text(FloeCADStrings.text("cad.material.delete.title",
                                                    "Delete material?")),
                    message: Text(deleteMessage(pending)),
                    primaryButton: .destructive(
                        Text(FloeCADStrings.text("cad.material.delete.confirm", "Delete"))
                    ) {
                        delete(pending)
                    },
                    secondaryButton: .cancel(
                        Text(FloeCADStrings.text("cad.ui.common.cancel", "Cancel"))))
            }
            .alert(FloeCADStrings.text("cad.material.library.rename", "Rename"),
                   isPresented: Binding(
                    get: { renameTarget != nil },
                    set: { if !$0 { renameTarget = nil } })) {
                TextField(FloeCADStrings.text("cad.material.name", "Name"),
                          text: $renameText)
                Button(FloeCADStrings.text("cad.ui.common.done", "Done")) {
                    if let target = renameTarget {
                        rename(target, to: renameText)
                    }
                    renameTarget = nil
                }
                Button(FloeCADStrings.text("cad.ui.common.cancel", "Cancel"),
                       role: .cancel) { renameTarget = nil }
            } message: {
                Text(FloeCADStrings.text(
                    "cad.material.library.renameMessage",
                    "Materials already applied keep their own copy of the old name."))
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: Target

    private var targetSection: some View {
        Section {
            if model.target.isEmpty {
                Label(FloeCADStrings.text(
                    "cad.material.target.empty",
                    "Select a body or a face in the viewport, then open Material again."),
                      systemImage: "cursorarrow.click.badge.clock")
                    .foregroundStyle(.secondary)
            } else {
                LabeledContent(FloeCADStrings.text("cad.material.target.label", "Selection")) {
                    Text(model.target.title)
                        .multilineTextAlignment(.trailing)
                }
            }
            // The material name belongs to the draft/library, not only to an
            // apply target. Keeping it visible lets a user prepare or import
            // a material before selecting a body; Apply stays disabled until
            // the target is valid.
            TextField(FloeCADStrings.text("cad.material.name", "Name"),
                      text: Binding(get: { model.draft.name },
                                    set: { model.setName($0) }))
                .textInputAutocapitalization(.words)
                .accessibilityIdentifier("CADMaterialNameField")
            if let note = model.target.note {
                Label(note, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text(FloeCADStrings.text("cad.material.section.target", "Selected"))
        }
    }

    // MARK: Surface

    private var surfaceSection: some View {
        Section {
            ColorPicker(FloeCADStrings.text("cad.material.color", "Color"),
                        selection: colorBinding, supportsOpacity: false)
                .accessibilityIdentifier("CADMaterialColor")
            factorRow(FloeCADStrings.text("cad.material.metallic", "Metallic"),
                      value: Binding(get: { model.draft.metallic },
                                     set: { value in model.update { $0.metallic = value } }),
                      identifier: "CADMaterialMetallic")
            factorRow(FloeCADStrings.text("cad.material.roughness", "Roughness"),
                      value: Binding(get: { model.draft.roughness },
                                     set: { value in model.update { $0.roughness = value } }),
                      identifier: "CADMaterialRoughness")
            factorRow(FloeCADStrings.text("cad.material.opacity", "Opacity"),
                      value: Binding(get: { model.draft.opacity },
                                     set: { value in model.update { $0.opacity = value } }),
                      identifier: "CADMaterialOpacity")
            DisclosureGroup(isExpanded: disclosureBinding("emission")) {
                ColorPicker(FloeCADStrings.text("cad.material.emissiveColor", "Emission"),
                            selection: emissiveBinding, supportsOpacity: false)
                    .accessibilityIdentifier("CADMaterialEmissionColor")
                HStack {
                    Text(FloeCADStrings.text("cad.material.emissiveStrength", "Strength"))
                    Slider(value: Binding(
                        get: { min(max(model.draft.emissiveStrength, 0), 10) },
                        set: { value in model.update { $0.emissiveStrength = value } }),
                           in: 0...10)
                        .accessibilityIdentifier("CADMaterialEmissionStrength")
                    Text("\(Int(model.draft.emissiveStrength.rounded()))")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 28, alignment: .trailing)
                }
            } label: {
                Label(FloeCADStrings.text("cad.material.section.emission", "Emission"),
                      systemImage: "sun.max")
            }
        } header: {
            Text(FloeCADStrings.text("cad.material.section.surface", "Surface"))
        }
    }

    // MARK: Textures

    private var texturesSection: some View {
        Section {
            textureRow(.baseColor,
                       title: FloeCADStrings.text("cad.material.texture.color", "Color map"))
            textureRow(.roughness,
                       title: FloeCADStrings.text("cad.material.texture.roughness", "Roughness map"))
            textureRow(.metallic,
                       title: FloeCADStrings.text("cad.material.texture.metallic", "Metallic map"))
            textureRow(.normal,
                       title: FloeCADStrings.text("cad.material.texture.normal", "Normal map"))
            DisclosureGroup(isExpanded: disclosureBinding("advancedTextures")) {
                textureRow(.emissive,
                           title: FloeCADStrings.text("cad.material.texture.emissive", "Emission map"))
                textureRow(.opacity,
                           title: FloeCADStrings.text("cad.material.texture.opacity", "Opacity map"))
            } label: {
                Label(FloeCADStrings.text("cad.material.section.moreTextures", "More maps"),
                      systemImage: "square.stack.3d.down.right")
            }
        } header: {
            Text(FloeCADStrings.text("cad.material.section.textures", "Textures"))
        } footer: {
            if model.draft.textures.contains(where: { $0.sanitized() == nil }) {
                Label(FloeCADStrings.text(
                    "cad.material.error.image",
                    "Choose a PNG or JPEG image no larger than 8 MB."),
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            Text(FloeCADStrings.text(
                "cad.material.texture.presentNote",
                "Full texture detail appears in Present."))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func textureRow(_ slot: MaterialTextureSlot, title: String) -> some View {
        let texture = model.draft.texture(for: slot)
        return HStack(spacing: 12) {
            textureThumbnail(texture)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let texture {
                    if UIImage(data: texture.bytes) != nil {
                        Text(texture.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text(FloeCADStrings.text("cad.material.texture.missing",
                                                 "Image unavailable"))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                } else {
                    Text(FloeCADStrings.text("cad.material.texture.none", "None"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Menu {
                Button {
                    pendingTextureSlot = slot
                    showPhotoPicker = true
                } label: {
                    Label(FloeCADStrings.text("cad.material.texture.photos", "Choose from Photos"),
                          systemImage: "photo.on.rectangle")
                }
                Button {
                    pendingTextureSlot = slot
                    showTextureFileImporter = true
                } label: {
                    Label(FloeCADStrings.text("cad.material.texture.files", "Choose from Files"),
                          systemImage: "folder")
                }
                if let texture {
                    Divider()
                    Button {
                        model.toggleTextureOrientation(slot: slot)
                    } label: {
                        Label(
                            texture.orientation == .topLeft
                                ? FloeCADStrings.text("cad.material.texture.flip",
                                                      "Flip vertically")
                                : FloeCADStrings.text("cad.material.texture.restoreOrientation",
                                                      "Restore orientation"),
                            systemImage: "arrow.up.arrow.down")
                    }
                    Menu {
                        Button(FloeCADStrings.text("cad.material.texture.autoColorSpace",
                                                   "Automatic")) {
                            model.setTextureColorSpace(
                                slot: slot,
                                slot == .baseColor || slot == .emissive ? .srgb : .linear)
                        }
                        Button(FloeCADStrings.text("cad.material.texture.srgb",
                                                   "Colour data")) {
                            model.setTextureColorSpace(slot: slot, .srgb)
                        }
                        Button(FloeCADStrings.text("cad.material.texture.linear",
                                                   "Linear data")) {
                            model.setTextureColorSpace(slot: slot, .linear)
                        }
                    } label: {
                        Label(FloeCADStrings.text("cad.material.texture.colorSpace",
                                                  "Colour space"),
                              systemImage: "circle.lefthalf.filled")
                    }
                    Divider()
                    Button(role: .destructive) {
                        model.removeTexture(slot: slot)
                    } label: {
                        Label(FloeCADStrings.text("cad.material.texture.remove", "Remove"),
                              systemImage: "trash")
                    }
                }
            } label: {
                Image(systemName: texture == nil ? "plus.circle" : "ellipsis.circle")
                    .font(.title3)
            }
            .accessibilityIdentifier("CADMaterialTexture-\(slot.rawValue)")
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func textureThumbnail(_ texture: CADMaterialTexture?) -> some View {
        if let texture, let image = UIImage(data: texture.bytes) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 7))
        } else {
            RoundedRectangle(cornerRadius: 7)
                .fill(Color(uiColor: .secondarySystemFill))
                .frame(width: 44, height: 44)
                .overlay {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                }
        }
    }

    // MARK: Mapping

    private var mappingSection: some View {
        Section {
            Picker(FloeCADStrings.text("cad.material.mapping.source", "Source"), selection: Binding(
                get: { model.draft.uvMapping.source },
                set: { source in
                    var mapping = model.draft.uvMapping
                    mapping.source = source
                    if source != .mesh, mapping.scaleMM.x <= 0 || mapping.scaleMM.y <= 0 {
                        mapping.scaleMM = SIMD2(100, 100)
                    }
                    model.setMapping(mapping)
                })) {
                Text(FloeCADStrings.text("cad.material.mapping.meshUV", "Model UVs"))
                    .tag(MaterialUVSource.mesh)
                Text(FloeCADStrings.text("cad.material.mapping.planar", "Planar"))
                    .tag(MaterialUVSource.planarProjection)
                Text(FloeCADStrings.text("cad.material.mapping.box", "Box"))
                    .tag(MaterialUVSource.boxProjection)
            }
            .accessibilityIdentifier("CADMaterialMappingSource")

            if model.draft.uvMapping.source != .mesh {
                Picker(FloeCADStrings.text("cad.material.mapping.axis", "Projection axis"),
                       selection: Binding(
                        get: { model.draft.uvMapping.axis },
                        set: { axis in
                            var mapping = model.draft.uvMapping
                            mapping.axis = axis
                            model.setMapping(mapping)
                        })) {
                    Text("X").tag(MaterialProjectionAxis.x)
                    Text("Y").tag(MaterialProjectionAxis.y)
                    Text("Z").tag(MaterialProjectionAxis.z)
                }
                .pickerStyle(.segmented)

                mappingNumberRow(FloeCADStrings.text("cad.material.mapping.tile", "Tile size"),
                                 valueX: Binding(
                                    get: { model.draft.uvMapping.scaleMM.x },
                                    set: { value in
                                        var mapping = model.draft.uvMapping
                                        mapping.scaleMM.x = max(value, 0.001)
                                        model.setMapping(mapping)
                                    }),
                                 valueY: Binding(
                                    get: { model.draft.uvMapping.scaleMM.y },
                                    set: { value in
                                        var mapping = model.draft.uvMapping
                                        mapping.scaleMM.y = max(value, 0.001)
                                        model.setMapping(mapping)
                                    }),
                                 suffix: FloeCADStrings.text("cad.unit.mm", "mm"),
                                 identifier: "CADMaterialMappingScale")

                HStack {
                    Text(FloeCADStrings.text("cad.material.mapping.rotation", "Rotation"))
                    Slider(value: Binding(
                        get: { model.draft.uvMapping.rotationDegrees },
                        set: { value in
                            var mapping = model.draft.uvMapping
                            mapping.rotationDegrees = value
                            model.setMapping(mapping)
                        }), in: -180...180)
                    Text("\(Int(model.draft.uvMapping.rotationDegrees.rounded()))°")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 48, alignment: .trailing)
                }

                mappingNumberRow(FloeCADStrings.text("cad.material.mapping.offset", "Offset"),
                                 valueX: Binding(
                                    get: { model.draft.uvMapping.offset.x },
                                    set: { value in
                                        var mapping = model.draft.uvMapping
                                        mapping.offset.x = value
                                        model.setMapping(mapping)
                                    }),
                                 valueY: Binding(
                                    get: { model.draft.uvMapping.offset.y },
                                    set: { value in
                                        var mapping = model.draft.uvMapping
                                        mapping.offset.y = value
                                        model.setMapping(mapping)
                                    }),
                                 suffix: "",
                                 identifier: "CADMaterialMappingOffset")

                Toggle(FloeCADStrings.text("cad.material.mapping.flipU", "Flip U"),
                       isOn: Binding(
                        get: { model.draft.uvMapping.flipU },
                        set: { value in
                            var mapping = model.draft.uvMapping
                            mapping.flipU = value
                            model.setMapping(mapping)
                        }))
                Toggle(FloeCADStrings.text("cad.material.mapping.flipV", "Flip V"),
                       isOn: Binding(
                        get: { model.draft.uvMapping.flipV },
                        set: { value in
                            var mapping = model.draft.uvMapping
                            mapping.flipV = value
                            model.setMapping(mapping)
                        }))
            }
        } header: {
            Text(FloeCADStrings.text("cad.material.section.mapping", "Mapping"))
        } footer: {
            Text(FloeCADStrings.text("cad.material.mapping.note",
                                     "Mapping changes how textures are sampled; it never changes the model geometry."))
        }
    }

    // MARK: Library

    private var librarySection: some View {
        Section {
            Picker(FloeCADStrings.text("cad.material.library.source", "Library"),
                   selection: $libraryTab) {
                ForEach(CADMaterialLibraryTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("CADMaterialLibraryTab")

            TextField(FloeCADStrings.text("cad.material.library.search", "Search"),
                      text: $searchText)
                .textInputAutocapitalization(.never)
                .accessibilityIdentifier("CADMaterialLibrarySearch")

            libraryContent

            HStack(spacing: 12) {
                Button {
                    model.newMaterial()
                } label: {
                    Label(FloeCADStrings.text("cad.material.library.new", "New"),
                          systemImage: "plus")
                }
                .accessibilityIdentifier("CADMaterialLibraryNew")

                Button {
                    model.saveToPersonalLibrary()
                } label: {
                    Label(FloeCADStrings.text("cad.material.library.save", "Save to My Materials"),
                          systemImage: "square.and.arrow.down")
                }
                .accessibilityIdentifier("CADMaterialLibrarySave")
            }
            .buttonStyle(.borderless)

            HStack(spacing: 16) {
                Button {
                    showLibraryImporter = true
                } label: {
                    Label(FloeCADStrings.text("cad.material.library.import", "Import pack"),
                          systemImage: "square.and.arrow.down.on.square")
                }
                Button {
                    if let data = model.exportPersonalPackData() {
                        exportedPack = MaterialPackDocument(data: data)
                        showLibraryExporter = true
                    }
                } label: {
                    Label(FloeCADStrings.text("cad.material.library.export", "Export pack"),
                          systemImage: "square.and.arrow.up")
                }
            }
            .buttonStyle(.borderless)
        } header: {
            Text(FloeCADStrings.text("cad.material.section.library", "Library"))
        } footer: {
            Text(FloeCADStrings.text(
                "cad.material.library.footer",
                "Applying a material copies it into this document. Editing or deleting a library entry never changes models that already use it."))
        }
    }

    @ViewBuilder
    private var libraryContent: some View {
        switch libraryTab {
        case .builtIn:
            materialGrid(MaterialPreset.library
                .filter { preset in
                    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
                    return query.isEmpty
                        || preset.name.localizedCaseInsensitiveContains(query)
                }
                .map {
                CADMaterialLibraryItem(
                    id: "preset-\($0.name)",
                    name: $0.name,
                    definition: CADMaterialDefinition(spec: $0.spec, name: $0.name),
                    origin: .preset($0.name))
            })
        case .personal:
            materialGrid(model.personalLibrary.entries
                .filter(matchesSearch)
                .map { CADMaterialLibraryItem(
                    id: "personal-\($0.id.raw.uuidString)",
                    name: $0.name, definition: $0,
                    origin: .personal($0.id)) })
        case .document:
            materialGrid(model.documentLibrary.entries
                .filter(matchesSearch)
                .map { CADMaterialLibraryItem(
                    id: "document-\($0.id.raw.uuidString)",
                    name: $0.name, definition: $0,
                    origin: .document($0.id)) })
        }
    }

    private func materialGrid(_ items: [CADMaterialLibraryItem]) -> some View {
        Group {
            if items.isEmpty {
                Text(FloeCADStrings.text("cad.material.library.empty", "No materials yet."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 12)],
                          spacing: 12) {
                    ForEach(items) { item in
                        materialCard(item)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func materialCard(_ item: CADMaterialLibraryItem) -> some View {
        let selected = isSelected(item)
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                model.select(item.definition, origin: item.origin)
            } label: {
                VStack(spacing: 4) {
                    if let image = CADMaterialThumbnailCache.shared.image(
                        for: item.definition) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    } else {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(uiColor: .secondarySystemFill))
                            .frame(height: 64)
                    }
                    Text(item.name)
                        .font(.callout)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .foregroundStyle(.primary)
                }
                .frame(maxWidth: .infinity)
                .padding(6)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(uiColor: .secondarySystemBackground))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(selected ? Color.accentColor : .clear,
                                        lineWidth: 2)))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("CADMaterialItem-\(item.name)")
            .contextMenu {
                Button {
                    model.select(item.definition, origin: item.origin)
                } label: {
                    Label(FloeCADStrings.text("cad.material.library.use", "Use"),
                          systemImage: "checkmark.circle")
                }
                Button {
                    model.select(item.definition, origin: item.origin)
                    model.duplicateCurrent()
                } label: {
                    Label(FloeCADStrings.text("cad.material.library.duplicate", "Duplicate"),
                          systemImage: "plus.square.on.square")
                }
                if case .document = item.origin {
                    Button {
                        renameTarget = PendingRename(definition: item.definition,
                                                     isPersonal: false)
                        renameText = item.definition.name
                    } label: {
                        Label(FloeCADStrings.text("cad.material.library.rename", "Rename"),
                              systemImage: "pencil")
                    }
                }
                if case .personal = item.origin {
                    Button {
                        renameTarget = PendingRename(definition: item.definition,
                                                     isPersonal: true)
                        renameText = item.definition.name
                    } label: {
                        Label(FloeCADStrings.text("cad.material.library.rename", "Rename"),
                              systemImage: "pencil")
                    }
                }
                if !isBuiltIn(item) {
                    Button(role: .destructive) {
                        pendingDeletion = PendingDeletion(
                            definition: item.definition, isPersonal: {
                                if case .personal = item.origin { return true }
                                return false
                            }())
                    } label: {
                        Label(FloeCADStrings.text("cad.ui.common.delete", "Delete"),
                              systemImage: "trash")
                    }
                }
            }
        }
    }

    private func isBuiltIn(_ item: CADMaterialLibraryItem) -> Bool {
        if case .preset = item.origin { return true }
        return false
    }

    private func isSelected(_ item: CADMaterialLibraryItem) -> Bool {
        switch (item.origin, model.origin) {
        case (.document(let a), .document(let b)): return a == b
        case (.personal(let a), .personal(let b)): return a == b
        case (.preset(let a), .preset(let b)): return a == b
        default: return false
        }
    }

    private func matchesSearch(_ definition: CADMaterialDefinition) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return definition.name.localizedCaseInsensitiveContains(query)
    }

    // MARK: Issues

    @ViewBuilder
    private var issueSection: some View {
        if !model.staleBindings.isEmpty || model.errorMessage != nil
            || model.statusMessage != nil {
            Section {
                if let error = model.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
                ForEach(Array(model.faceRangeWarnings.enumerated()), id: \.offset) { item in
                    Label(item.element, systemImage: "square.stack.3d.up.slash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let status = model.statusMessage {
                    Label(status, systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                }
                Button {
                    model.removeStaleFaceBindings()
                } label: {
                    Label(FloeCADStrings.text("cad.material.stale.remove",
                                              "Remove stale assignments"),
                          systemImage: "trash.slash")
                }
                .accessibilityIdentifier("CADMaterialRemoveStale")
                ForEach(Array(model.staleBindings.enumerated()), id: \.offset) { item in
                    let binding = item.element
                    VStack(alignment: .leading, spacing: 4) {
                        Label(binding.bodyName, systemImage: "square.stack.3d.up.slash")
                            .font(.footnote.weight(.semibold))
                        Text(binding.reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(FloeCADStrings.text(
                            "cad.material.reselect",
                            "Reselect the face in the viewport to assign a new material."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text(FloeCADStrings.text("cad.material.section.issues", "Details"))
            }
        }
    }

    // MARK: Bindings / helpers

    private var colorBinding: Binding<Color> {
        Binding(
            get: {
                Color(red: model.draft.baseColor.x, green: model.draft.baseColor.y,
                      blue: model.draft.baseColor.z)
            },
            set: { color in
                var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 1
                UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
                model.update {
                    $0.baseColor = SIMD4(Double(red), Double(green), Double(blue),
                                         $0.baseColor.w)
                }
            })
    }

    private var emissiveBinding: Binding<Color> {
        Binding(
            get: {
                Color(red: model.draft.emissive.x, green: model.draft.emissive.y,
                      blue: model.draft.emissive.z)
            },
            set: { color in
                var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 1
                UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
                model.update {
                    $0.emissive = SIMD3(Double(red), Double(green), Double(blue))
                    if $0.emissiveStrength == 0 { $0.emissiveStrength = 1 }
                }
            })
    }

    private func factorRow(_ title: String, value: Binding<Double>,
                           identifier: String) -> some View {
        HStack {
            Text(title)
            Slider(value: value, in: 0...1)
                .accessibilityIdentifier("\(identifier)Slider")
            Text("\(Int((value.wrappedValue * 100).rounded()))%")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, alignment: .trailing)
                .accessibilityIdentifier("\(identifier)Value")
        }
    }

    private func mappingNumberRow(_ title: String, valueX: Binding<Double>,
                                  valueY: Binding<Double>, suffix: String,
                                  identifier: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
            TextField("U", value: valueX, format: .number.precision(.fractionLength(0...3)))
                .textFieldStyle(.roundedBorder)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .accessibilityIdentifier("\(identifier)U")
            TextField("V", value: valueY, format: .number.precision(.fractionLength(0...3)))
                .textFieldStyle(.roundedBorder)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .accessibilityIdentifier("\(identifier)V")
            if !suffix.isEmpty {
                Text(suffix).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func disclosureBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { disclosure.contains(key) },
            set: { expanded in
                if expanded { disclosure.insert(key) } else { disclosure.remove(key) }
            })
    }

    // MARK: File actions

    private func loadTextureFile(_ result: Result<[URL], Error>) {
        guard let slot = pendingTextureSlot else { return }
        defer { pendingTextureSlot = nil }
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                model.setExternalError(FloeCADStrings.text(
                    "cad.material.error.image",
                    "Choose a PNG or JPEG image no larger than 8 MB."))
                return
            }
            model.setTexture(slot: slot, data: data,
                             displayName: url.deletingPathExtension().lastPathComponent)
        case .failure:
            model.setExternalError(FloeCADStrings.text(
                "cad.material.error.image",
                "Choose a PNG or JPEG image no larger than 8 MB."))
        }
    }

    private func deleteMessage(_ pending: PendingDeletion) -> String {
        let references = pending.isPersonal
            ? 0 : model.appliedReferenceCount(pending.definition.id)
        if references > 0 {
            return FloeCADStrings.format(
                "cad.material.delete.inUse",
                "This material is used in %d place(s). Deleting the library entry does not change those models.",
                references)
        }
        return FloeCADStrings.text(
            "cad.material.delete.message",
            "This removes the library entry. Materials already applied keep their own copy.")
    }

    private func delete(_ pending: PendingDeletion) {
        if pending.isPersonal {
            if let failure = model.deletePersonalEntry(pending.definition.id) {
                model.setExternalError(failure)
            }
        } else {
            let result = model.deleteDocumentEntry(pending.definition.id)
            if let error = result.error {
                model.setExternalError(error)
            } else if result.references > 0 {
                model.setExternalNote(FloeCADStrings.format(
                    "cad.material.deleted.inUse",
                    "Removed from the library. %d applied appearance(s) are unchanged.",
                    result.references))
            }
        }
    }

    private func rename(_ pending: PendingRename, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if pending.isPersonal {
            var definition = pending.definition
            definition.name = CADMaterialDefinition.sanitizedName(trimmed)
            definition.revision += 1
            definition.updatedAt = Date()
            if let failure = model.personalStore.upsert(definition) {
                model.setExternalError(failure)
            } else {
                model.refreshLibraries()
            }
        } else if let failure = model.renameDocumentEntry(pending.definition.id,
                                                          to: trimmed) {
            model.setExternalError(failure)
        }
    }
}

// MARK: - Support

private struct CADMaterialLibraryItem: Identifiable {
    let id: String
    let name: String
    let definition: CADMaterialDefinition
    let origin: CADMaterialOrigin
}

// MARK: - Pack export

struct MaterialPackDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

#endif
