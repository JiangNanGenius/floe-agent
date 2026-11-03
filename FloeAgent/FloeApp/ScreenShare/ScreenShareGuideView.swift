// Native guide over the real ReplayKit preview. Analysis is button-only.
#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import FloeCore

struct ScreenShareGuideView: View {
    @ObservedObject var center: ScreenShareCenter
    var body: some View {
        ScrollView {
            VStack(alignment:.leading,spacing:16) {
                GroupBox {
                    if let frame=center.latestFrame {screenImage(frame,hints:[])}
                    else {ContentUnavailableView(statusTitle,systemImage:"rectangle.inset.filled.and.person.filled")}
                } label: {Label("screenshare.guide.currentFrame",systemImage:"rectangle.on.rectangle")}
                Text(statusTitle).font(.subheadline).foregroundStyle(.secondary)
                    .accessibilityIdentifier("screenshare.guide.status")
                if let error=center.sharingError {Text(error).font(.footnote).foregroundStyle(.orange)}
                HStack {
                    Button {center.requestBroadcast()} label: {Label("screenshare.guide.start",systemImage:"record.circle")}
                        .disabled(center.isSharing || center.isWaitingForBroadcast || center.lifecycleState == .stopping)
                        .accessibilityIdentifier("screenshare.guide.start")
                    Spacer()
                    Button(role:.destructive) {
                        if center.lifecycleState == .stopFailed {center.retryStopSharing()} else {center.stopSharing()}
                    } label: {Label("screenshare.guide.stop",systemImage:"stop.circle")}
                    .disabled(!center.canStop || center.lifecycleState == .stopping)
                    .accessibilityIdentifier("screenshare.guide.stop")
                }
                GroupBox {
                    VStack(alignment:.leading,spacing:10) {
                        TextField("screenshare.guide.goal",text:$center.userGoal,axis:.vertical)
                            .lineLimit(2...5).accessibilityIdentifier("screenshare.guide.goal")
                        LabeledContent("screenshare.guide.service",value:center.analysisDestinationName)
                            .font(.footnote).accessibilityIdentifier("screenshare.guide.service")
                        Text("screenshare.guide.transmission").font(.footnote).foregroundStyle(.secondary)
                        HStack {
                            Button {
                                center.analyzeScreenAndGuide(userGoal:center.userGoal)
                            } label: {Label("screenshare.guide.analyze",systemImage:"sparkles")}
                            .disabled(!center.canAnalyze || center.userGoal.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || center.userGoal.count>2000)
                            .accessibilityIdentifier("screenshare.guide.analyze")
                            if center.analysisState == .analyzing {
                                ProgressView()
                                Button("screenshare.guide.cancelAnalysis") {center.cancelAnalysis()}
                                    .accessibilityIdentifier("screenshare.guide.cancelAnalysis")
                            }
                        }
                        if let error=center.analysisError {Text(error).font(.footnote).foregroundStyle(.orange)}
                        if center.analysisState == .cancelled {Text("screenshare.guide.analysisCancelled").font(.footnote)}
                    }
                } label: {Text("screenshare.guide.goalTitle")}
                if center.analysisState == .ready,let frame=center.analyzedFrame {
                    GroupBox {
                        VStack(alignment:.leading,spacing:10) {
                            // Markers and hints always use the exact image sent,
                            // never whichever newer live frame arrived later.
                            screenImage(frame,hints:center.guideHints)
                            if center.guideHints.isEmpty {Text(center.guidanceText).textSelection(.enabled)}
                            else {
                                ForEach(Array(center.guideHints.enumerated()),id:\.element.id) { i,hint in
                                    VStack(alignment:.leading) {
                                        Text("\(i+1). \(hint.elementText)").font(.subheadline.weight(.semibold))
                                        Text(hint.instruction).font(.subheadline)
                                    }
                                }
                            }
                        }
                    } label: {Text("screenshare.guide.resultFrame")}
                    .accessibilityIdentifier("screenshare.guide.result")
                }
            }.padding()
        }
        .navigationTitle("screenshare.guide.title").navigationBarTitleDisplayMode(.inline)
        .task {center.startSharing()} // Local preview only; no picker/upload.
        .onDisappear {center.endPreviewIfIdle()}
    }
    private var statusTitle: String {
        switch center.lifecycleState {
        case .idle:return FloeL10n.l("screenshare.guide.idle")
        case .requesting,.waitingForFirstFrame:return FloeL10n.l("screenshare.guide.waiting")
        case .active:return FloeL10n.l("screenshare.guide.active")
        case .paused:return FloeL10n.l("screenshare.guide.paused")
        case .stopping:return FloeL10n.l("screenshare.guide.stopping")
        case .stopFailed:return FloeL10n.l("screenshare.guide.stopUnconfirmed")
        case .stopped:return FloeL10n.l("screenshare.guide.stopped")
        case .failed:return FloeL10n.l("screenshare.guide.unavailable")
        }
    }
    private func screenImage(_ image: UIImage,hints:[ScreenShareCenter.GuideHint])->some View {
        GeometryReader { proxy in
            let scale=min(proxy.size.width/max(1,image.size.width),proxy.size.height/max(1,image.size.height))
            let size=CGSize(width:image.size.width*scale,height:image.size.height*scale)
            let origin=CGPoint(x:(proxy.size.width-size.width)/2,y:(proxy.size.height-size.height)/2)
            Image(uiImage:image).resizable().scaledToFit().frame(width:proxy.size.width,height:proxy.size.height)
            ForEach(Array(hints.enumerated()),id:\.element.id) { i,hint in
                Text("\(i+1)").font(.headline.bold()).padding(7).background(.yellow,in:Circle()).foregroundStyle(.black)
                    .position(x:origin.x+hint.tapPoint.x*size.width,y:origin.y+hint.tapPoint.y*size.height)
                    .accessibilityLabel(hint.elementText)
            }
        }.frame(height:300).background(.black,in:RoundedRectangle(cornerRadius:8))
    }
}
#endif
