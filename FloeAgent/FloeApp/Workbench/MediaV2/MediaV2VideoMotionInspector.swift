// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeWorkbench

struct MediaV2VideoMotionInspector: View {
    @Bindable var session: MediaV2Session
    let onImport: () -> Void
    @State private var pickingRegion = false
    @State private var region: NormalizedRect?
    @State private var smoothing = 0.3
    @State private var strength = 1.0
    @State private var cropEdges = true
    @State private var confidence = 0.3
    @State private var details = false
    private var tracking: Bool { session.tool == "video.tracking" }
    private var validTarget: Bool {
        session.selectedClip?.track.kind == .visual && session.selectedClip?.clip.assetID.flatMap { session.document.asset($0)?.kind } == .video
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            MediaV2VisualClipTarget(session: session, onImport: onImport)
            if validTarget, let selected = session.selectedClip {
                if tracking {
                    Button { pickingRegion = true } label: {
                        Label(region == nil ? WorkbenchText.t("选择跟踪对象", "Select object to track") : WorkbenchText.t("重新框选对象", "Choose another object"),systemImage: "viewfinder")
                            .frame(maxWidth: .infinity,minHeight: 44)
                    }.buttonStyle(.bordered)
                    Text(WorkbenchText.t("从片段的第一个源画面开始跟踪。", "Tracking starts at the first source frame of this clip."))
                        .font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup(WorkbenchText.t("跟踪设置", "Tracking settings")) {
                        MusicValueSlider(title: WorkbenchText.t("最低置信度", "Minimum confidence"),value: confidence,range: 0.05...0.95,suffix: "") { confidence = $0 }
                    }
                    if let saved = selected.clip.videoTracking {
                        trackingResults(saved, clip: selected.clip)
                    }
                } else {
                    MusicValueSlider(title: WorkbenchText.t("平滑时长", "Smoothing window"),value: smoothing,range: 0.05...2,suffix: "s") { smoothing = $0 }
                    MusicValueSlider(title: WorkbenchText.t("防抖强度", "Stabilization strength"),value: strength,range: 0...1,suffix: "") { strength = $0 }
                    Toggle(WorkbenchText.t("自动裁去边缘", "Crop moving edges"),isOn: $cropEdges).frame(minHeight: 44)
                    if !cropEdges {
                        Text(WorkbenchText.t("保留全部画面，移动边缘可能露出背景。", "Keeps the whole frame; moving edges may reveal the background."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let saved = selected.clip.stabilization {
                        LabeledContent(WorkbenchText.t("已应用", "Applied"),value: "\(saved.samples.count) " + WorkbenchText.t("帧", "frames"))
                        if saved.cropEdges { LabeledContent(WorkbenchText.t("裁边缩放", "Crop scale"),value: saved.cropScale.formatted(.number.precision(.fractionLength(2))) + "×") }
                    }
                }
                if session.processingTool {
                    ProgressView(session.providerStatus ?? WorkbenchText.t("正在分析…", "Analyzing…"))
                    Button(WorkbenchText.t("取消", "Cancel"),systemImage: "xmark.circle") { session.cancelToolProcessing() }.frame(minHeight: 44)
                } else {
                    MediaV2InspectorApplyButton(title: tracking ? WorkbenchText.t("开始跟踪", "Track object") : WorkbenchText.t("分析并应用防抖", "Analyze and stabilize"),isWorking: session.saving) { run(clear: false) }
                        .disabled(selected.track.isLocked || session.rendering || (tracking && region == nil))
                    if (tracking ? selected.clip.videoTracking != nil : selected.clip.stabilization != nil) {
                        Button(tracking ? WorkbenchText.t("清除跟踪结果", "Clear tracking") : WorkbenchText.t("移除防抖", "Remove stabilization"),systemImage: "arrow.uturn.backward") { run(clear: true) }
                            .frame(minHeight: 44).disabled(selected.track.isLocked || session.saving)
                    }
                }
                Text(WorkbenchText.t("每次分析最长两分钟；原视频始终保留。", "Analyze up to two minutes at a time. Your original video is preserved."))
                    .font(.caption).foregroundStyle(.secondary)
            } else if session.selectedClip != nil {
                Label(WorkbenchText.t("请选择视频素材片段", "Select a video source clip"),systemImage: "film").foregroundStyle(.secondary)
            }
        }.sheet(isPresented: $pickingRegion) {
            if let selected = session.selectedClip, let assetID = selected.clip.assetID,
               let url = try? session.resolvedAssets()[assetID] {
                MediaV2TrackingRegionPicker(url: url,sourceSeconds: selected.clip.sourceRange.startSeconds,initial: region) { selectedRegion in
                    region = selectedRegion; pickingRegion = false
                }
            } else {
                NavigationStack {
                    ContentUnavailableView { Label(WorkbenchText.t("素材暂不可用", "Source unavailable"),systemImage: "film") }
                        description: { Text(WorkbenchText.t("请重新导入视频素材后再选择对象。", "Import the video source again, then select the object.")) }
                        actions: { Button(WorkbenchText.t("导入素材", "Import media")) { pickingRegion = false;onImport() } }
                        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(WorkbenchText.t("关闭", "Close")) { pickingRegion = false } } }
                }
            }
        }.onAppear(perform: load)
            .onChange(of: session.selectedClipID) { _,_ in pickingRegion = false;region = nil;load() }
            .onChange(of: session.tool) { _,_ in load() }
    }
    private func trackingResults(_ saved: MediaVideoTracking,clip: MediaPreparedClip) -> some View {
        VStack(alignment: .leading,spacing: 10) {
            Label(WorkbenchText.t("跟踪结果已保存", "Tracking saved"),systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
            let lost = saved.samples.filter { $0.state == .lost }.count
            if lost > 0 {
                Label(WorkbenchText.t("部分画面跟踪丢失，请检查后重新框选。", "Tracking was lost in some frames. Review the result or select the object again."),systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            Slider(value: Binding(get: { min(clip.timelineRange.endSeconds,max(clip.timelineRange.startSeconds,session.playhead)) },set: { session.scrub($0) }),
                in: clip.timelineRange.startSeconds...clip.timelineRange.endSeconds)
                .accessibilityLabel(WorkbenchText.t("检查跟踪位置", "Review tracked position"))
            DisclosureGroup(WorkbenchText.t("查看采样结果", "View observations"),isExpanded: $details) {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(Array(saved.samples.enumerated()),id: \.offset) { _,sample in
                            HStack {
                                Text(sample.sourceSeconds,format: .number.precision(.fractionLength(2))).monospacedDigit()
                                Spacer()
                                Text(sample.state == .seed ? WorkbenchText.t("起点", "Start") : sample.state == .lost ? WorkbenchText.t("丢失", "Lost") : sample.confidence.formatted(.percent.precision(.fractionLength(0))))
                                    .foregroundStyle(sample.state == .lost ? Color.orange : Color.secondary)
                            }.font(.caption)
                        }
                    }
                }.frame(maxHeight: 180)
            }
        }
    }
    private func load() {
        if let saved = session.selectedClip?.clip.stabilization { smoothing = saved.smoothingSeconds;strength = saved.strength;cropEdges = saved.cropEdges }
        if let saved = session.selectedClip?.clip.videoTracking { confidence = saved.minimumConfidence;region = saved.samples.first?.region }
    }
    private func run(clear: Bool) {
        var input = MediaV2ToolInput();input.objectID = session.selectedClipID;input.expectedRevision = session.document.revision
        if clear { input.property = "clear" }
        else if tracking {
            guard let region else { return }
            input.points = [.init(x: region.x,y: region.y),.init(x: region.x+region.width,y: region.y+region.height)]
            input.number = confidence;input.secondary = 15
        } else { input.number = smoothing;input.secondary = strength;input.flag = cropEdges }
        let tool = session.tool
        Task { do { _ = try await session.performTool(tool,input: input) } catch { session.diagnostic = error.localizedDescription } }
    }
}

private struct MediaV2TrackingRegionPicker: View {
    let url: URL
    let sourceSeconds: Double
    let initial: NormalizedRect?
    let onApply: (NormalizedRect) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var image: CGImage?
    @State private var region: NormalizedRect?
    @State private var error: String?
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text(WorkbenchText.t("在源画面中框选要跟踪的对象。", "Drag a rectangle around the object in the source frame."))
                    .font(.callout).foregroundStyle(.secondary)
                if let image {
                    GeometryReader { proxy in
                        let scale = min(proxy.size.width/CGFloat(image.width),proxy.size.height/CGFloat(image.height))
                        let size = CGSize(width: CGFloat(image.width)*scale,height: CGFloat(image.height)*scale)
                        Image(decorative: image,scale: 1).resizable().frame(width: size.width,height: size.height)
                            .overlay { selection(size: size) }.contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 3).onChanged { value in
                                let x0 = min(1,max(0,value.startLocation.x/size.width)), y0 = min(1,max(0,value.startLocation.y/size.height))
                                let x1 = min(1,max(0,value.location.x/size.width)), y1 = min(1,max(0,value.location.y/size.height))
                                region = .init(x: min(x0,x1),y: min(y0,y1),width: abs(x1-x0),height: abs(y1-y0))
                            }).frame(maxWidth: .infinity,maxHeight: .infinity)
                    }
                } else if let error {
                    ContentUnavailableView { Label(WorkbenchText.t("无法读取画面", "Couldn’t load frame"),systemImage: "film") }
                        description: { Text(error) } actions: { Button(WorkbenchText.t("重试", "Retry")) { Task { await load() } } }
                } else { ProgressView(WorkbenchText.t("正在读取画面…", "Loading frame…")).frame(maxWidth: .infinity,maxHeight: .infinity) }
            }.padding().navigationTitle(WorkbenchText.t("选择跟踪对象", "Select tracking object"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(WorkbenchText.t("取消", "Cancel")) { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(WorkbenchText.t("使用此区域", "Use this region")) { if let region { onApply(region) } }
                            .disabled(region.map { (try? MediaVideoMotionMath.validateRegion($0)) == nil } ?? true)
                    }
                }
        }.task { region = initial;await load() }
    }
    private func selection(size: CGSize) -> some View {
        SwiftUI.Canvas { context,_ in
            if let region {
                let rect = CGRect(x: region.x*size.width,y: region.y*size.height,width: region.width*size.width,height: region.height*size.height)
                context.fill(Path(rect),with: .color(.accentColor.opacity(0.15)))
                context.stroke(Path(rect),with: .color(.white),lineWidth: 3)
                context.stroke(Path(rect),with: .color(.accentColor),lineWidth: 1)
            }
        }.allowsHitTesting(false)
    }
    private func load() async {
        error = nil
        do { image = try await MediaVideoMotionService.shared.sourcePreview(url: url,sourceSeconds: sourceSeconds).image }
        catch is CancellationError { }
        catch { self.error = error.localizedDescription }
    }
}
#endif
