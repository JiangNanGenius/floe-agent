import Foundation
import Testing
@testable import FloeCore

@Suite("FloeCore.ModelSelectionPreferences")
struct ModelSelectionPreferencesTests {
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
}
