// FloeApp — Tool call card.
//
// SPDX-License-Identifier: MPL-2.0
//
// One card per tool invocation: name, semantic status chip, optional
// duration, foldable input/result summaries (monospaced evidence
// typography). Status colors come exclusively from FloeTheme semantic
// tokens — pending amber, success green, failure red.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import CryptoKit
import FloeCore
import FloeModels

/// Presentation model for one tool call card. `status` accepts the
/// producer's raw vocabulary (`ok` / `failed` / `pending`) plus the
/// run-state name when available; colors resolve through RunStateLocalizer.
struct ToolCallCardView: View {
    /// Tool name (e.g. "workspace.readFile").
    let name: String
    /// Raw status: "pending", "ok", "failed" (payload vocabulary).
    var status: String = "pending"
    /// One-line summary of the arguments (input).
    var inputSummary: String? = nil
    /// One-line summary of the result (output).
    var resultSummary: String? = nil
    /// Approval decision/reason for this exact invocation, shown inside the
    /// expanded tool details rather than as a detached timeline footer.
    var approvalSummary: String? = nil
    /// Wall-clock duration when known.
    var duration: TimeInterval? = nil
    /// Digest-addressed files returned by the tool. Image artifacts render
    /// directly in the conversation and expose the system save/share sheet.
    var artifacts: [ToolArtifactReference] = []

    @State private var isExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            if !imageArtifacts.isEmpty {
                ArtifactImageGallery(artifacts: imageArtifacts)
            }
            if !richArtifacts.isEmpty {
                RichArtifactGallery(artifacts: richArtifacts)
            }
            if isExpanded {
                Divider()
                detail.transition(FloeTheme.stepTransition(reduceMotion: reduceMotion))
            }
        }
        .padding(12)
        .background(FloeTheme.stepSurface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(FloeTheme.separator.opacity(0.45), lineWidth: 0.5))
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: status)
        .onChange(of: status, initial: true) { _, value in
            if ["failed", "error", "denied", "expired", "needsUser"].contains(value) { isExpanded = true }
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Header: icon + name + status chip + duration + fold

    private var header: some View {
        Button {
            guard hasDetail else { return }
            withAnimation(FloeTheme.motionAnimation(reduceMotion: reduceMotion)) { isExpanded.toggle() }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: statusIcon)
                    .font(.body.weight(.medium)).foregroundStyle(statusColor)
                    .frame(width: 26, height: 26)
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        .lineLimit(2).multilineTextAlignment(.leading)
                    HStack(spacing: 8) {
                        Text(statusTitle).foregroundStyle(statusColor)
                        if let duration { Text(durationText(duration)).monospacedDigit().foregroundStyle(.secondary) }
                    }.font(.caption)
                }
                Spacer(minLength: 4)
                if hasDetail {
                    Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        .foregroundStyle(.secondary).frame(width: 24, height: 26)
                }
            }
            .frame(maxWidth: .infinity, minHeight: FloeTheme.minimumTarget, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isExpanded ? "已展开" : "已折叠")
        .accessibilityHint(hasDetail ? "查看调用参数、结果和审批记录" : "")
    }

    // MARK: - Folded-out detail

    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let inputSummary, !inputSummary.isEmpty {
                labeledEvidence(title: "tool.input", text: inputSummary)
            }
            if let resultSummary, !resultSummary.isEmpty {
                labeledEvidence(title: "tool.result", text: resultSummary)
            }
            if let approvalSummary, !approvalSummary.isEmpty {
                labeledEvidence(title: "tool.approval", text: approvalSummary)
            }
        }
    }

    private func labeledEvidence(title: LocalizedStringKey, text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(FloeTheme.Typography.metadata)
                .foregroundStyle(.secondary)
            Text(text)
                .font(FloeTheme.Typography.evidence)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Status mapping

    private var hasDetail: Bool {
        (inputSummary?.isEmpty == false)
            || (resultSummary?.isEmpty == false)
            || (approvalSummary?.isEmpty == false)
    }

    private var imageArtifacts: [ToolArtifactReference] {
        artifacts.filter { $0.mimeType == "image/png" || $0.mimeType == "image/jpeg" }
    }

    private var richArtifacts: [ToolArtifactReference] {
        artifacts.filter { $0.mimeType != "image/png" && $0.mimeType != "image/jpeg" }
    }

    private var statusIcon: String {
        switch status {
        case "ok", "completed": "checkmark.circle"
        case "failed", "error": "xmark.octagon"
        case "denied": "hand.raised"
        case "expired": "clock.badge.exclamationmark"
        case "cancelled": "stop.circle"
        case "pending", "needsUser": "hourglass"
        default: "wrench.and.screwdriver"
        }
    }

    private var statusColor: Color {
        switch status {
        case "ok", "completed": FloeTheme.success
        case "failed", "error", "denied", "expired": FloeTheme.destructive
        case "running", "executingTool": FloeTheme.primary
        case "pending", "needsUser": FloeTheme.pending
        default: FloeTheme.unknown
        }
    }

    private var statusTitle: LocalizedStringKey {
        switch status {
        case "ok", "completed": "tool.status.succeeded"
        case "failed", "error": "tool.status.failed"
        case "running", "executingTool": "tool.status.running"
        case "pending": "tool.status.pending"
        case "needsUser": "tool.status.needsUser"
        case "denied": "tool.status.denied"
        case "expired": "tool.status.expired"
        case "cancelled": "tool.status.cancelled"
        default: "tool.status.unknown"
        }
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        if seconds < 1 {
            return String(
                format: String(localized: "tool.duration.ms"),
                Int((seconds * 1000).rounded())
            )
        }
        return String(format: String(localized: "tool.duration.s"), seconds)
    }
}

