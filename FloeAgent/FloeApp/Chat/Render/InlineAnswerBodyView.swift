// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import FloeCore
import FloeModels
import FloeTools
import FloeMarkdown

/// Ordinary Markdown remains on its original renderer. Stable block offsets
/// keep earlier native cards mounted as later streamed paragraphs arrive.
struct InlineAnswerBodyView: View {
    let source: String
    var isStreaming = false
    var body: some View {
        let blocks = InlineContentBlockParser.parse(source, streaming: isStreaming)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks) { block in
                switch block.content {
                case .markdown(let text): MarkdownRendererView(source: text, isStreaming: isStreaming && block.id == blocks.last?.id)
                case .reference(let title, let uri): ChatInlineContentView(title: title, uri: uri)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ChatInlineContentRequest: Hashable {
    let uri: String
    let scope: ChatInlineContentScope?
    let attempt: Int
}
private struct ChatInlineContentView: View {
    let title: String
    let uri: String
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.chatInlineContentScope) private var scope
    @State private var resolved: ResolvedChatInlineContent?
    @State private var verifiedArtifact: VerifiedChatInlineArtifact?
    @State private var failed = false
    @State private var attempt = 0
    private var request: ChatInlineContentRequest { .init(uri: uri, scope: scope, attempt: attempt) }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if failed {
                VStack(alignment: .leading, spacing: 6) {
                    Label(IDELanguageRunText.t("内容暂时无法显示，请重试或重新生成。", "Content is unavailable. Retry or generate it again."), systemImage: "doc.badge.ellipsis")
                        .font(.callout).foregroundStyle(.secondary)
                    Button(IDELanguageRunText.t("重试", "Retry")) { attempt += 1 }.frame(minHeight: 44)
                }
            } else if let resolved {
                switch resolved {
                case .artifact(_, _, let tool):
                    if let verifiedArtifact {
                        if ToolArtifactPresentation.isImage(verifiedArtifact.artifact) {
                            ArtifactImageView(artifact: verifiedArtifact.artifact, index: 0, preverified: verifiedArtifact)
                        } else {
                            RichArtifactView(artifact: verifiedArtifact.artifact, preverified: verifiedArtifact,
                                compactAudio: tool == "audio.synthesize",
                                fileDiffDisposition: NativeFileDiffDisposition.writeTools.contains(tool) ? .applied : .reference)
                        }
                    } else { ProgressView().controlSize(.small) }
                case .output(let receipt, let context): RunOutputFileView(receipt: receipt, context: context)
                case .attachment(let attachment, let messageID):
                    InlineOwnedAttachmentView(attachment: attachment, messageID: messageID)
                }
            } else { ProgressView().controlSize(.small) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat.inlineContent")
        .task(id: request) {
            resolved = nil; verifiedArtifact = nil; failed = false
            let current = request
            do {
                guard let scope = current.scope, let reference = ChatContentReference(current.uri) else {
                    throw ChatInlineContentResolutionError.unavailable
                }
                let value = try await ChatInlineContentResolver.resolve(reference, scope: scope,
                    conversations: environment.conversationStore, runs: environment.runStore)
                var artifact: VerifiedChatInlineArtifact?
                if case .artifact(let ref, let runID, let tool) = value {
                    let worker = Task.detached(priority: .utility) {
                        let root = try FloeArtifactStore.root()
                        return try VerifiedChatInlineArtifact.load(ref, runID: runID, tool: tool, root: root)
                    }
                    artifact = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                }
                try Task.checkCancellation()
                guard request == current else { return }
                verifiedArtifact = artifact; resolved = value
            } catch is CancellationError {} catch {
                if !Task.isCancelled, request == current { failed = true }
            }
        }
    }
}

private struct InlineOwnedAttachmentView: View {
    let attachment: AttachmentRef
    let messageID: UUID
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.chatInlineContentScope) private var scope
    @State private var opening: ChatAttachmentOpenRequest?
    @State private var image: UIImage?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let image {
                Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            AttachmentChipRow(items: [.init(id: attachment.id.uuidString, name: attachment.displayName,
                kind: attachment.kind == .image ? .image : .file, attachmentID: attachment.id)], alignment: .leading, onOpen: { _ in
                guard let scope, !scope.isTemporary else { return }
                opening = .init(conversationID: scope.conversationID, messageID: messageID, attachmentID: attachment.id)
            })
        }
        .sheet(item: $opening) { ChatAttachmentOpenSheet(request: $0, environment: environment) }
        .task(id: attachment) {
            image = nil
            // Bookmarks keep the existing explicit open route; automatic
            // thumbnails are limited to app-owned immutable attachment bytes.
            guard let scope, !scope.isTemporary, attachment.conversationID == scope.conversationID,
                  attachment.kind == .image, attachment.storage == .applicationSupport,
                  let url = try? environment.filesCenter.resolveURL(for: attachment),
                  let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
            let root = support.appendingPathComponent("FloeAgent").standardizedFileURL
            guard url.standardizedFileURL.path.hasPrefix(root.path + "/") else { return }
            let relative = String(url.standardizedFileURL.path.dropFirst(root.path.count + 1))
            guard relative.hasPrefix("Attachments/") || relative.hasPrefix("GeneratedImages/") else { return }
            let worker = Task.detached(priority: .utility) { () -> Data? in
                guard let data = try? VerifiedChatInlineArtifact.read(relativePath: relative, root: root,
                    byteCount: attachment.byteCount, digest: attachment.sha256, limit: 16 * 1_024 * 1_024),
                      let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
                      let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
                      let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
                      width > 0, height > 0, width <= 16_384, height <= 16_384, width <= 40_000_000 / height,
                      let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 1_024
                      ] as CFDictionary) else { return nil }
                let output = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
                CGImageDestinationAddImage(destination, thumbnail, nil)
                guard CGImageDestinationFinalize(destination), output.length <= 4 * 1_024 * 1_024 else { return nil }
                return output as Data
            }
            let bytes = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, let bytes else { return }
            image = UIImage(data: bytes)
        }
    }
}
#endif
