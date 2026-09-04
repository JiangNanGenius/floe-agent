import Foundation
import Testing
@testable import FloeCore

@Suite("FloeCore.ModelSelectionPreferences")
struct ModelSelectionPreferencesTests {
    @Test("Canvas model routes inherit global defaults when unset")
    func canvasRoutesDefaultToInheritance() {
        let preferences = ModelSelectionPreferences()
        #expect(preferences.canvasAgentModelID == nil)
        #expect(preferences.canvasVisionModelID == nil)
    }

    @Test("Shared image model splits only into supported roles")
    func sharedToSeparate() {
        let id = UUID()
        var preferences = ModelSelectionPreferences(
            auxiliaryImageMode: .shared,
            sharedImageModelID: id
        )
        preferences.switchAuxiliaryMode(to: .separate) { _ in [.imageGeneration] }
        #expect(preferences.sharedImageModelID == nil)
        #expect(preferences.imageGenerationModelID == id)
        #expect(preferences.imageEditingModelID == nil)
    }

    @Test("Separate image roles merge only when the same model supports both")
    func separateToShared() {
        let id = UUID()
        var preferences = ModelSelectionPreferences(
            auxiliaryImageMode: .separate,
            imageGenerationModelID: id,
            imageEditingModelID: id
        )
        preferences.switchAuxiliaryMode(to: .shared) { _ in
            [.imageGeneration, .imageEditing]
        }
        #expect(preferences.sharedImageModelID == id)
        #expect(preferences.imageGenerationModelID == nil)
        #expect(preferences.imageEditingModelID == nil)
    }

    @Test("Different separate models require a new shared selection")
    func incompatibleMerge() {
        var preferences = ModelSelectionPreferences(
            auxiliaryImageMode: .separate,
            imageGenerationModelID: UUID(),
            imageEditingModelID: UUID()
        )
        preferences.switchAuxiliaryMode(to: .shared) { _ in
            [.imageGeneration, .imageEditing]
        }
        #expect(preferences.sharedImageModelID == nil)
    }

    @Test("Video routing remains independent from image-mode transitions")
    func videoRouteIsIndependent() {
        let imageID = UUID()
        let videoID = UUID()
        var preferences = ModelSelectionPreferences(
            auxiliaryImageMode: .shared,
            sharedImageModelID: imageID,
            defaultVideoModelID: videoID
        )
        preferences.switchAuxiliaryMode(to: .separate) { _ in
            [.imageGeneration, .imageEditing]
        }
        #expect(preferences.defaultVideoModelID == videoID)
    }

    @Test("Known media models are removed from approval routes without clearing missing synced models")
    func clearsKnownIncompatibleApprovalModels() {
        let providerID = UUID()
        let mediaID = UUID()
        let temporarilyMissingID = UUID()
        let media = ModelProfile(
            id: mediaID,
            providerID: providerID,
            remoteModelID: "image-only",
            displayName: "Image only",
            limits: ModelLimits(contextTokens: 1, maxOutputTokens: 0),
            capabilities: [.imageGeneration],
            useSurfaces: [.imageGeneration]
        )
        var preferences = ModelSelectionPreferences(
            approvalModelID: mediaID,
            packageReviewModelID: temporarilyMissingID
        )

        let cleared = preferences.clearKnownIncompatibleApprovalModels(
            modelsByID: [mediaID: media]
        )

        #expect(cleared == [mediaID])
        #expect(preferences.approvalModelID == nil)
        #expect(preferences.packageReviewModelID == temporarilyMissingID)
    }
}