private struct ArtifactImageGallery: View {
    let artifacts: [ToolArtifactReference]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(artifacts) { artifact in
                ArtifactImageView(artifact: artifact)
            }
        }
    }
}

private struct ArtifactImageView: View {
    let artifact: ToolArtifactReference
    @State private var image: UIImage?
    @State private var fileURL: URL?
    @State private var failed = false
    @State private var showingFullScreen = false

    var body: some View {
        Group {
            if let image, let fileURL {
                VStack(alignment: .leading, spacing: 8) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { showingFullScreen = true }
                        .accessibilityLabel("生成的图片")
                        .accessibilityHint("双击全屏查看")
                    ShareLink(item: fileURL) {
                        Label("保存或共享图片", systemImage: "square.and.arrow.up")
                    }
                    .font(FloeTheme.Typography.metadata)
                }
            } else if failed {
                Label("生成图片已返回，但本地文件校验失败", systemImage: "exclamationmark.triangle")
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(FloeTheme.destructive)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .task(id: artifact.id) { loadVerifiedImage() }
        .fullScreenCover(isPresented: $showingFullScreen) {
            if let image, let fileURL {
                FullScreenArtifactImage(image: image, fileURL: fileURL)
            }
        }
        .onChange(of: artifact.id) { _, _ in showingFullScreen = false }
    }

    private func loadVerifiedImage() {
        guard artifact.byteCount > 0,
              artifact.byteCount <= 12 * 1_024 * 1_024,
              !artifact.relativePath.hasPrefix("/"),
              !artifact.relativePath.split(separator: "/").contains(".."),
              artifact.relativePath.hasPrefix("GeneratedImages/") ||
                artifact.relativePath.hasPrefix("BrowserArtifacts/") ||
                artifact.relativePath.hasPrefix("VNCArtifacts/"),
              let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
              ).first else {
            failed = true
            return
        }
        let root = support.appendingPathComponent("FloeAgent", isDirectory: true)
            .standardizedFileURL
        let candidate = root.appendingPathComponent(artifact.relativePath)
            .standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard candidate.path.hasPrefix(prefix),
              let data = try? Data(floeContentsOf: candidate, options: [.mappedIfSafe]),
              data.count == artifact.byteCount else {
            failed = true
            return
        }
        let digest = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }.joined()
        guard digest == artifact.sha256.lowercased(), let decoded = UIImage(data: data) else {
            failed = true
            return
        }
        image = decoded
        fileURL = candidate
    }
}

private struct FullScreenArtifactImage: View {
    let image: UIImage
    let fileURL: URL
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(scale)
                    .gesture(
                        MagnifyGesture()
                            .onChanged { value in
                                scale = min(6, max(1, lastScale * value.magnification))
                            }
                            .onEnded { _ in lastScale = scale }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.snappy) {
                            scale = scale > 1 ? 1 : 2.5
                            lastScale = scale
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .toolbarBackground(.black.opacity(0.72), for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("完成") { dismiss() }
                        .foregroundStyle(.white)
                        .frame(minHeight: FloeTheme.minimumTarget)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: fileURL) {
                        Label("保存或共享图片", systemImage: "square.and.arrow.up")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.white)
                    }
                }
            }
        }
    }
}
#endif
