// SPDX-License-Identifier: MPL-2.0
#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct CADLightingInspectorSections: View {
    @Binding var draft: CADViewAppearance
    let onPreview: () -> Void
    @State private var choosingImage = false
    @State private var importing = false
    @State private var importID = UUID()
    @State private var importTask: Task<Void,Never>?
    @State private var problem: String?

    var body: some View {
        Group {
            Section {
                if let map = draft.environmentMap {
                    LabeledContent(FloeCADStrings.text("cad.environment.image", "Environment image"),value:map.name)
                    HStack {
                        Text(FloeCADStrings.text("cad.environment.rotation", "Rotation"))
                        TextField("°",value:mapNumber(\.rotationDegrees),format:.number)
                            .keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("CADEnvironmentMapRotation")
                        Text("°").foregroundStyle(.secondary)
                    }
                    HStack {
                        Text(FloeCADStrings.text("cad.environment.brightness", "Brightness"))
                        Slider(value:mapNumber(\.intensity),in:0...16)
                            .accessibilityIdentifier("CADEnvironmentMapIntensity")
                        Text(map.intensity,format:.number.precision(.fractionLength(1)))
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    Toggle(FloeCADStrings.text("cad.environment.showImage", "Show as background"),isOn:Binding(
                        get:{ draft.environmentMap?.showsBackground ?? false },
                        set:{ draft.environmentMap?.showsBackground = $0; onPreview() }))
                        .accessibilityIdentifier("CADEnvironmentMapBackground")
                    Button(FloeCADStrings.text("cad.environment.removeImage", "Remove image"),role:.destructive) {
                        cancelImport(); draft.environmentMap = nil; onPreview()
                    }.accessibilityIdentifier("CADEnvironmentMapRemove")
                }
                Button {
                    choosingImage = true
                } label: {
                    Label(FloeCADStrings.text("cad.environment.importImage", "Import environment image"),systemImage:"photo.badge.plus")
                }.accessibilityIdentifier("CADEnvironmentMapImport")
                if importing { ProgressView(FloeCADStrings.text("cad.environment.importing", "Importing image…")) }
            } header: { Text(FloeCADStrings.text("cad.environment.image", "Environment image")) }

            Section {
                ForEach(draft.sceneLights ?? []) { light in
                    NavigationLink {
                        CADSceneLightEditor(light:lightBinding(light)) { previewIfValid() }
                    } label: {
                        HStack {
                            Image(systemName:light.enabled ? "lightbulb.fill" : "lightbulb.slash")
                            Text(light.name)
                            Spacer()
                            Text(Self.kindName(light.kind)).foregroundStyle(.secondary)
                        }
                    }.accessibilityIdentifier("CADSceneLight-\(light.id.uuidString)")
                }.onDelete { offsets in
                    var lights = draft.sceneLights ?? []; lights.remove(atOffsets:offsets)
                    draft.sceneLights = lights; onPreview()
                }
                Menu {
                    ForEach(CADSceneLight.Kind.allCases,id:\.self) { kind in
                        Button(Self.kindName(kind)) {
                            var lights = draft.sceneLights ?? []
                            let name = FloeCADStrings.format("cad.lights.numberedName", "Light %@",lights.count+1)
                            lights.append(CADSceneLight(name:name,kind:kind))
                            draft.sceneLights = lights; onPreview()
                        }
                    }
                } label: { Label(FloeCADStrings.text("cad.lights.add", "Add light"),systemImage:"plus") }
                .disabled((draft.sceneLights?.count ?? 0) >= CADSceneLight.maximumCount)
                .accessibilityIdentifier("CADSceneLightAdd")
                if draft.sceneLights != nil {
                    Button(FloeCADStrings.text("cad.lights.usePreset", "Use preset lights")) {
                        draft.sceneLights = nil; onPreview()
                    }.accessibilityIdentifier("CADSceneLightsUsePreset")
                }
            } header: { Text(FloeCADStrings.text("cad.lights.title", "Scene lights")) }
        }
        .fileImporter(isPresented:$choosingImage,allowedContentTypes:[.image,.data]) { result in
            switch result {
            case .success(let url): importImage(url)
            case .failure(let error): if !(error is CancellationError) { problem = error.localizedDescription }
            }
        }
        .alert(FloeCADStrings.text("cad.environment.title", "Environment"),isPresented:Binding(
            get:{ problem != nil },set:{ if !$0 { problem = nil } })) {
                Button(FloeCADStrings.text("cad.ui.common.ok", "OK"),role:.cancel) { problem = nil }
            } message: { Text(problem ?? "") }
        .onDisappear { cancelImport() }
    }

    private func mapNumber(_ path:WritableKeyPath<CADEnvironmentMap,Double>) -> Binding<Double> {
        Binding(get:{ let v = draft.environmentMap?[keyPath:path] ?? 0; return v.isFinite ? v : 0 },set:{ value in
            draft.environmentMap?[keyPath:path] = value; previewIfValid()
        })
    }
    private func lightBinding(_ fallback:CADSceneLight) -> Binding<CADSceneLight> {
        Binding(get:{ draft.sceneLights?.first { $0.id == fallback.id } ?? fallback },set:{ value in
            guard let index = draft.sceneLights?.firstIndex(where:{ $0.id == fallback.id }) else { return }
            draft.sceneLights?[index] = value
        })
    }
    private func previewIfValid() {
        do { try CADSceneLight.validate(draft.sceneLights); try draft.environmentMap?.validate(); onPreview() }
        catch { /* Keep the last valid preview while a value is being edited. */ }
    }
    private func cancelImport() { importID = UUID(); importTask?.cancel(); importTask = nil; importing = false }
    private func importImage(_ url:URL) {
        cancelImport(); let id = UUID(); importID = id; importing = true
        importTask = Task { @MainActor in
            let worker = Task.detached(priority:.userInitiated) {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let file = try FileHandle(forReadingFrom:url); defer { try? file.close() }
                var bytes = Data()
                while true {
                    try Task.checkCancellation()
                    let part = try file.read(upToCount:1024*1024) ?? Data()
                    if part.isEmpty { break }
                    guard bytes.count <= CADEnvironmentMap.maximumEncodedBytes - part.count else { throw CADSceneLightingError.mapTooLarge }
                    bytes.append(part)
                }
                return try CADEnvironmentMap.imported(data:bytes,name:url.lastPathComponent)
            }
            do {
                let map = try await withTaskCancellationHandler { try await worker.value } onCancel:{ worker.cancel() }
                guard importID == id, !Task.isCancelled else { return }
                draft.environmentMap = map; onPreview()
            } catch {
                if importID == id, !Task.isCancelled, !(error is CancellationError) { problem = error.localizedDescription }
            }
            if importID == id { importing = false; importTask = nil }
        }
    }
    static func kindName(_ kind:CADSceneLight.Kind) -> String {
        switch kind {
        case .directional: FloeCADStrings.text("cad.lights.directional", "Directional")
        case .point: FloeCADStrings.text("cad.lights.point", "Point")
        case .spot: FloeCADStrings.text("cad.lights.spot", "Spot")
        }
    }
}

