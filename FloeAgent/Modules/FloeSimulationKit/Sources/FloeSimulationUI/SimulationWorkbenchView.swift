import SwiftUI
import FloeSimulationCore
import FloeSimulationRuntime

/// The CAD host injects its existing Metal viewport. The workbench only owns its
/// feature panels, preserving the App's outer split view and editor state.
public struct SimulationWorkbenchView<Viewport: View>: View {
    @Bindable private var model: SimulationWorkbenchModel
    private let viewport: (SimulationWorkbenchModel) -> Viewport
    @State private var capabilities: [SimulationBackendDescriptor] = []
    @State private var animationMode = false
    @State private var playing = false
    public init(model: SimulationWorkbenchModel, @ViewBuilder viewport: @escaping (SimulationWorkbenchModel) -> Viewport) { self.model = model; self.viewport = viewport }
    public var body: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 1000 {
                HStack(spacing:0) {
                    studyList.frame(width:220)
                    Divider()
                    VStack(spacing:0) { viewport(model); timeline; taskList }.frame(maxWidth:.infinity)
                    Divider()
                    inspector.frame(width:330)
                }
            } else {
                VStack(spacing:0) {
                    HStack { studyMenu; Spacer(); actions }.padding(.horizontal)
                    viewport(model).frame(height:max(180,geometry.size.height * 0.35))
                    timeline
                    inspector
                    taskList
                }
            }
        }
        .navigationTitle(simulationText("Simulation","仿真与分析"))
        .task { capabilities = await model.coordinator.capabilities(); await model.observe() }
        .task(id:playing) {
            while playing, !Task.isCancelled {
                do { try await Task.sleep(for:.milliseconds(33)) } catch { break }
                if let frames = model.result?.frames, frames.count > 1 { model.frameIndex = (model.frameIndex+1)%frames.count }
            }
        }
        .accessibilityIdentifier("simulation.workbench")
        .disabled(model.isClosed)
    }
    private var studyList: some View {
        VStack {
            HStack { studyMenu; Spacer() }.padding()
            List(selection:$model.selectedStudyID) { ForEach(model.document.studies) { study in Text(study.name).tag(study.id).accessibilityIdentifier("simulation.study."+study.kind.rawValue) } }
            if !model.savedResults.isEmpty {
                Menu(simulationText("Saved results","已保存结果")) { ForEach(model.savedResults) { summary in Button(summary.name) { Task { await model.showSavedResult(summary) } } } }.padding(.horizontal)
            }
            actions.padding()
        }
    }
    private var studyMenu: some View {
        Menu {
            ForEach(SimulationStudyKind.allCases) { kind in Button(kind.simulationDisplayName) { model.createStudy(kind) } }
        } label: { Label(simulationText("New study","新建研究"),systemImage:"plus") }
        .accessibilityIdentifier("simulation.newStudy")
    }
    private var actions: some View {
        HStack {
            Button { Task { await model.save() } } label: { Image(systemName:"square.and.arrow.down") }.accessibilityLabel(simulationText("Save","保存")).disabled(model.saving)
            Button { Task { await model.run() } } label: { Image(systemName:"play.fill") }.accessibilityLabel(simulationText("Run","运行")).disabled(model.selectedStudy == nil || !canRun).accessibilityIdentifier("simulation.run")
        }.buttonStyle(.bordered)
    }
    private var canRun: Bool { guard let kind = model.selectedStudy?.kind else { return false }; return capabilities.contains { $0.isAvailable && $0.supportedStudies.contains(kind) } }
    private var inspector: some View {
        VStack(spacing:0) {
            Picker(simulationText("Workspace","工作模式"),selection:$animationMode) {
                Text(simulationText("Studies","仿真分析")).tag(false)
                Text(simulationText("Animation","动画")).tag(true)
            }.pickerStyle(.segmented).padding(.horizontal)
            if model.hasExternalChanges {
                Button(simulationText("Workspace changed · Reload","工作区已更新 · 重新载入")) { Task { await model.reopen() } }.font(.caption).padding(.horizontal)
            }
            if animationMode { SimulationAnimationSettingsView(model:model) }
            else if let study = model.selectedStudy {
                Picker(simulationText("Study","研究"),selection:$model.selectedStudyID) { ForEach(model.document.studies) { Text($0.name).tag(Optional($0.id)) } }.padding(.horizontal)
                SimulationMeshSettingsView(model:model)
                SimulationStudySettingsView(model:model,kind:study.kind)
                if model.result != nil { SimulationResultInspector(model:model).frame(maxHeight:240) }
                if !canRun { Label(simulationText("Solver connection pending","求解组件待接通"),systemImage:"clock").font(.footnote).foregroundStyle(.secondary).padding(.horizontal) }
            } else { ContentUnavailableView(simulationText("Create a study","创建研究"),systemImage:"cube.transparent",description:Text(simulationText("Choose physics or an analysis type to begin.","选择物理或分析类型开始。"))) }
            if let error = model.errorDetails {
                DisclosureGroup(simulationText("Unable to complete · Details","未能完成 · 详情")) { Text(error).font(.caption).textSelection(.enabled) }.foregroundStyle(.red).padding()
            }
        }
    }
    private var timeline: some View {
        Group {
            if let result = model.result, result.frames.count > 1 {
                HStack {
                    Button { playing.toggle() } label: { Image(systemName:playing ? "pause.fill" : "play.fill") }.accessibilityLabel(playing ? simulationText("Pause","暂停") : simulationText("Play","播放"))
                    Slider(value:Binding(get:{ Double(model.frameIndex) },set:{ model.frameIndex = Int($0.rounded()); model.probeIndex = 0 }),in:0...Double(result.frames.count-1),step:1)
                    Text(model.currentFrame?.timeSeconds.map { String(format:"%.3f s",$0) } ?? model.currentFrame?.frequencyHz.map { String(format:"%.4g Hz",$0) } ?? "").monospacedDigit().font(.caption)
                }.padding(.horizontal).frame(minHeight:44).accessibilityIdentifier("simulation.timeline")
            }
        }
    }
    private var taskList: some View {
        VStack(spacing:4) {
            ForEach(model.meshJobs.filter { !$0.status.isTerminal }) { job in
                HStack {
                    if let fraction = job.progress.fraction { ProgressView(value:fraction).frame(maxWidth:160) } else { ProgressView() }
                    Text(job.status == .cancelling ? simulationText("Stopping mesh","正在停止网格") : simulationText("Generating mesh","正在生成网格")).font(.caption)
                    Spacer()
                    Button(simulationText("Stop","停止")) { Task { await model.cancelMesh(job.id) } }.disabled(job.status == .cancelling || job.progress.stage == "saving")
                }
            }
            ForEach(model.jobs.filter { !$0.status.isTerminal }) { job in
                HStack {
                    if let fraction = job.progress.fraction { ProgressView(value:fraction).frame(maxWidth:160) } else { ProgressView() }
                    Text(job.status == .queued ? simulationText("Queued","排队中") : job.status == .cancelling ? simulationText("Stopping","正在停止") : simulationText("Running","计算中")).font(.caption)
                    Spacer()
                    Button(simulationText("Stop","停止")) { Task { await model.cancel(job.id) } }.disabled(job.status == .cancelling).accessibilityIdentifier("simulation.cancel")
                }
            }
        }.padding(.horizontal)
    }
}

