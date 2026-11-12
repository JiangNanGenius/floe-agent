// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import ImageIO
import UniformTypeIdentifiers
import FloeCore
import FloeModels
import FloePersistence
import FloeTools
import FloeMarkdown

/// Ordinary Markdown remains on its original renderer. Stable block offsets
/// keep earlier native cards mounted as later streamed paragraphs arrive.
struct InlineAnswerBodyView: View {
    let source: String
    var isStreaming = false
    var helpRunID: UUID? = nil
    @Environment(\.helpContentCenter) private var helpCenter
    @State private var helpReferences: [HelpReference] = []
    @Environment(\.helpSceneID) private var helpSceneID
    @Environment(\.chatInlineContentScope) private var helpScope
    @Environment(\.openURL) private var inheritedHelpOpenURL
    #if canImport(AlarmKit)
    @Environment(\.inlineTimerProjection) private var inlineTimerProjection
    #endif
    var body: some View {
        let blocks = InlineContentBlockParser.parse(source, streaming: isStreaming)
        #if canImport(AlarmKit)
        let suppressedTimerBlocks = InlineTimerBodyProjection.suppressedReferenceBlockIDs(
            text: source, sources: inlineTimerProjection, isStreaming: isStreaming)
        let visibleBlocks = blocks.filter { !suppressedTimerBlocks.contains($0.id) }
        #else
        let visibleBlocks = blocks
        #endif
        VStack(alignment: .leading, spacing: 10) {
            ForEach(visibleBlocks) { block in
                switch block.content {
                case .markdown(let text): MarkdownRendererView(source: text, isStreaming: isStreaming && block.id == blocks.last?.id)
                case .reference(let title, let uri): ChatInlineContentView(title: title, uri: uri)
                }
            }
            #if canImport(AlarmKit)
            // Projected native countdown timers for answers whose model text
            // omitted the reference: appended once per whole answer (never
            // per paragraph), each card verifying its own durable receipt.
            let projectedTimers = InlineTimerBodyProjection.unreferencedSources(
                inlineTimerProjection, text: source, isStreaming: isStreaming)
            if !projectedTimers.isEmpty {
                ForEach(projectedTimers, id: \.creationID) { timerSource in
                    InlineTimerCard(source: timerSource)
                }
            }
            #endif
            if let center = helpCenter, let sceneID = helpSceneID, let scope = helpScope, !scope.isTemporary {
                ForEach(helpReferences) { reference in
                    HelpAnswerGuideCard(center: center, reference: reference, sceneID: sceneID,
                        conversationID: scope.conversationID, answerRunID: helpRunID)
                }
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
        .task(id: source) {
            guard source.contains("floe-help://") else { helpReferences = []; return }
            if isStreaming {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
            let text = source
            let worker = Task.detached(priority: .utility) { HelpAnswerReferences.references(in: text) }
            let references = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            helpReferences = references
        }
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "floe-help" else {
                inheritedHelpOpenURL(url)
                return .handled
            }
            guard let reference = try? HelpReferenceLink.reference(from: url),
                  let sceneID = helpSceneID, let scope = helpScope, !scope.isTemporary else { return .discarded }
            return HelpPresentationCoordinator.shared.presentFromUser(
                reference: reference, sceneID: sceneID, currentConversationID: scope.conversationID
            ) ? .handled : .discarded
        })
    }
}

private struct ChatInlineContentRequest: Hashable {
    let uri: String
    let scope: ChatInlineContentScope?
    let attempt: Int
}
private struct ChatInlineContentView: View {
    @EnvironmentObject private var router: AppRouter
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
                    Label(IDELanguageRunText.t("暂时无法预览。可重试或在文件列表中打开。", "Preview is unavailable. Retry or open the file from the file list."), systemImage: "doc.badge.ellipsis")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        Button(IDELanguageRunText.t("重试", "Retry")) { attempt += 1 }
                        if let scope, !scope.isTemporary, router.selectedConversationID == scope.conversationID {
                            Button(IDELanguageRunText.t("文件列表", "Files")) { router.showInspector(.workspaceFiles) }
                        }
                    }.frame(minHeight: 44)
                }
            } else if let resolved {
                switch resolved {
                case .artifact(let ref, let runID, let tool):
                    #if canImport(AlarmKit)
                    // A verified native timer binding renders the live card,
                    // not a generic rich-artifact fallback.
                    if tool == "apple.alarm.schedule", ref.mimeType == NativeTimerBinding.mimeType {
                        InlineTimerCard(source: InlineTimerCardSource(artifact: ref, runID: runID, tool: tool))
                    } else { artifactContent(tool: tool) }
                    #else
                    artifactContent(tool: tool)
                    #endif
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
                    conversations: environment.conversationStore, runs: environment.runStore,
                    children: SQLiteChildRunStore(database: environment.database))
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

    @ViewBuilder
    private func artifactContent(tool: String) -> some View {
        if let verifiedArtifact {
            if ToolArtifactPresentation.isImage(verifiedArtifact.artifact) {
                ArtifactImageView(artifact: verifiedArtifact.artifact, index: 0, preverified: verifiedArtifact)
            } else {
                RichArtifactView(artifact: verifiedArtifact.artifact, preverified: verifiedArtifact,
                    compactAudio: tool == "audio.synthesize",
                    fileDiffDisposition: NativeFileDiffDisposition.writeTools.contains(tool) ? .applied : .reference)
            }
        } else { ProgressView().controlSize(.small) }
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