private struct CADSceneLightEditor: View {
    @Binding var light:CADSceneLight
    let onPreview:()->Void
    var body: some View {
        Form {
            Section {
                TextField(FloeCADStrings.text("cad.lights.name", "Name"),text:$light.name)
                    .accessibilityIdentifier("CADSceneLightName")
                Toggle(FloeCADStrings.text("cad.lights.enabled", "Enabled"),isOn:$light.enabled)
                ColorPicker(FloeCADStrings.text("cad.lights.color", "Colour"),selection:color,supportsOpacity:false)
                number(FloeCADStrings.text("cad.environment.brightness", "Brightness"),path:\.intensity)
            }
            if light.kind != .directional {
                Section(FloeCADStrings.text("cad.lights.position", "Position (mm)")) { vector(\.positionMM) }
                Section { number(FloeCADStrings.text("cad.lights.reach", "Reach (mm)"),path:\.radiusMM) }
            }
            if light.kind != .point {
                Section(FloeCADStrings.text("cad.lights.direction", "Direction")) { vector(\.direction) }
                Section { Toggle(FloeCADStrings.text("cad.environment.shadows", "Shadows"),isOn:$light.castsShadow) }
            }
            if light.kind == .spot {
                Section {
                    number(FloeCADStrings.text("cad.lights.innerAngle", "Inner angle (°)"),path:\.innerAngleDegrees)
                    number(FloeCADStrings.text("cad.lights.outerAngle", "Outer angle (°)"),path:\.outerAngleDegrees)
                }
            }
        }
        .navigationTitle(light.name).navigationBarTitleDisplayMode(.inline)
        .onChange(of:light) { _,_ in onPreview() }
    }
    private var color:Binding<Color> {
        Binding(get:{ Color(red:channel(0),green:channel(1),blue:channel(2)) },set:{ value in
            var r:CGFloat=0,g:CGFloat=0,b:CGFloat=0,a:CGFloat=0
            guard UIColor(value).getRed(&r,green:&g,blue:&b,alpha:&a) else { return }
            light.color = [Double(r),Double(g),Double(b)]
        })
    }
    private func channel(_ index:Int) -> Double {
        guard light.color.indices.contains(index), light.color[index].isFinite else { return 1 }
        return min(max(light.color[index],0),1)
    }
    private func number(_ title:String,path:WritableKeyPath<CADSceneLight,Double>) -> some View {
        HStack { Text(title); Spacer(); TextField(title,value:Binding(
            get:{ light[keyPath:path] },set:{ light[keyPath:path] = $0 }),format:.number)
            .keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing) }
    }
    @ViewBuilder private func vector(_ path:WritableKeyPath<CADSceneLight,[Double]>) -> some View {
        ForEach(0..<3,id:\.self) { index in
            HStack { Text(["X","Y","Z"][index]); Spacer(); TextField(["X","Y","Z"][index],value:Binding(
                get:{ light[keyPath:path].indices.contains(index) ? light[keyPath:path][index] : 0 },set:{ value in
                    var vector = light[keyPath:path]
                    if vector.count != 3 { vector = [0,0,0] }
                    vector[index] = value; light[keyPath:path] = vector
                }),format:.number)
                .keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing) }
        }
    }
}
#endif
