import SwiftUI
import FloeModels
import FloeSecurity

struct ThreadFixtureView: View {
    @State private var events = Self.initialEvents
    @State private var latest = true
    @State private var previewIsShort = false
    private static let runID = UUID()
    private static func event(_ sequence: Int, kind: RunEventRecord.Kind, call: String, name: String, status: String = "ok") -> RunEventRecord {
        let payload = ["callID": call, "tool": name, "status": status, "summary": "示例文件已读取"]
        return RunEventRecord(runID: runID, sequence: sequence, kind: kind,
            payloadJSON: String(decoding: try! JSONEncoder().encode(payload), as: UTF8.self))
    }
    static let initialEvents = [
        event(1, kind: .toolRequest, call: "a", name: "workspace.readFile"),
        event(2, kind: .toolResult, call: "a", name: "workspace.readFile"),
        event(3, kind: .toolRequest, call: "b", name: "video.inspect"),
        event(4, kind: .toolResult, call: "b", name: "video.inspect")
    ]
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ReasoningBlockView(text: previewIsShort ? "继续检查。" : String(repeating: "先检查素材的时长与尺寸，再确认字幕区间和导出设置。", count: 4), isStreaming: true)
                StepGroupView(events: events, isLatest: latest, isLive: latest, hasError: false, pendingApprovals: [])
                ToolCallCardView(name: "audio.edit", status: "failed", inputSummary: "音轨：旁白.wav", resultSummary: "混音采样率不一致，请先转换为相同采样率。")
            }.padding()
        }.navigationTitle("任务执行")
        .toolbar {
            Button("切换思考片段") { previewIsShort.toggle() }.accessibilityIdentifier("fixture.reasoningFragment")
            Button("下一轮") { latest = false }.accessibilityIdentifier("fixture.nextRound")
            Button("追加工具", systemImage: "plus") {
                withAnimation(.easeOut(duration: 0.22)) {
                    events.append(Self.event(5, kind: .toolRequest, call: "c", name: "video.transcode", status: "running"))
                }
            }.accessibilityIdentifier("fixture.append")
        }
    }
}

// Narrow stand-ins for App-owned routing and approval/artifact dependencies.
// These fixture tests cover production cards/grouping, not attachment rendering
// or the App's approval execution chain (covered by the full-App CI suite).
struct PendingApproval: Identifiable {
    let toolCall: ToolCall
    var id: String { toolCall.id }
}
struct ApprovalCardView: View {
    let approval: PendingApproval
    let onDecision: (ApprovalDecision) -> Void
    var body: some View { Text("需要确认：\(approval.id)") }
}
struct RichArtifactGallery: View {
    let artifacts: [ToolArtifactReference]
    var body: some View { Text("Fixture does not render rich artifacts") }
}
struct ThreadEventView: View {
    let event: RunEventRecord
    let isLive: Bool
    let hasError: Bool
    let onRetry: (() -> Void)?
    let approvalSummary: String?
    let toolRequestStatus: String?
    let toolRequestResultPayloadJSON: String?
    var body: some View {
        let payload = (try? JSONDecoder().decode([String: String].self, from: Data(event.payloadJSON.utf8))) ?? [:]
        ToolCallCardView(name: payload["tool"] ?? "tool", status: toolRequestStatus ?? "ok",
            inputSummary: "工作区示例文件", resultSummary: toolRequestResultPayloadJSON == nil ? nil : "素材检查完成",
            approvalSummary: approvalSummary)
    }
}
