// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import FloeWorkbench

struct MediaV2VideoColorInspector: View {
    @Bindable var session: MediaV2Session
    let onImport: () -> Void
    @State private var draft = MediaVideoGrade()
    @State private var tone = "midtones"
    @State private var qualifierExpanded = true
    @State private var correctionExpanded = true
    @State private var importing = false
    @State private var readingLUT = false
    private static let identityCurve: [ImageFreehandStroke.Point] = [.init(x:0,y:0),.init(x:0.25,y:0.25),.init(x:0.5,y:0.5),.init(x:0.75,y:0.75),.init(x:1,y:1)]
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            MediaV2VisualClipTarget(session: session, onImport: onImport)
            if session.selectedClip?.track.kind == .visual {
                VStack(alignment: .leading, spacing: 14) {
                    controls
                    MediaV2InspectorApplyButton(title: WorkbenchText.t("应用到所选片段", "Apply to selected clip"),isWorking: session.saving,action: apply)
                        .disabled(readingLUT)
                    Button(WorkbenchText.t("移除此调整", "Remove this adjustment"),systemImage: "arrow.uturn.backward") { run(reset: true) }
                        .frame(minHeight: 44).disabled(!hasSavedAdjustment)
                }.disabled(session.saving || session.selectedClip?.track.isLocked == true)
            }
        }.onAppear(perform: load)
            .onChange(of: session.selectedClipID) { _,_ in load() }
            .onChange(of: session.selectedClip?.clip.revision) { _,_ in load() }
            .onChange(of: session.tool) { _,_ in load() }
            .fileImporter(isPresented: $importing,allowedContentTypes: [.plainText,.data],onCompletion: importLUT)
    }
    @ViewBuilder private var controls: some View {
        switch session.tool {
        case "video.video-curves":
            MediaV2ToneCurveEditor(points: Binding(get: { draft.toneCurve ?? Self.identityCurve },set: { draft.toneCurve = $0 })).frame(height: 180)
            Text(WorkbenchText.t("拖动控制点调整画面明暗。", "Drag control points to adjust image tones.")).font(.caption).foregroundStyle(.secondary)
            Button(WorkbenchText.t("重置曲线", "Reset curve"),systemImage: "arrow.counterclockwise") { draft.toneCurve = Self.identityCurve }.frame(minHeight: 44)
        case "video.wheels":
            Picker(WorkbenchText.t("色调范围", "Tonal range"),selection: $tone) {
                Text(WorkbenchText.t("阴影", "Shadows")).tag("shadows")
                Text(WorkbenchText.t("中间调", "Midtones")).tag("midtones")
                Text(WorkbenchText.t("高光", "Highlights")).tag("highlights")
            }.pickerStyle(.segmented)
            MediaV2TonalColorWheel(value: Binding(get: { selectedBalance },set: setSelectedBalance))
            Toggle(WorkbenchText.t("保持亮度", "Preserve luminance"),isOn: Binding(get: { draft.colorBalance?.preserveLuminance ?? true },set: { var balance = draft.colorBalance ?? .init();balance.preserveLuminance = $0;draft.colorBalance = balance })).frame(minHeight: 44)
            Button(WorkbenchText.t("重置当前色轮", "Reset this wheel"),systemImage: "arrow.counterclockwise") { setSelectedBalance(.init()) }.frame(minHeight: 44)
        case "video.video-hsl":
            DisclosureGroup(isExpanded: $qualifierExpanded) {
                VStack(alignment: .leading,spacing: 10) {
                    ColorPicker(WorkbenchText.t("目标色相", "Target hue"),selection: Binding(get: { Color(hue: secondary.hueCenter/360,saturation: 1,brightness: 1) },set: { color in
                        var h: CGFloat = 0,s: CGFloat = 0,b: CGFloat = 0,a: CGFloat = 0
                        UIColor(color).getHue(&h,saturation: &s,brightness: &b,alpha: &a);updateSecondary(\.hueCenter,Double(h)*360)
                    }),supportsOpacity: false).frame(minHeight: 44)
                    slider(WorkbenchText.t("色相宽度", "Hue width"),\.hueWidth,0...180,suffix: "°")
                    slider(WorkbenchText.t("色相柔化", "Hue softness"),\.hueFeather,0...90,suffix: "°")
                    rangeControls(WorkbenchText.t("饱和度范围", "Saturation range"),lower: \.saturationMin,upper: \.saturationMax)
                    rangeControls(WorkbenchText.t("亮度范围", "Lightness range"),lower: \.lightnessMin,upper: \.lightnessMax)
                    slider(WorkbenchText.t("范围柔化", "Range softness"),\.rangeFeather,0...0.25)
                }.padding(.top,10)
            } label: { Label(WorkbenchText.t("选色范围", "Color qualifier"),systemImage: "eyedropper") }
            DisclosureGroup(isExpanded: $correctionExpanded) {
                VStack(spacing: 10) {
                    slider(WorkbenchText.t("色相偏移", "Hue shift"),\.hueShift,-180...180,suffix: "°")
                    slider(WorkbenchText.t("饱和度", "Saturation"),\.saturationScale,0...2,suffix: "×")
                    slider(WorkbenchText.t("亮度偏移", "Lightness shift"),\.lightnessShift,-1...1)
                    slider(WorkbenchText.t("混合强度", "Mix"),\.mix,0...1)
                }.padding(.top,10)
            } label: { Label(WorkbenchText.t("范围内调整", "Qualified adjustment"),systemImage: "slider.horizontal.3") }
        default:
            Picker(WorkbenchText.t("滤镜", "Filter"),selection: Binding(get: { draft.filterID ?? "CIPhotoEffectChrome" },set: { draft.filterID = $0;draft.colorLUT = nil;draft.lutName = nil })) {
                Text(WorkbenchText.t("鲜艳", "Chrome")).tag("CIPhotoEffectChrome")
                Text(WorkbenchText.t("黑白", "Mono")).tag("CIPhotoEffectMono")
                Text(WorkbenchText.t("黑色电影", "Noir")).tag("CIPhotoEffectNoir")
                Text(WorkbenchText.t("褪色", "Fade")).tag("CIPhotoEffectFade")
                Text(WorkbenchText.t("即时成像", "Instant")).tag("CIPhotoEffectInstant")
                Text(WorkbenchText.t("棕褐色", "Sepia")).tag("CISepiaTone")
            }.disabled(draft.colorLUT != nil)
            if draft.colorLUT != nil {
                Label(draft.lutName ?? WorkbenchText.t("自定义 LUT", "Custom LUT"),systemImage: "checkmark.circle.fill").font(.subheadline).lineLimit(2)
                Button(WorkbenchText.t("改用内置滤镜", "Use built-in filter"),systemImage: "slider.horizontal.3") { draft.colorLUT = nil;draft.lutName = nil;draft.filterID = "CIPhotoEffectChrome" }.frame(minHeight: 44)
            }
            Button(WorkbenchText.t("导入 .cube LUT", "Import .cube LUT"),systemImage: "doc.badge.plus") { importing = true }.frame(minHeight: 44).disabled(readingLUT)
            if readingLUT { ProgressView(WorkbenchText.t("正在读取 LUT…", "Reading LUT…")) }
        }
    }
    private var secondary: MediaHSLSecondary { draft.secondary ?? .init() }
    private func updateSecondary(_ key: WritableKeyPath<MediaHSLSecondary,Double>,_ value: Double) {
        var q = secondary;q[keyPath: key] = value;draft.secondary = q
    }
    private func slider(_ title: String,_ key: WritableKeyPath<MediaHSLSecondary,Double>,_ range: ClosedRange<Double>,suffix: String = "") -> some View {
        MusicValueSlider(title: title,value: secondary[keyPath: key],range: range,suffix: suffix) { updateSecondary(key,$0) }
    }
    private func rangeControls(_ title: String,lower: WritableKeyPath<MediaHSLSecondary,Double>,upper: WritableKeyPath<MediaHSLSecondary,Double>) -> some View {
        VStack(alignment: .leading,spacing: 6) {
            Text(title).font(.caption.weight(.medium))
            MusicValueSlider(title: WorkbenchText.t("最低", "Minimum"),value: secondary[keyPath: lower],range: 0...1) { value in
                var q = secondary;q[keyPath: lower] = value;q[keyPath: upper] = max(value,q[keyPath: upper]);draft.secondary = q
            }
            MusicValueSlider(title: WorkbenchText.t("最高", "Maximum"),value: secondary[keyPath: upper],range: 0...1) { value in
                var q = secondary;q[keyPath: upper] = value;q[keyPath: lower] = min(value,q[keyPath: lower]);draft.secondary = q
            }
        }
    }
    private var selectedBalance: ImageRGBBalance {
        let b = draft.colorBalance ?? .init();return tone == "shadows" ? b.shadows : tone == "highlights" ? b.highlights : b.midtones
    }
    private func setSelectedBalance(_ value: ImageRGBBalance) {
        var b = draft.colorBalance ?? .init()
        if tone == "shadows" { b.shadows = value } else if tone == "highlights" { b.highlights = value } else { b.midtones = value };draft.colorBalance = b
    }
    private var hasSavedAdjustment: Bool {
        let grade = session.selectedClip?.clip.videoGrade
        switch session.tool { case "video.video-curves": return grade?.toneCurve != nil;case "video.wheels": return grade?.colorBalance != nil;case "video.video-hsl": return grade?.secondary != nil;default: return grade?.filterID != nil || grade?.colorLUT != nil }
    }
    private func load() { draft = session.selectedClip?.clip.videoGrade ?? .init() }
    private func apply() {
        if session.tool == "video.video-curves",draft.toneCurve == nil { draft.toneCurve = Self.identityCurve }
        if session.tool == "video.wheels",draft.colorBalance == nil { draft.colorBalance = .init() }
        if session.tool == "video.video-hsl",draft.secondary == nil { draft.secondary = .init() }
        if session.tool == "video.video-lut",draft.filterID == nil,draft.colorLUT == nil { draft.filterID = "CIPhotoEffectChrome" }
        run(reset: false)
    }
    private func run(reset: Bool) {
        var input = MediaV2ToolInput();input.objectID = session.selectedClipID;input.expectedRevision = session.document.revision;input.videoGrade = draft;input.flag = !reset
        let tool = session.tool
        Task { do { _ = try await session.performTool(tool,input: input) } catch { session.diagnostic = error.localizedDescription } }
    }
    private func importLUT(_ result: Result<URL,any Error>) {
        do {
            let url = try result.get();guard url.pathExtension.lowercased() == "cube" else { throw MediaV2CommandError.invalidInput }
            let scoped = url.startAccessingSecurityScopedResource();defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let bytes = try Data(contentsOf: url,options: .mappedIfSafe)
            guard bytes.count <= 2_097_152,let text = String(data: bytes,encoding: .utf8) else { throw MediaV2CommandError.invalidInput }
            let clipID = session.selectedClipID,revision = session.document.revision,name = url.lastPathComponent
            readingLUT = true
            Task {
                defer { readingLUT = false }
                do {
                    let worker = Task.detached(priority: .utility) { try ImageColorLUT.parseCube(text) };let lut = try await worker.value
                    guard session.selectedClipID == clipID,session.document.revision == revision else { return }
                    draft.colorLUT = lut;draft.filterID = nil;draft.lutName = name
                } catch { session.diagnostic = error.localizedDescription }
            }
        } catch { session.diagnostic = error.localizedDescription }
    }
}
#endif
