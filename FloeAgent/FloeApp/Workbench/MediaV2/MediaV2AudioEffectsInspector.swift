// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeWorkbench

struct MediaV2AudioEffectsInspector: View {
    @Bindable var session: MediaV2Session
    private struct Band: Identifiable { let id = UUID();var value:PreparedVideoEQBand }
    @State private var bands: [Band] = []
    @State private var compressor = false
    @State private var threshold = -20.0
    @State private var headroom = 5.0
    @State private var attack = 5.0
    @State private var release = 50.0
    @State private var makeup = 0.0
    @State private var limiter = false
    @State private var ceiling = -1.0
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            if let selected = session.selectedClip {
                if selected.track.kind == .visual {
                    Button(WorkbenchText.t("分离原声以编辑", "Separate source audio to edit")) {
                        Task { do { let result = try await session.editableSourceAudio(for:selected.clip.id);session.select(result.track,clip:result.clip) }
                            catch { session.diagnostic = error.localizedDescription } }
                    }.frame(minHeight:44)
                } else if selected.track.kind == .audio {
                    Toggle(WorkbenchText.t("片段静音", "Mute clip"),isOn:Binding(get:{selected.clip.isMuted},set:{ value in
                        var clip = selected.clip;clip.isMuted = value
                        session.submit([.replaceClip(trackID:selected.track.id,clipID:clip.id,expectedRevision:selected.clip.revision,clip:clip)])
                    })).frame(minHeight:44)
                    if session.tool == "video.eq" { equalizer }
                    else { dynamics }
                    Button(WorkbenchText.t("应用到当前音频片段", "Apply to this audio clip"),action:apply).frame(minHeight:44)
                } else { Text(WorkbenchText.t("请选择音频或视频片段。", "Select an audio or video clip.")).font(.caption).foregroundStyle(.secondary) }
            } else { Text(WorkbenchText.t("请选择音频或视频片段。", "Select an audio or video clip.")).font(.caption).foregroundStyle(.secondary) }
        }.disabled(session.saving || session.processingTool || session.selectedClip?.track.isLocked == true)
            .onAppear(perform:load).onChange(of:session.selectedClipID) { _,_ in load() }
            .onChange(of:session.selectedClip?.clip.revision) { _,_ in load() }
    }
    private var equalizer: some View {
        VStack(alignment:.leading,spacing:10) {
            ForEach(bands) { item in
                let id = item.id
                VStack(alignment:.leading,spacing:6) {
                    HStack {
                        Toggle(WorkbenchText.t("频段", "Band")+" \((bands.firstIndex(where:{$0.id == id}) ?? 0)+1)",isOn:Binding(get:{band(id).isEnabled},set:{replaceBand(id,enabled:$0)}))
                        Button(role:.destructive) { bands.removeAll { $0.id == id } } label: { Image(systemName:"trash").frame(width:44,height:44) }
                    }
                    Picker(WorkbenchText.t("类型", "Type"),selection:Binding(get:{band(id).filter},set:{replaceBand(id,filter:$0)})) {
                        Text(WorkbenchText.t("低频搁架", "Low shelf")).tag(PreparedVideoEQFilter.lowShelf)
                        Text(WorkbenchText.t("峰值", "Peak")).tag(PreparedVideoEQFilter.parametric)
                        Text(WorkbenchText.t("高频搁架", "High shelf")).tag(PreparedVideoEQFilter.highShelf)
                    }
                    MusicValueSlider(title:WorkbenchText.t("频率", "Frequency"),value:log10(band(id).frequency),range:log10(20)...log10(20_000)) { replaceBand(id,frequency:pow(10,$0)) }
                    Text(String(format:"%.0f Hz",band(id).frequency)).font(.caption).monospacedDigit()
                    MusicValueSlider(title:WorkbenchText.t("增益", "Gain"),value:band(id).gain,range:-24...24,suffix:"dB") { replaceBand(id,gain:$0) }
                    MusicValueSlider(title:WorkbenchText.t("带宽", "Bandwidth"),value:band(id).bandwidth,range:0.05...5,suffix:WorkbenchText.t("八度", "oct")) { replaceBand(id,bandwidth:$0) }
                }.padding(10).background(Color.secondary.opacity(0.06),in:RoundedRectangle(cornerRadius:8))
            }
            Button(WorkbenchText.t("添加频段", "Add band")) { bands.append(.init(value:.init(frequency:1000,gain:0))) }.frame(minHeight:44).disabled(bands.count>=8)
            Button(WorkbenchText.t("清除均衡", "Clear EQ")) { bands = [] }.frame(minHeight:44)
        }
    }
    private var dynamics: some View {
        VStack(alignment:.leading,spacing:10) {
            Toggle(WorkbenchText.t("压缩", "Compressor"),isOn:$compressor).frame(minHeight:44)
            if compressor {
                MusicValueSlider(title:WorkbenchText.t("阈值", "Threshold"),value:threshold,range:-40...0,suffix:"dB") { threshold = $0 }
                MusicValueSlider(title:WorkbenchText.t("余量", "Headroom"),value:headroom,range:0.1...40,suffix:"dB") { headroom = $0 }
                MusicValueSlider(title:WorkbenchText.t("启动", "Attack"),value:attack,range:0.1...200,suffix:"ms") { attack = $0 }
                MusicValueSlider(title:WorkbenchText.t("释放", "Release"),value:release,range:10...3000,suffix:"ms") { release = $0 }
                MusicValueSlider(title:WorkbenchText.t("补偿增益", "Makeup gain"),value:makeup,range:-24...24,suffix:"dB") { makeup = $0 }
            }
            Toggle(WorkbenchText.t("峰值限幅", "Peak limiter"),isOn:$limiter).frame(minHeight:44)
            if limiter {
                MusicValueSlider(title:WorkbenchText.t("峰值上限", "Ceiling"),value:ceiling,range:-24...0,suffix:"dB") { ceiling = $0 }
                Text(WorkbenchText.t("限制当前片段的峰值。", "Limits this clip's peaks.")).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
    private func load() {
        let p = session.selectedClip?.clip.audioProcessing ?? .init()
        bands = p.eqBands.map { .init(value:$0) };compressor = p.dynamics != nil;limiter = p.limiter != nil
        let d = p.dynamics ?? .init()
        threshold = d.threshold;headroom = d.headRoom;attack = d.attackTime*1000;release = d.releaseTime*1000;makeup = d.masterGain
        ceiling = p.limiter?.ceilingDB ?? -1
    }
    private func band(_ id:UUID) -> PreparedVideoEQBand { bands.first { $0.id == id }?.value ?? .init(frequency:1000,gain:0) }
    private func replaceBand(_ id:UUID,frequency:Double? = nil,gain:Double? = nil,bandwidth:Double? = nil,filter:PreparedVideoEQFilter? = nil,enabled:Bool? = nil) {
        guard let index = bands.firstIndex(where:{$0.id == id}) else { return };let b = bands[index].value
        bands[index].value = .init(frequency:frequency ?? b.frequency,gain:gain ?? b.gain,bandwidth:bandwidth ?? b.bandwidth,filter:filter ?? b.filter,isEnabled:enabled ?? b.isEnabled)
    }
    private func apply() {
        guard let selected = session.selectedClip,selected.track.kind == .audio else { return }
        let old = selected.clip.audioProcessing
        var p = MediaAudioProcessing(eqBands:bands.map(\.value),
            dynamics:compressor ? .init(threshold:threshold,headRoom:headroom,expansionRatio:old?.dynamics?.expansionRatio ?? 2,attackTime:attack/1000,releaseTime:release/1000,masterGain:makeup) : nil,
            limiter:limiter ? .init(ceilingDB:ceiling,attackTime:old?.limiter?.attackTime ?? 0.001,decayTime:old?.limiter?.decayTime ?? 0.05) : nil)
        if session.tool == "video.eq" { p.dynamics = old?.dynamics;p.limiter = old?.limiter }
        var input = MediaV2ToolInput();input.objectID = selected.clip.id;input.expectedRevision = session.document.revision;input.audioProcessing = p
        let id = session.tool
        Task { do { _ = try await session.performTool(id,input:input) } catch { session.diagnostic = error.localizedDescription } }
    }
}
#endif
