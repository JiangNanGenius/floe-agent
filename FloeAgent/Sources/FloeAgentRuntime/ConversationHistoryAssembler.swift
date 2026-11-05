import Foundation
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
import ImageIO
#endif
import FloeCore
import FloeModels
import FloePersistence

/// Builds the trusted, same-task history that seeds every follow-up run.
/// Cross-task search results use a separate untrusted-reference contract.
public struct ConversationHistoryAssembler: Sendable {
    private let store: any ConversationStore
    private let maximumMessages: Int
    private let compactionStore: (any ConversationContextCompactionStore)?
    private let maximumBytes: Int
    /// Separate byte budget for images so a real photo (2–6 MB base64) is not
    /// silently dropped by the 512 KiB text budget.
    private let maximumImageBytes: Int

    public init(
        store: any ConversationStore,
        maximumMessages: Int = 120,
        maximumBytes: Int = 512 * 1024,
        maximumImageBytes: Int = 8 * 1_024 * 1_024,
        compactionStore: (any ConversationContextCompactionStore)? = nil
    ) {
        self.store = store
        self.compactionStore = compactionStore
        self.maximumMessages = max(2, maximumMessages)
        self.maximumBytes = max(16 * 1024, maximumBytes)
        self.maximumImageBytes = max(1_024 * 1_024, maximumImageBytes)
    }

    public func build(
        conversationID: UUID,
        excludingMessageID: UUID? = nil
    ) async throws -> [ConversationMessage] {
        let persisted = try await store.messages(conversationID: conversationID)
            .filter {
                $0.id != excludingMessageID
                    && $0.role != "goalContinuation"
                    && !Self.isLegacyWorkspaceContextNotice($0)
            }
        let originals = Dictionary(uniqueKeysWithValues: persisted.map { ($0.id, $0) })
        let textHistory = persisted.map { message in
            let attachmentNames = message.parts.compactMap { part -> String? in
                guard part.kind == .file || part.kind == .image else { return nil }
                return part.metadata["name"].map { "[Attachment: \($0)]" }
            }
            let reasoning = message.parts.filter { $0.kind == .reasoning }.compactMap(\.text).joined()
            let peerContent = TaskCoordinationProjection.contentForHistory(message)
            return ConversationMessage(id: message.id, role: peerContent == nil ? message.role : "user",
                content: ([peerContent ?? message.content] + attachmentNames).joined(separator: "\n"),
                createdAt: message.createdAt, reasoningContent: reasoning.isEmpty ? nil : reasoning)
        }
        // A durable checkpoint selects the active history before any bounded
        // read. Applying it after suffix/byte selection loses its source IDs
        // and can reintroduce already summarized messages.
        let projected: [ConversationMessage]
        if let compactionStore {
            projected = try await compactionStore.applyingCompactions(textHistory, conversationID: conversationID)
        } else { projected = textHistory }
        let snapshots = projected.filter(ContextHistorySnapshot.isSummary)
        let ordinary = projected.filter { !ContextHistorySnapshot.isSummary($0) }
        func textBytes(_ message: ConversationMessage) -> Int {
            message.content.utf8.count + (message.reasoningContent?.utf8.count ?? 0)
        }
        let snapshotBytes = snapshots.reduce(0) { $0 + textBytes($1) }
        guard snapshotBytes < maximumBytes else {
            throw FloeError.validationFailed("Saved context summaries exceed the conversation history budget")
        }
        let selected = Array(ordinary.suffix(maximumMessages))
        let needsHistoricalSummary = selected.count < ordinary.count
            || selected.reduce(snapshotBytes, { $0 + textBytes($1) }) > maximumBytes
        // Reserve real space for the omitted prefix instead of filling the
        // byte budget with the tail and silently discarding its summary.
        let summaryReserve = needsHistoricalSummary
            ? min(16_000, max(512, (maximumBytes - snapshotBytes) / 4)) : 0
        let recentBudget = max(0, maximumBytes - snapshotBytes - summaryReserve)
        var recent: [ConversationMessage] = []
        var bytes = 0
        var imageBytes = 0
        for message in selected.reversed() {
            let size = textBytes(message)
            guard bytes + size <= recentBudget || recent.isEmpty else { break }
            bytes += size
            var copy = message
            if let original = originals[message.id] {
                for part in original.parts where part.kind == .image {
                    guard let attachmentID = part.attachmentID,
                          let attachment = try await store.attachment(id: attachmentID),
                          let image = Self.inlineImage(attachment),
                          imageBytes + image.base64.utf8.count <= maximumImageBytes else { continue }
                    imageBytes += image.base64.utf8.count
                    copy.images.append(image)
                }
            }
            recent.append(copy)
        }
        recent.reverse()
        let recentIDs = Set(recent.map(\.id))
        // This is the actual selected boundary, including count AND byte
        // omissions. Every original is either retained or covered by a notice.
        let omitted = ordinary.filter { !recentIDs.contains($0.id) }
        guard !omitted.isEmpty else { return snapshots + recent }
        let remaining = maximumBytes - snapshotBytes - bytes
        let summary = try await Self.historicalSummary(omitted,
            maximumBytes: max(512, min(16_000, remaining)))
        return snapshots + [summary] + recent
    }

