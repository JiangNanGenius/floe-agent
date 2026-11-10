// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeWorkbench

struct MediaV2ScopesInspector: View {
    @Bindable var session: MediaV2Session
    @State private var mode = 0
    @State private var bin: (x:Int,y:Int)?
    @State private var loading = false
    @State private var loadGeneration = UUID()
    private struct Request: Hashable { let revision:Int64;let seconds:Double }
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            Picker(WorkbenchText.t("示波器", "Scopes"),selection:$mode) {
                Text(WorkbenchText.t("亮度波形", "Luma waveform")).tag(0)
                Text(WorkbenchText.t("色度分布", "Vectorscope")).tag(1)
            }.pickerStyle(.segmented).onChange(of:mode) { _,_ in bin = nil }
            if let snapshot = session.videoScopes,snapshot.revision == session.document.revision {
                plot(snapshot).frame(height:200).background(.black,in:RoundedRectangle(cornerRadius:8))
                Text(String(format:WorkbenchText.t("画面时间 %.3f 秒", "Frame at %.3f s"),snapshot.timelineSeconds)).font(.caption).monospacedDigit()
                if let bin {
                    if mode == 0 {
                        let at = bin.y*snapshot.waveformWidth+bin.x
                        Text(String(format:WorkbenchText.t("亮度 %.1f%% · 样本 %u", "Luma %.1f%% · samples %u"),Double(bin.y)*100/Double(snapshot.waveformHeight-1),snapshot.waveform[at])).font(.caption).monospacedDigit()
                    } else {
                        let size = snapshot.vectorscopeSize,x = min(size-1,bin.x),y = min(size-1,bin.y),at = y*size+x
                        Text(String(format:"Cb %.3f · Cr %.3f · %u",Double(x)/Double(size-1)-0.5,Double(y)/Double(size-1)-0.5,snapshot.vectorscope[at])).font(.caption).monospacedDigit()
                    }
                }
                Text(WorkbenchText.t("点击图中位置读值。", "Tap the plot to read a value.")).font(.caption2).foregroundStyle(.secondary)
            } else if loading { ProgressView().frame(maxWidth:.infinity,minHeight:80) }
            Button(WorkbenchText.t("刷新当前画面", "Refresh current frame")) { Task { await refresh() } }.frame(minHeight:44).disabled(loading)
        }.task(id:Request(revision:session.document.revision,seconds:session.playhead)) {
            do { try await Task.sleep(for:.milliseconds(120));await refresh() } catch {}
        }
    }
    private func plot(_ snapshot:MediaVideoScopeSnapshot) -> some View {
        GeometryReader { geometry in
            let width = mode == 0 ? snapshot.waveformWidth : snapshot.vectorscopeSize
            let height = mode == 0 ? snapshot.waveformHeight : snapshot.vectorscopeSize
            let values = mode == 0 ? snapshot.waveform : snapshot.vectorscope
            SwiftUI.Canvas { context,size in
                var grid = Path()
                for i in 0...4 {
                    let t = Double(i)/4
                    grid.move(to:.init(x:t*size.width,y:0));grid.addLine(to:.init(x:t*size.width,y:size.height))
                    grid.move(to:.init(x:0,y:t*size.height));grid.addLine(to:.init(x:size.width,y:t*size.height))
                }
                context.stroke(grid,with:.color(.white.opacity(0.2)),lineWidth:1)
                let peak = Double(values.max() ?? 1),denominator = log1p(max(1,peak))
                for index in values.indices where values[index]>0 {
                    let x = index%width,y = index/width
                    let rectangle = CGRect(x:Double(x)*size.width/Double(width),y:Double(height-1-y)*size.height/Double(height),
                        width:max(1,size.width/Double(width)),height:max(1,size.height/Double(height)))
                    context.fill(Path(rectangle),with:.color((mode == 0 ? Color.green : .cyan).opacity(0.2+0.8*log1p(Double(values[index]))/denominator)))
                }
            }.contentShape(Rectangle()).onTapGesture { point in
                let x = max(0,min(width-1,Int(point.x/max(1,geometry.size.width)*Double(width))))
                let y = max(0,min(height-1,height-1-Int(point.y/max(1,geometry.size.height)*Double(height))))
                bin = (x,y)
            }
        }
    }
    private func refresh() async {
        let generation = UUID();loadGeneration = generation
        loading = true;defer { if loadGeneration == generation { loading = false } }
        let duration = session.document.trackGraph.totalDurationSeconds
        guard duration>0 else { return }
        let frame = 1/max(1,session.document.trackGraph.frameRate?.seconds ?? 30)
        do { _ = try await session.readVideoScopes(at:min(session.playhead,max(0,duration-frame))) }
        catch is CancellationError {}
        catch { session.diagnostic = error.localizedDescription }
    }
}
#endif
