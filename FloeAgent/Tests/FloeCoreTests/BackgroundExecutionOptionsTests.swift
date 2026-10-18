import Foundation
import Testing
@testable import FloeCore

@Suite("FloeCore.BackgroundExecutionOptions")
struct BackgroundExecutionOptionsTests {
    @Test("Legacy choices migrate without dropping their enabled capabilities")
    func legacyMigration() throws {
        for legacy in BackgroundExecutionPreference.allCases {
            let restored = try JSONDecoder().decode(
                BackgroundExecutionPreference.self,
                from: JSONEncoder().encode(legacy)
            )
            let options = BackgroundExecutionOptions(legacy: restored)
            #expect(options.enhancedBackgroundEnabled)
            #expect(options.pictureInPictureEnabled == (legacy != .standard))
            #expect(options.screenFeedbackEnabled == (legacy == .screenShare))
            #expect(options.legacyPreference == legacy)
        }
    }

    @Test("Screen feedback enables its PiP dependency without enabling enhanced background")
    func feedbackDependency() {
        var options = BackgroundExecutionOptions(enhancedBackgroundEnabled: false)
        options.setScreenFeedbackEnabled(true)
        #expect(options.pictureInPictureEnabled)
        #expect(options.screenFeedbackEnabled)
        #expect(!options.enhancedBackgroundEnabled)
        options.setScreenFeedbackEnabled(false)
        #expect(options.pictureInPictureEnabled)
        #expect(!options.screenFeedbackEnabled)
    }

    @Test("Turning PiP off removes screen feedback but leaves enhanced background unchanged")
    func pipOffCascade() {
        for enhanced in [false, true] {
            var options = BackgroundExecutionOptions(
                enhancedBackgroundEnabled: enhanced,
                screenFeedbackEnabled: true
            )
            options.setPictureInPictureEnabled(false)
            #expect(!options.pictureInPictureEnabled)
            #expect(!options.screenFeedbackEnabled)
            #expect(options.enhancedBackgroundEnabled == enhanced)
        }
    }

    @Test("Every supported combination survives persistence without becoming exclusive")
    func combinationsRoundTrip() throws {
        for enhanced in [false, true] {
            for visual in BackgroundExecutionPreference.allCases {
                var options = BackgroundExecutionOptions(legacy: visual)
                options.enhancedBackgroundEnabled = enhanced
                let restored = try JSONDecoder().decode(
                    BackgroundExecutionOptions.self,
                    from: JSONEncoder().encode(options)
                )
                #expect(restored == options)
                #expect(restored.normalized == options)
            }
        }
    }

    @Test("Decoded inconsistent dependency is normalized at the settings boundary")
    func decodedDependency() throws {
        let bytes = Data("""
        {"enhancedBackgroundEnabled":false,"pictureInPictureEnabled":false,"screenFeedbackEnabled":true}
        """.utf8)
        let options = try JSONDecoder().decode(BackgroundExecutionOptions.self, from: bytes).normalized
        #expect(options.pictureInPictureEnabled)
        #expect(options.screenFeedbackEnabled)
        #expect(!options.enhancedBackgroundEnabled)
    }

    @Test("An all-off preference remains off and is distinct from regular enhanced processing")
    func allOffIsPreserved() throws {
        let off = BackgroundExecutionOptions(enhancedBackgroundEnabled: false)
        let restored = try JSONDecoder().decode(
            BackgroundExecutionOptions.self,
            from: JSONEncoder().encode(off)
        )
        #expect(restored != BackgroundExecutionOptions())
        #expect(restored == off)
        #expect(!restored.enhancedBackgroundEnabled)
        #expect(!restored.pictureInPictureEnabled)
        #expect(!restored.screenFeedbackEnabled)
    }
}
