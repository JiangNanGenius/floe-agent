import Foundation
import FloeCore
import FloeModels
import FloeTools
import FloeWorkspace

/// The model sees one native API call. Apple controls the interactive system
/// session; completion, cancellation and artifact persistence remain explicit.
struct AppleImagePlaygroundTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        let prompt: String
        var sourcePath: String?
        var intent: AppleImagePlaygroundIntent?
        var style: AppleImagePlaygroundStyle?
        var width: Int?
        var height: Int?
    }

    static let name = "image.playground"
    static let toolDescription = """
        Create an image or edit an original with Apple's built-in Image Playground (图乐园). No cloud image API key is required. Pass a description and optionally a workspace-relative sourcePath; intent defaults to edit with an original, otherwise generate. Editing requires iOS 27+. This opens Apple's sheet in the owning foreground task and waits for the person to choose an image or cancel; it cannot run unattended or auto-confirm. Newer systems may use Apple Private Cloud Compute, so do not promise offline generation. Width/height request the closest supported size. Returns a verified new file and durable task output, preserving the original. Call this dedicated tool when the user explicitly requests Image Playground. For ordinary image requests use image.models and image.generate: they prefer configured cloud routes and honor the independent automatic Image Playground switch. Do not bypass that switch with an unsolicited direct call. Explicit requests remain supported when automatic participation is off. Unsupported system/device/language/region, a missing visible host or cancellation returns no image.
        """
    static let parametersJSON = #"""
        {"type":"object","properties":{"prompt":{"type":"string","minLength":1,"maxLength":16384,"description":"Description of the image or requested modification"},"sourcePath":{"type":"string","description":"Optional existing image path relative to this task's workspace"},"intent":{"type":"string","enum":["generate","edit"],"description":"Defaults to edit with sourcePath, otherwise generate. generate uses the original as inspiration; edit preserves it as closely as the system supports."},"style":{"type":"string","enum":["automatic","animation","illustration","sketch"]},"width":{"type":"integer","minimum":64,"maximum":4096},"height":{"type":"integer","minimum":64,"maximum":4096}},"required":["prompt"],"additionalProperties":false}
        """#
    static let riskLabels: Set<RiskLabel> = [.readsFiles, .writesFiles, .sendsDataToProvider, .controlsGUI]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .mutating
    static let executionBoundary: ToolExecutionBoundary = .mainRunOnly
    static let supportsConcurrentBatchDispatch = false

    private let service: AppleImagePlaygroundService

    init(service: AppleImagePlaygroundService) { self.service = service }

    func validate(_ args: Arguments) throws {
        let intent = args.intent ?? (args.sourcePath == nil ? .generate : .edit)
        guard !args.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              args.prompt.utf8.count <= 16_384,
              intent != .edit || args.sourcePath?.isEmpty == false else {
            throw AppleImagePlaygroundFailure.invalidInput("Supply a description and an original image path when editing.")
        }
        if let path = args.sourcePath {
            guard !path.isEmpty, path.utf8.count <= 4096,
                  !path.hasPrefix("/"), !path.hasPrefix("~") else {
                throw AppleImagePlaygroundFailure.invalidInput("The original must be a workspace-relative image path.")
            }
        }
        if args.width != nil || args.height != nil {
            guard let width = args.width, let height = args.height,
                  (64...4096).contains(width), (64...4096).contains(height) else {
                throw AppleImagePlaygroundFailure.invalidInput("Supply both width and height, each between 64 and 4096.")
            }
        }
    }

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try await execute(args, context: context, producerTool: Self.name)
    }

    func execute(_ args: Arguments, context: ToolContext, producerTool: String) async throws -> ToolExecutionOutput {
        guard [Self.name, "image.generate"].contains(producerTool),
              context.executionToolName == nil || context.executionToolName == producerTool else { throw FloeError.unauthorized }
        try validate(args)
        try context.cancellation.throwIfCancelled()
        guard !context.temporaryReadOnly, !context.publicWebOnly,
              context.childExecution == nil, context.childBudget == nil,
              let conversationID = context.conversationID,
              let callID = context.toolCallID, !callID.isEmpty,
              let root = context.workspaceRootURL, root.isFileURL else {
            throw FloeError.validationFailed("Image Playground requires the owning task and its writable workspace.")
        }
        try AppleImagePlaygroundOutput.validateDestinationAccess(context)
        let guarder = WorkspacePathGuard(rootURL: root,
            maxReadBytes: AppleImagePlaygroundImage.maximumBytes,
            maxWriteBytes: AppleImagePlaygroundImage.maximumBytes)
        let source: AppleImagePlaygroundImage?
        if let path = args.sourcePath {
            try context.authorizeWorkspacePath(path)
            let url = try guarder.resolve(path)
            try guarder.assertReadableSize(url)
            source = try AppleImagePlaygroundImage(contentsOf: url)
        } else { source = nil }
        let input = AppleImagePlaygroundInput(prompt: args.prompt,
            source: source, intent: args.intent ?? (source == nil ? .generate : .edit),
            style: args.style ?? .automatic, width: args.width, height: args.height)
        let image: AppleImagePlaygroundImage
        do {
            image = try await service.request(input,
                owner: AppleImagePlaygroundOwner(conversationID: conversationID,
                    runID: context.runID, toolCallID: callID),
                isCancelled: { context.cancellation.isCancelled })
        } catch let failure as AppleImagePlaygroundFailure {
            let state: String
            switch failure {
            case .cancelled: state = "cancelled"
            case .foregroundRequired: state = "foregroundRequired"
            case .ownerChanged: state = "ownerChanged"
            case .unavailable: state = "unavailable"
            case .busy: state = "busy"
            case .editingUnavailable: state = "editingUnavailable"
            case .invalidImage, .invalidInput: state = "failed"
            }
            let message = AppleImagePlaygroundCopy.message(for: failure)
            let bytes = try JSONEncoder().encode(FailureResult(state: state, message: message))
            return ToolExecutionOutput(summary: String(decoding: bytes, as: UTF8.self),
                fullOutputSHA256: FloeDigest.sha256Hex(bytes), exitStatus: state == "cancelled" ? 130 : 75)
        }
        try Task.checkCancellation()
        try context.cancellation.throwIfCancelled()
        return try AppleImagePlaygroundOutput.persist(image, context: context, producerTool: producerTool)
    }

    private struct FailureResult: Encodable { let state: String; let message: String }
}

enum AppleImagePlaygroundOutput {
    static func validateDestinationAccess(_ context: ToolContext) throws {
        guard let root = context.workspaceRootURL, root.isFileURL,
              (try? root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
              let callID = context.toolCallID, !callID.isEmpty,
              context.conversationID != nil, !context.temporaryReadOnly, !context.publicWebOnly else {
            throw FloeError.validationFailed("The original task's writable workspace is unavailable.")
        }
        let directory = "GeneratedImages/Apple/\(context.runID.uuidString)"
        try context.authorizeWorkspacePath(directory)
        _ = try WorkspacePathGuard(rootURL: root).resolve(directory)
        try context.cancellation.throwIfCancelled()
    }

    /// Single standard workspace commit + immutable run-output publication.
    /// Qualification may inject its own snapshot root; model arguments cannot.
    static func persist(_ image: AppleImagePlaygroundImage, context: ToolContext,
                        snapshotRoot: URL? = nil,
                        producerTool: String = AppleImagePlaygroundTool.name) throws -> ToolExecutionOutput {
        guard [AppleImagePlaygroundTool.name, "image.generate"].contains(producerTool) else {
            throw FloeError.unauthorized
        }
        try context.cancellation.throwIfCancelled()
        try validateDestinationAccess(context)
        guard !context.temporaryReadOnly, !context.publicWebOnly,
              let root = context.workspaceRootURL, root.isFileURL,
              context.conversationID != nil,
              let callID = context.toolCallID, !callID.isEmpty else {
            throw FloeError.validationFailed("Image output requires the original task's writable workspace.")
        }
        let callDigest = FloeDigest.sha256Hex(Data(callID.utf8))
        let path = "GeneratedImages/Apple/\(context.runID.uuidString)/\(callDigest).\(image.fileExtension)"
        try context.authorizeWorkspacePath(path)
        let guarder = WorkspacePathGuard(rootURL: root,
            maxReadBytes: AppleImagePlaygroundImage.maximumBytes,
            maxWriteBytes: AppleImagePlaygroundImage.maximumBytes)
        let url = try guarder.resolve(path)
        if FileManager.default.fileExists(atPath: url.path) {
            let prior = try AppleImagePlaygroundImage(contentsOf: url)
            guard prior.sha256 == image.sha256 else {
                throw FloeError.validationFailed("This image call already saved different content; the earlier image is preserved.")
            }
        } else {
            try AtomicFileCommitter.commit(image.data, to: url, policy: FileCommitPolicy(
                conflict: .failIfExists, maxBytes: AppleImagePlaygroundImage.maximumBytes,
                verifyBeforeCommit: { staged in
                    guard try AppleImagePlaygroundImage(contentsOf: staged).sha256 == image.sha256 else {
                        throw AppleImagePlaygroundFailure.invalidImage
                    }
                }, checkCancellation: { try context.cancellation.throwIfCancelled() }))
        }
        try context.cancellation.throwIfCancelled()
        let output = try RunOutputSnapshotStore.publish(RunOutputSnapshotRequest(
            producerTool: producerTool, slot: "image",
            commit: RunOutputCommit(sourceURL: url, sha256: image.sha256, byteCount: image.data.count,
                displayName: "Image Playground.\(image.fileExtension)", mimeType: image.mimeType, uti: image.uti)),
            using: context, artifactRoot: snapshotRoot)
        struct Receipt: Encodable {
            let state = "created"
            let backend = "appleImagePlayground"
            let path: String
            let mimeType: String
            let byteCount: Int
            let sha256: String
            let width: Int
            let height: Int
            let inlineMarkdown: String
        }
        let receipt = Receipt(path: path, mimeType: image.mimeType, byteCount: image.data.count,
            sha256: image.sha256, width: image.width, height: image.height,
            inlineMarkdown: ChatContentReference(kind: .output, ownerID: context.runID,
                contentID: output.outputID)!.markdown(title: "Image Playground"))
        let bytes = try JSONEncoder().encode(receipt)
        return ToolExecutionOutput(summary: String(decoding: bytes, as: UTF8.self),
            fullOutputSHA256: FloeDigest.sha256Hex(bytes), exitStatus: 0,
            outputFiles: [output])
    }
}

@MainActor
func registerAppleImagePlaygroundTool(service: AppleImagePlaygroundService,
                                     registry: ToolRunnerRegistry = .shared) {
    ToolCatalog.register(AppleImagePlaygroundTool.self)
    registry.register(AppleImagePlaygroundTool(service: service))
}

enum AppleImagePlaygroundCopy {
    static var title: String { FloeL10n.isChinese ? "图乐园" : "Image Playground" }
    static var detail: String {
        FloeL10n.isChinese ? "使用 Apple 图乐园生成或修改图片。需要在系统面板中完成选择。"
            : "Create or edit images with Apple Image Playground. Finish your selection in the system sheet."
    }

    static func message(for failure: AppleImagePlaygroundFailure) -> String {
        guard FloeL10n.isChinese else { return failure.localizedDescription }
        switch failure {
        case .unavailable: return "当前设备暂不可用图乐园，请检查系统设置后重试。"
        case .foregroundRequired: return "请打开原任务后使用图乐园。"
        case .busy: return "请先完成或关闭当前图乐园面板。"
        case .cancelled: return "已取消图片创作。"
        case .ownerChanged: return "原任务已关闭，图片未写入其他任务。"
        case .editingUnavailable: return "原图修改需要 iOS 27 或更新系统。"
        case .invalidImage: return "图片无效、格式不支持或大小超出限制。"
        case .invalidInput: return "请填写图片描述；修改图片时还需提供原图路径。"
        }
    }
}