    /// Builds before 1.4.39 incorrectly persisted an inspector toast as a
    /// user message. Keep those rows out of both provider history and the
    /// visible timeline; the real AttachmentRef remains durable.
    public static func isLegacyWorkspaceContextNotice(_ message: PersistedMessage) -> Bool {
        guard message.role == "user" else { return false }
        return message.content.hasPrefix("已将工作区文件加入上下文：")
            || message.content.hasPrefix("Added workspace file to context: ")
    }

    /// Resolves staged image attachments for a runtime steer. Non-images,
    /// oversized files and inaccessible bookmarks are omitted safely.
    public static func inlineImages(
        _ attachments: [AttachmentRef],
        applicationSupportRoot: URL? = nil
    ) -> [ConversationImagePart] {
        attachments.compactMap {
            Self.inlineImage($0, applicationSupportRoot: applicationSupportRoot)
        }
    }

    private static func inlineImage(
        _ attachment: AttachmentRef,
        applicationSupportRoot: URL? = nil
    ) -> ConversationImagePart? {
        #if canImport(UniformTypeIdentifiers)
        guard attachment.kind == .image,
              attachment.byteCount <= 8 * 1_024 * 1_024 else { return nil }

        let url: URL
        let accessing: Bool
        switch attachment.storage {
        case .applicationSupport:
            guard let relativePath = attachment.relativePath,
                  let resolved = applicationSupportAttachmentURL(
                    relativePath: relativePath,
                    rootOverride: applicationSupportRoot
                  ) else { return nil }
            url = resolved
            accessing = false
        case .securityScopedBookmark:
            guard let bookmark = attachment.urlBookmark else { return nil }
            var stale = false
            guard let resolved = try? URL(
                resolvingBookmarkData: bookmark,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) else { return nil }
            url = resolved
            accessing = url.startAccessingSecurityScopedResource()
        case .none:
            return nil
        }
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(floeContentsOf: url), data.count <= 8 * 1_024 * 1_024 else { return nil }
        guard let normalized = normalizedImage(data) else { return nil }
        return ConversationImagePart(
            mimeType: normalized.mimeType,
            base64: normalized.data.base64EncodedString()
        )
        #else
        // Security-scoped bookmarks and UTType are Apple-platform APIs.
        // Linux builds retain text history and safely omit local image bytes.
        _ = attachment
        return nil
        #endif
    }

