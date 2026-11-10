// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import CryptoKit
import FloeWorkbench

extension MediaV2Session {
    static let providerToolIDs: Set<String> = ["image.inpaint","image.outpaint","video.transcribe","video.translate","video.voice-separate"]
    static func providerCapability(for toolID: String) -> MediaV2ProviderBridge.Capability? {
        switch toolID {
        case "image.inpaint","image.outpaint": .imageEditing
        case "video.transcribe": .transcription
        case "video.translate": .translation
        case "video.voice-separate": .stemSeparation
        default: nil
        }
    }
    func performProviderTool(_ id: String,input: MediaV2ToolInput,actor: MediaPreparedActorKind,
                             suppliedAuthority: MediaV2ProviderAuthority?) async throws -> MediaV2ToolReceipt {
        guard Self.providerToolIDs.contains(id),let capability = Self.providerCapability(for:id),
              !processingTool,!saving else { throw MediaV2CommandError.unavailable }
        guard input.expectedRevision == document.revision else { throw MediaPreparedCoreError.documentChanged }
        let base = document.revision
        let authority: MediaV2ProviderAuthority
        if actor == .model {
            guard let suppliedAuthority else { throw MediaPreparedCoreError.invalidOperation("Use the task-authorized studio.media.provider tool") }
            authority = suppliedAuthority
        } else {
            authority = try await MediaV2ProviderAuthority.userAction(session:self,capability:capability)
        }
        try await authority.authorize(capability:capability,projectID:self.id,revision:base)
        guard !processingTool,!saving,document.revision == base else { throw MediaPreparedCoreError.documentChanged }
        processingTool = true
        let worker = Task { @MainActor in
            switch id {
            case "image.inpaint":
                return try await providerImageEdit(id,input:input,actor:actor,base:base,authority:authority)
            case "image.outpaint":
                return try await providerOutpaint(input:input,actor:actor,base:base,authority:authority)
            case "video.transcribe":
                return try await providerTranscribe(input:input,actor:actor,base:base,authority:authority)
            case "video.voice-separate":
                return try await providerVoiceSeparate(input:input,actor:actor,base:base,authority:authority)
            default:
                return try await providerTranslate(input:input,actor:actor,base:base,authority:authority)
            }
        }
        cancelToolWork = { worker.cancel() }
        defer { processingTool = false;cancelToolWork = nil;providerStatus = nil }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
    func requireProviderSelection(_ input: MediaV2ToolInput,actor: MediaPreparedActorKind) throws -> Bool {
        if actor == .user { return true }
        guard let fence = input.selectionFence else { return false }
        guard try StudioMediaObservation.media(self).selectionFence == fence else { throw MediaPreparedCoreError.documentChanged }
        return true
    }
    private func providerImageEdit(_ id: String,input: MediaV2ToolInput,actor: MediaPreparedActorKind,
                                   base: Int64,authority: MediaV2ProviderAuthority) async throws -> MediaV2ToolReceipt {
        let fenced = try requireProviderSelection(input,actor:actor)
        guard project.kind == .image,let text = input.text?.trimmingCharacters(in:.whitespacesAndNewlines),!text.isEmpty,text.utf8.count<=32_768 else { throw MediaV2CommandError.invalidInput }
        let layer = input.objectID.flatMap { document.layer($0) } ?? (input.objectID == nil && fenced ? selectedLayer : nil)
        guard let layer,!layer.isLocked else { throw MediaV2CommandError.missingSelection }
        guard fenced,let region = selection else { throw MediaPreparedCoreError.invalidOperation(WorkbenchText.t("请先选择要重绘的区域。", "Select the area to redraw first.")) }
        let modelID: UUID?
        if let supplied = input.property { guard let parsed = UUID(uuidString:supplied) else { throw MediaV2CommandError.invalidInput };modelID = parsed } else { modelID = nil }
        providerStatus = WorkbenchText.t("正在准备选区…", "Preparing selection…")
        let image = try await renderedLayerImage(layer,revision:base)
        let prepare = Task.detached(priority:.userInitiated) {
            let reference = try MediaProviderEditPixels.prepareInpaint(image,selection:region)
            let digest = SHA256.hash(data:try MediaProviderEditPixels.pixelDigestInput(image)).map { String(format:"%02x",$0) }.joined()
            return (reference,digest)
        }
        let (reference,digest) = try await withTaskCancellationHandler { try await prepare.value } onCancel: { prepare.cancel() }
        try await authority.authorize(capability:.imageEditing,projectID:self.id,revision:base)
        guard selection == region else { throw MediaPreparedCoreError.documentChanged }
        providerStatus = WorkbenchText.t("正在生成图像…", "Generating image…")
        let result = try await MediaV2ProviderBridge.editImage(.init(sourcePNG:reference.sourcePNG,maskPNG:reference.maskPNG,prompt:text,modelID:modelID,width:image.width,height:image.height),authority:authority)
        try await authority.authorize(capability:.imageEditing,projectID:self.id,revision:base)
        guard selection == region else { throw MediaPreparedCoreError.documentChanged }
        let current = try await renderedLayerImage(layer,revision:base)
        let composite = Task.detached(priority:.userInitiated) {
            let currentDigest = SHA256.hash(data:try MediaProviderEditPixels.pixelDigestInput(current)).map { String(format:"%02x",$0) }.joined()
            guard currentDigest == digest else { throw MediaPreparedCoreError.documentChanged }
            return try MediaProviderEditPixels.compositeInpaint(result.imageData,over:image,selection:region)
        }
        let output = try await withTaskCancellationHandler { try await composite.value } onCancel: { composite.cancel() }
        try Task.checkCancellation();guard document.revision == base,selection == region else { throw MediaPreparedCoreError.documentChanged }
        providerStatus = WorkbenchText.t("正在保存图像…", "Saving image…")
        let commit = try await commitRenderedImage(output,replacing:layer,revision:base,actor:actor)
        return .init(documentID:document.id,revision:document.revision,toolID:id,groupID:commit.groupID,selectionOnly:false)
    }
}
#endif
