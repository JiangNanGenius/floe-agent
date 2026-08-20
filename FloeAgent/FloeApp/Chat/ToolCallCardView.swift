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
            if isExpanded {
                detail
            }
        }
        .padding(10)
        .background(FloeTheme.groupedSurface, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Header: icon + name + status chip + duration + fold

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
                .accessibilityHidden(true)
            Text(name)
                .font(FloeTheme.Typography.metadata.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(statusTitle)
                .font(FloeTheme.Typography.metadata)
                .foregroundStyle(statusColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(statusColor.opacity(0.12), in: Capsule())
            if let duration {
                Text(durationText(duration))
                    .font(FloeTheme.Typography.metadata)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if hasDetail {
                Button {
                    withAnimation(FloeTheme.motionAnimation(reduceMotion: reduceMotion)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .frame(
                    minWidth: FloeTheme.minimumTarget,
                    minHeight: FloeTheme.minimumTarget
                )
                .accessibilityLabel(
                    isExpanded
                        ? LocalizedStringKey("thread.collapse")
                        : LocalizedStringKey("thread.expand")
                )
            }
        }
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
        }
    }

    private func labeledEvidence(title: LocalizedStringKey, text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(FloeTheme.Typography.metadata)
                .foregroundStyle(.tertiary)
            Text(text)
                .font(FloeTheme.Typography.evidence)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Status mapping

    private var hasDetail: Bool {
        (inputSummary?.isEmpty == false) || (resultSummary?.isEmpty == false)
    }

    private var imageArtifacts: [ToolArtifactReference] {
        artifacts.filter { $0.mimeType == "image/png" || $0.mimeType == "image/jpeg" }
    }

    private var statusIcon: String {
        switch status {
        case "ok", "completed": "checkmark.circle"
        case "failed", "error": "xmark.octagon"
        default: "wrench.and.screwdriver"
        }
    }

    private var statusColor: Color {
        switch status {
        case "ok", "completed": FloeTheme.success
        case "failed", "error": FloeTheme.destructive
        case "running", "executingTool": FloeTheme.primary
        default: FloeTheme.pending
        }
    }

    private var statusTitle: LocalizedStringKey {
        switch status {
        case "ok", "completed": "tool.status.succeeded"
        case "failed", "error": "tool.status.failed"
        case "running", "executingTool": "tool.status.running"
        default: "tool.status.pending"
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

    var body: some View {
        Group {
            if let image, let fileURL {
                VStack(alignment: .leading, spacing: 8) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .accessibilityLabel("生成的图片")
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
    }

    private func loadVerifiedImage() {
        guard artifact.byteCount > 0,
              artifact.byteCount <= 12 * 1_024 * 1_024,
              !artifact.relativePath.hasPrefix("/"),
              !artifact.relativePath.split(separator: "/").contains(".."),
              artifact.relativePath.hasPrefix("GeneratedImages/") ||
                artifact.relativePath.hasPrefix("BrowserArtifacts/"),
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
#endif