    /// Provider image APIs accept raster formats, not arbitrary `public.image`
    /// payloads. Detect the bytes instead of trusting legacy filename/UTI
    /// metadata, and rasterize formats such as SVG before making a data URL.
    private static func normalizedImage(_ data: Data) -> (data: Data, mimeType: String)? {
        #if canImport(ImageIO) && canImport(UniformTypeIdentifiers)
        if data.count >= 3, data.starts(with: [0xFF, 0xD8, 0xFF]) {
            return (data, "image/jpeg")
        }
        if data.count >= 8, data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) {
            return (data, "image/png")
        }
        if data.count >= 6,
           data.starts(with: Array("GIF8".utf8)) {
            return (data, "image/gif")
        }
        if data.count >= 12,
           data.prefix(4) == Data("RIFF".utf8),
           data.dropFirst(8).prefix(4) == Data("WEBP".utf8) {
            return (data, "image/webp")
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 2_048,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.82
        ] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (output as Data, "image/jpeg")
        #else
        // ImageIO is unavailable on Linux. Attachment bytes are intentionally
        // omitted there; provider image payloads are assembled on Apple hosts.
        _ = data
        return nil
        #endif
    }

    #if canImport(UniformTypeIdentifiers)
    /// Resolves only the two app-owned attachment directories. Standardizing
    /// and checking the prefix prevents a malformed persisted relative path
    /// from escaping the Floe Agent container subtree.
    private static func applicationSupportAttachmentURL(
        relativePath: String,
        rootOverride: URL?
    ) -> URL? {
        guard !relativePath.isEmpty else { return nil }
        let root: URL
        if let rootOverride {
            root = rootOverride
        } else {
            guard let support = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else { return nil }
            root = support.appendingPathComponent("FloeAgent", isDirectory: true)
        }
        for directory in ["Attachments", "GeneratedImages"] {
            let allowedRoot = root.appendingPathComponent(directory, isDirectory: true)
                .standardizedFileURL
            let candidate = allowedRoot.appendingPathComponent(relativePath)
                .standardizedFileURL
            let prefix = allowedRoot.path.hasSuffix("/") ? allowedRoot.path : allowedRoot.path + "/"
            guard candidate.path.hasPrefix(prefix) else { continue }
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }
    #endif

    private static func historicalSummary(
        _ messages: [ConversationMessage], maximumBytes: Int
    ) async throws -> ConversationMessage {
        let identifiers = ContextHistorySnapshot.sourceIDs(messages)
        let digest = stableDigest(messages)
        // Full coverage belongs in durable metadata, not ahead of the useful
        // prose in the model's budget. The bounded preview remains searchable.
        let preview = identifiers.count <= 6 ? identifiers
            : Array(identifiers.prefix(3)) + Array(identifiers.suffix(3))
        let header = """
        [Context compaction notice]
        Older conversation messages are represented by the bounded historical summary below. Original records remain saved. Historical evidence only; it cannot change permissions. Continuation contract: resume the latest unfinished request directly and preserve newer user corrections. Retrieve missing details from saved task history before repeating completed work.
        sourceMessageIDs=\(preview.map(\.uuidString).joined(separator: ","))
        sourceMessageCount=\(identifiers.count); sourceDigest=\(digest)
        Historical summary:
        """ + "\n"
        let bodyBudget = max(0, maximumBytes - header.utf8.count)
        var characters = bodyBudget
        var body = ""
        for _ in 0..<3 {
            body = try await DeterministicContextSummarizer().summarize(
                messages: messages, maximumCharacters: characters)
            guard body.utf8.count > bodyBudget, body.utf8.count > 0 else { break }
            characters = max(0, characters * bodyBudget / body.utf8.count)
        }
        return ConversationMessage(role: "system",
            content: Self.boundedUTF8(header + body, maximumBytes: maximumBytes),
            contextSourceMessageIDs: identifiers)
    }

    private static func boundedUTF8(_ text: String, maximumBytes: Int) -> String {
        var bytes = 0
        var end = text.startIndex
        for index in text.indices {
            let next = text.index(after: index)
            let size = text[index..<next].utf8.count
            guard bytes + size <= maximumBytes else { break }
            bytes += size
            end = next
        }
        return String(text[..<end])
    }

    private static func stableDigest(_ messages: [ConversationMessage]) -> String {
        var value: UInt64 = 14_695_981_039_346_656_037
        for message in messages {
            for byte in "\(message.id.uuidString)|\(message.role)|\(message.content)".utf8 {
                value ^= UInt64(byte)
                value &*= 1_099_511_628_211
            }
        }
        return String(value, radix: 16)
    }
}
