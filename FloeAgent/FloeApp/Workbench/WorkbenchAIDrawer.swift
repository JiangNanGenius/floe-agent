// FloeApp — Workbench AI drawer.
//
// Opens only on request. Shows: current selection, pending proposals (accept
// / reject), available enabled models, the pre-submission review (model,
// uploaded assets, parameters and honest cost note), generated candidates
// (import as layer/clip only after acceptance) and durable generation jobs
// with recovery, stop-waiting vs remote cancel, and no automatic resubmit.

import SwiftUI
import FloeCore
import FloeWorkbench
#if canImport(UIKit)
import UIKit
#endif

struct WorkbenchAIDrawer: View {
    @ObservedObject var center: WorkbenchCenter

    @State private var imagePrompt = ""
    @State private var videoPrompt = ""
    @State private var selectedImageModel: UUID?
    @State private var selectedVideoModel: UUID?
    @State private var imageSize = "1K"
    @State private var imageCount = 1
    @State private var videoDuration = 5
    @State private var videoAspect = "16:9"
    @State private var videoResolution = "720p"
    @State private var tab: Tab = .assistant

    enum Tab: String, CaseIterable {
        case assistant, proposals, jobs
    }

    private var imageModels: [WorkbenchAIModelInfo] { center.imageModelsForUI() }
    private var videoModels: [WorkbenchAIModelInfo] { center.videoModelsForUI() }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text(WorkbenchText.t("助手", "Assistant")).tag(Tab.assistant)
                Text(WorkbenchText.t("提案 \(center.pendingProposals.count)", "Proposals \(center.pendingProposals.count)"))
                    .tag(Tab.proposals)
                Text(WorkbenchText.t("任务", "Jobs")).tag(Tab.jobs)
            }
            .pickerStyle(.segmented)
            .padding(8)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    selectionSummary
                    switch tab {
                    case .assistant: assistantSection
                    case .proposals: proposalsSection
                    case .jobs: jobsSection
                    }
                }
                .padding(12)
            }
        }
        .task {
            await center.reloadAISignals()
        }
    }

    private var selectionSummary: some View {
        SectionCard(title: WorkbenchText.t("当前选择", "Current selection")) {
            if let project = center.project {
                if project.kind == .image,
                   let layer = project.imageLayers.first(where: { $0.id == center.selectedLayerID }) {
                    Text("\(WorkbenchText.t("图层", "Layer")): \(layer.name)")
                } else if project.kind == .video,
                          let clip = project.videoTimeline?.clips.first(where: { $0.id == center.selectedClipID }) {
                    Text(String(format: "%@: %.2f–%.2f s", WorkbenchText.t("片段", "Clip"),
                                clip.trimStart, clip.trimEnd))
                } else {
                    Text(WorkbenchText.t("未选择具体对象", "Nothing specific selected"))
                        .foregroundStyle(.secondary)
                }
                Text(WorkbenchText.t("画布 \(project.canvas?.width ?? 0)×\(project.canvas?.height ?? 0)",
                                     "Canvas \(project.canvas?.width ?? 0)×\(project.canvas?.height ?? 0)"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Assistant

    private var assistantSection: some View {
        Group {
            if !center.aiAvailable {
                SectionCard(title: WorkbenchText.t("AI 不可用", "AI unavailable")) {
                    Text(WorkbenchText.t("未配置可用的图像或视频模型；Floe 不会自动切换服务商。请在设置中配置模型。",
                                         "No enabled image or video model is configured; Floe never switches providers automatically. Configure a model in Settings."))
                        .font(.caption)
                }
                .accessibilityIdentifier("workbench.ai.unavailable")
            } else {
                SectionCard(title: WorkbenchText.t("图片生成", "Image generation")) {
                    if imageModels.isEmpty {
                        Text(WorkbenchText.t("没有已启用且带适配器的图像模型。",
                                             "No enabled image model with an adapter."))
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        TextField(WorkbenchText.t("描述要生成的图片", "Describe the image"), text: $imagePrompt,
                                  axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(2...5)
                            .accessibilityIdentifier("workbench.ai.image.prompt")
                        Picker(WorkbenchText.t("模型", "Model"), selection: $selectedImageModel) {
                            Text(WorkbenchText.t("选择模型", "Choose model")).tag(UUID?.none)
                            ForEach(imageModels) { model in
                                Text("\(model.displayName) · \(model.providerName)").tag(UUID?.some(model.id))
                            }
                        }
                        .accessibilityIdentifier("workbench.ai.image.model")
                        HStack {
                            Picker(WorkbenchText.t("尺寸", "Size"), selection: $imageSize) {
                                Text("1K").tag("1K")
                                Text("2K").tag("2K")
                                Text("4K").tag("4K")
                            }
                            Stepper(WorkbenchText.t("数量 \(imageCount)", "Count \(imageCount)"),
                                    value: $imageCount, in: 1...4)
                        }
                        Button(WorkbenchText.t("检查并生成", "Review & generate")) {
                            guard let modelID = selectedImageModel ?? imageModels.first?.id else { return }
                            center.prepareImageGeneration(prompt: imagePrompt, modelID: modelID,
                                                          size: imageSize, count: imageCount,
                                                          sourceAssetID: sourceAssetIDForEdit())
                        }
                        .disabled(imagePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("workbench.ai.image.submit")
                    }
                }

                SectionCard(title: WorkbenchText.t("视频生成", "Video generation")) {
                    if videoModels.isEmpty {
                        Text(WorkbenchText.t("没有已启用且带原生适配器的视频模型。",
                                             "No enabled video model with a native adapter."))
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        TextField(WorkbenchText.t("描述要生成的视频", "Describe the video"), text: $videoPrompt,
                                  axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(2...5)
                            .accessibilityIdentifier("workbench.ai.video.prompt")
                        Picker(WorkbenchText.t("模型", "Model"), selection: $selectedVideoModel) {
                            Text(WorkbenchText.t("选择模型", "Choose model")).tag(UUID?.none)
                            ForEach(videoModels) { model in
                                Text("\(model.displayName) · \(model.providerName)").tag(UUID?.some(model.id))
                            }
                        }
                        .accessibilityIdentifier("workbench.ai.video.model")
                        HStack {
                            Picker(WorkbenchText.t("时长", "Duration"), selection: $videoDuration) {
                                Text("5s").tag(5)
                                Text("8s").tag(8)
                                Text("10s").tag(10)
                            }
                            Picker(WorkbenchText.t("画幅", "Aspect"), selection: $videoAspect) {
                                Text("16:9").tag("16:9")
                                Text("9:16").tag("9:16")
                                Text("1:1").tag("1:1")
                            }
                        }
                        Picker(WorkbenchText.t("分辨率", "Resolution"), selection: $videoResolution) {
                            Text("720p").tag("720p")
                            Text("1080p").tag("1080p")
                        }
                        Button(WorkbenchText.t("检查并提交", "Review & submit")) {
                            guard let modelID = selectedVideoModel ?? videoModels.first?.id else { return }
                            center.prepareVideoGeneration(
                                prompt: videoPrompt, modelID: modelID,
                                options: WorkbenchVideoAIOptions(durationSeconds: Double(videoDuration),
                                                                 aspectRatio: videoAspect,
                                                                 resolution: videoResolution))
                        }
                        .disabled(videoPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("workbench.ai.video.submit")
                    }
                }

                if !center.imageRequests.isEmpty {
                    imageRequestsSection
                }

                if !center.candidates.isEmpty {
                    SectionCard(title: WorkbenchText.t("候选结果", "Candidates")) {
                        Text(WorkbenchText.t("候选不会自动替换项目；导入后作为新图层或片段。",
                                             "Candidates never replace the project automatically; import them as a new layer or clip."))
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(center.candidates) { candidate in
                            HStack {
                                Image(systemName: candidate.kind == .image ? "photo" : "film")
                                VStack(alignment: .leading) {
                                    Text(candidate.url.lastPathComponent).font(.caption).lineLimit(1)
                                    Text(candidate.modelName).font(.caption2).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(WorkbenchText.t("导入", "Import")) {
                                    center.acceptCandidate(candidate)
                                }
                                .buttonStyle(.borderedProminent)
                                .frame(minHeight: 44)
                                .accessibilityIdentifier("workbench.ai.candidate.accept")
                                Button(role: .destructive) {
                                    center.rejectCandidate(candidate)
                                } label: { Image(systemName: "xmark") }
                                .frame(minWidth: 44, minHeight: 44)
                            }
                        }
                    }
                    .accessibilityIdentifier("workbench.ai.candidates")
                }
            }
        }
    }

    /// Truthful status of image requests with no provider job id. Nothing
    /// here resubmits: interrupted/unknown outcomes stay visible until the
    /// user dismisses them or prepares a new generation.
    private var imageRequestsSection: some View {
        SectionCard(title: WorkbenchText.t("图片请求", "Image requests")) {
            ForEach(center.imageRequests) { record in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: icon(for: record.status))
                        Text(title(for: record.status)).font(.subheadline.weight(.medium))
                        Spacer()
                        Button(role: .destructive) {
                            center.dismissImageRequest(record.id)
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .frame(minWidth: 44, minHeight: 44)
                        .accessibilityIdentifier("workbench.ai.imageRequest.dismiss")
                    }
                    Text(record.modelName).font(.caption).foregroundStyle(.secondary)
                    Text(record.detail).font(.caption2).foregroundStyle(.secondary)
                    if let message = record.message {
                        Text(message).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("workbench.ai.imageRequest.\(record.status.rawValue)")
            }
        }
        .accessibilityIdentifier("workbench.ai.imageRequests")
    }

    private func icon(for status: WorkbenchImageRequestStore.Status) -> String {
        switch status {
        case .submitted: "hourglass"
        case .interrupted: "waveform.path.ecg"
        case .unknown: "questionmark.circle"
        case .failed: "exclamationmark.triangle"
        }
    }

    private func title(for status: WorkbenchImageRequestStore.Status) -> String {
        switch status {
        case .submitted: WorkbenchText.t("提交中", "Submitting")
        case .interrupted: WorkbenchText.t("已中断（不会自动重试）", "Interrupted (no auto-retry)")
        case .unknown: WorkbenchText.t("结果未知（不会自动重试）", "Unknown outcome (no auto-retry)")
        case .failed: WorkbenchText.t("已拒绝", "Rejected")
        }
    }

    private func sourceAssetIDForEdit() -> UUID? {        guard let project = center.project, project.kind == .image,
              let layer = project.imageLayers.first(where: { $0.id == center.selectedLayerID }),
              let assetID = layer.assetID else { return nil }
        return assetID
    }

    // MARK: Proposals

    private var proposalsSection: some View {
        Group {
            if center.pendingProposals.isEmpty {
                Text(WorkbenchText.t("没有待确认的提案。", "No pending proposals."))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(center.pendingProposals) { proposal in
                    SectionCard(title: WorkbenchText.t("提案", "Proposal")) {
                        Text(proposal.summary).font(.subheadline)
                        Text(WorkbenchText.t("基于修订 \(proposal.baseRevision) · \(proposal.commands.count) 条命令",
                                             "Based on revision \(proposal.baseRevision) · \(proposal.commands.count) command(s)"))
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button(WorkbenchText.t("接受", "Accept")) {
                                center.acceptProposal(proposal)
                            }
                            .buttonStyle(.borderedProminent)
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("workbench.ai.proposal.accept")
                            Button(role: .destructive) {
                                center.rejectProposal(proposal)
                            } label: {
                                Text(WorkbenchText.t("拒绝", "Reject"))
                                    .frame(minHeight: 44)
                            }
                        }
                        Text(WorkbenchText.t("手动修改或撤销会让提案过期；过期提案必须重新生成。",
                                             "Manual edits or undo make a proposal stale; stale proposals must be prepared again."))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    .accessibilityIdentifier("workbench.ai.proposal")
                }
            }
        }
    }

    // MARK: Jobs

    private var jobsSection: some View {
        Group {
            HStack {
                Button(WorkbenchText.t("刷新", "Refresh")) {
                    Task { await center.refreshAIJobs() }
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("workbench.ai.jobs.refresh")
                Spacer()
                Text(WorkbenchText.t("关闭视图不会丢弃任务；重新打开后仍可恢复。",
                                     "Closing the view does not drop jobs; they recover when reopened."))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if center.aiJobs.isEmpty {
                Text(WorkbenchText.t("没有生视频任务。", "No video generation jobs."))
                    .foregroundStyle(.secondary)
            }
            ForEach(center.aiJobs) { job in
                SectionCard(title: WorkbenchText.t("任务", "Job")) {
                    Text(job.id.uuidString).font(.caption2).foregroundStyle(.secondary)
                    Text(job.state)
                        .font(.subheadline)
                    if let message = job.message {
                        Text(message).font(.caption).foregroundStyle(.red)
                    }
                    HStack {
                        if job.isActive {
                            if job.isWaitStopped {
                                Button(WorkbenchText.t("继续等待", "Resume waiting")) {
                                    center.resumeWaiting(jobID: job.id)
                                }
                                .frame(minHeight: 44)
                            } else {
                                Button(WorkbenchText.t("停止等待", "Stop waiting")) {
                                    center.stopWaiting(jobID: job.id)
                                }
                                .frame(minHeight: 44)
                                .accessibilityIdentifier("workbench.ai.job.stopWaiting")
                            }
                            Button(role: .destructive) {
                                Task { await center.cancelAIJob(jobID: job.id) }
                            } label: {
                                Text(WorkbenchText.t("取消远端任务", "Cancel remote job"))
                                    .frame(minHeight: 44)
                            }
                            .accessibilityIdentifier("workbench.ai.job.cancel")
                        } else {
                            Button(WorkbenchText.t("导入结果", "Import result")) {
                                Task {
                                    if let url = await center.deliverCandidateURL(jobID: job.id) {
                                        center.addImportedCandidate(url: url)
                                    }
                                }
                            }
                            .frame(minHeight: 44)
                            .accessibilityIdentifier("workbench.ai.job.import")
                        }
                    }
                    if job.isActive && !job.isWaitStopped {
                        Text(WorkbenchText.t("停止等待只停止本地刷新；取消会请求远端真正取消。",
                                             "Stop waiting only stops local refreshes; cancel requests a real remote cancellation."))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("workbench.ai.job")
            }
        }
    }
}

// MARK: - Pre-submission review

struct WorkbenchAIReviewSheet: View {
    @ObservedObject var center: WorkbenchCenter
    var request: WorkbenchCenter.AIReviewRequest
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section(WorkbenchText.t("模型", "Model")) {
                    LabeledContent(WorkbenchText.t("模型", "Model"), value: request.modelName)
                }
                Section(WorkbenchText.t("上传素材", "Uploaded assets")) {
                    if request.assetNames.isEmpty {
                        Text(WorkbenchText.t("无参考素材", "No reference assets"))
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(request.assetNames, id: \.self) { name in
                            Text(name)
                        }
                    }
                }
                Section(WorkbenchText.t("参数", "Parameters")) {
                    LabeledContent(WorkbenchText.t("提示词", "Prompt"), value: request.prompt)
                    ForEach(Array(request.parameters.keys.sorted()), id: \.self) { key in
                        LabeledContent(key, value: request.parameters[key] ?? "")
                    }
                }
                Section(WorkbenchText.t("费用", "Cost")) {
                    Text(request.costNote)
                        .font(.caption)
                }
                Section {
                    Text(WorkbenchText.t("提交后任务会持久化；关闭视图不会丢弃任务。",
                                         "The submitted job is durable; closing the view does not drop it."))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(WorkbenchText.t("确认提交", "Confirm submission"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(WorkbenchText.t("取消", "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(WorkbenchText.t("提交", "Submit")) {
                        let captured = request
                        dismiss()
                        Task {
                            if captured.kind == .image {
                                await center.confirmImageGeneration(captured)
                            } else {
                                await center.confirmVideoGeneration(captured)
                            }
                        }
                    }
                    .accessibilityIdentifier("workbench.ai.review.submit")
                }
            }
        }
    }
}