private struct SimulationResultInspector: View {
    @Bindable var model: SimulationWorkbenchModel
    var body: some View {
        Form {
            if let result = model.result {
                if result.source != model.document.source || result.studyRevision != model.selectedStudy?.revision { Label(simulationText("Inputs changed","输入已更改"),systemImage:"exclamationmark.arrow.triangle.2.circlepath").foregroundStyle(.orange) }
                Picker(simulationText("Field","结果场"),selection:$model.selectedFieldID) { ForEach(model.currentFrame?.fields ?? []) { Text($0.simulationDisplayName+" ("+$0.unit+")").tag(Optional($0.id)) } }
                if let field = model.currentField, !field.values.isEmpty {
                    Stepper(simulationText("Probe","探针")+" \(model.probeIndex+1)",value:$model.probeIndex,in:0...max(0,field.values.count/field.components-1))
                    let start = min(model.probeIndex,field.values.count/field.components-1)*field.components
                    ForEach(0..<field.components,id:\.self) { component in
                        LabeledContent("\(component+1)") { Text(field.values[start+component].formatted(.number.precision(.significantDigits(3...6)))).monospacedDigit() }
                    }
                    if let imaginary = field.imaginaryValues { Text(simulationText("Imaginary","虚部")+": "+imaginary[start..<(start+field.components)].map { String(format:"%.5g",$0) }.joined(separator:", ")).font(.caption) }
                }
                LabeledContent(simulationText("Deformation","变形倍率")) { TextField("1",value:$model.deformationScale,format:.number).frame(maxWidth:80) }
                Button(simulationText("Export CSV","导出 CSV")) { Task { await model.export() } }.accessibilityIdentifier("simulation.export")
                if let url = model.exportURL { ShareLink(item:url) { Label(simulationText("Share result","共享结果"),systemImage:"square.and.arrow.up") } }
            }
        }
    }
}
