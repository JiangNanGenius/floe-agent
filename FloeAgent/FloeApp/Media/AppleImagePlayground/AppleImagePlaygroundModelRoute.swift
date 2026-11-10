// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCore
import FloeModels
import FloeTools

@MainActor enum AppleImagePlaygroundModelRoute {
    static func generateIfSelected(_ args: RemoteImageGenerateTool.Arguments, context: ToolContext,
        center: FilesCenter) async throws -> ToolExecutionOutput? {
        let conversation = center.environment.conversationCenter
        let explicitNative = args.modelID == AppleImagePlaygroundModelIdentity.profileID
            || args.model.map(AppleImagePlaygroundModelIdentity.matches) == true
        let preferred = conversation.modelPreferences.auxiliaryImageMode == .shared
            ? conversation.modelPreferences.sharedImageModelID : conversation.modelPreferences.imageGenerationModelID
        let native = AppleImagePlaygroundModelIdentity.shouldUse(explicitNative: explicitNative,
            explicitOther: !explicitNative && (args.model != nil || args.modelID != nil),
            preferredNative: preferred == AppleImagePlaygroundModelIdentity.profileID,
            hasCloud: !conversation.agentImageRoutes(operation: .generate).isEmpty,
            automaticEnabled: AppleImagePlaygroundModelIdentity.automaticRoutingEnabled()
                && conversation.imageModels.contains(where: { $0.id == AppleImagePlaygroundModelIdentity.profileID }),
            systemAvailable: center.environment.appleImagePlaygroundService.isAvailable)
        guard native else { return nil }
        guard (args.count ?? 1) == 1 else {
            throw FloeError.validationFailed("Image Playground returns one selected image per request. Use count:1.")
        }
        guard args.quality == nil, args.resolution == nil, args.aspectRatio == nil else {
            throw FloeError.validationFailed("Image Playground uses the system image choices; omit quality, resolution and aspectRatio. A size may request the closest supported dimensions.")
        }
        var width: Int?, height: Int?
        if let size = args.size {
            let parts = size.lowercased().split(separator: "x")
            guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]),
                  (64...4096).contains(w), (64...4096).contains(h) else {
                throw FloeError.validationFailed("Use size:WIDTHxHEIGHT or omit size for Image Playground.")
            }
            width = w; height = h
        }
        return try await AppleImagePlaygroundTool(service: center.environment.appleImagePlaygroundService)
            .execute(.init(prompt: args.prompt, width: width, height: height), context: context,
                producerTool: RemoteImageGenerateTool.name)
    }
}
#endif
