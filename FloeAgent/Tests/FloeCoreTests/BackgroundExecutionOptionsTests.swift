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
            // The visual surfaces always implied the audio foundation; the
            // migration records it so PiP keeps working — but recording the
            // capability never plays sound (playback needs a real task).
            #expect(options.audioEnabled == (legacy != .standard))
            #expect(options.legacyPreference == legacy)
        }
    }

    @Test("Screen feedback enabling pulls in the WHOLE prerequisite chain (PiP, audio, enhanced)")
    func feedbackEnablesFullChain() {
        var options = BackgroundExecutionOptions(enhancedBackgroundEnabled: false)
        #expect(options.setScreenFeedbackEnabled(true))
        #expect(options.pictureInPictureEnabled)
        #expect(options.audioEnabled)
        #expect(options.screenFeedbackEnabled)
        // Latest approved plan: enabling a lower capability enables every
        // prerequisite above it — enhanced processing included.
        #expect(options.enhancedBackgroundEnabled)
        // Screen feedback has no dependents: turning it off is always
        // allowed and changes nothing else.
        #expect(options.setScreenFeedbackEnabled(false))
        #expect(options.pictureInPictureEnabled)
        #expect(options.audioEnabled)
        #expect(options.enhancedBackgroundEnabled)
        #expect(!options.screenFeedbackEnabled)
    }

    @Test("A prerequisite cannot be disabled while a dependent is active: the setter refuses, nothing cascades off")
    func disableIsRefusedWhileDependentsActive() {
        var options = BackgroundExecutionOptions(legacy: .screenShare)
        #expect(options.screenFeedbackEnabled)
        // PiP off is refused while screen feedback presents inside it.
        #expect(!options.setPictureInPictureEnabled(false))
        #expect(options.pictureInPictureEnabled)
        #expect(options.screenFeedbackEnabled)
        // Audio off is refused while PiP/feedback ride on it.
        #expect(!options.setAudioEnabled(false))
        #expect(options.audioEnabled)
        // Enhanced off is refused while ANY dependent is active.
        #expect(!options.setEnhancedBackgroundEnabled(false))
        #expect(options.enhancedBackgroundEnabled)
        // Nothing was silently cascaded off — the refusal is a no-op.
        #expect(options == BackgroundExecutionOptions(legacy: .screenShare))
        // Clearing dependents deepest-first unlocks each prerequisite.
        #expect(options.setScreenFeedbackEnabled(false))
        #expect(options.pictureInPictureEnabled) // PiP itself stays on
        #expect(options.setPictureInPictureEnabled(false))
        #expect(!options.pictureInPictureEnabled)
        #expect(options.setAudioEnabled(false))
        #expect(!options.audioEnabled)
        #expect(options.setEnhancedBackgroundEnabled(false))
        #expect(!options.enhancedBackgroundEnabled)
    }

    @Test("Enabling PiP pulls in audio and enhanced; enabling audio pulls in enhanced")
    func enablePullsPrerequisites() {
        var pip = BackgroundExecutionOptions(enhancedBackgroundEnabled: false)
        #expect(pip.setPictureInPictureEnabled(true))
        #expect(pip.audioEnabled)
        #expect(pip.enhancedBackgroundEnabled)
        var audio = BackgroundExecutionOptions(enhancedBackgroundEnabled: false)
        #expect(audio.setAudioEnabled(true))
        #expect(audio.enhancedBackgroundEnabled)
        #expect(!audio.pictureInPictureEnabled)
        // Enhanced alone grants nothing above it.
        var enhanced = BackgroundExecutionOptions(enhancedBackgroundEnabled: false)
        #expect(enhanced.setEnhancedBackgroundEnabled(true))
        #expect(!enhanced.audioEnabled)
        #expect(!enhanced.pictureInPictureEnabled)
        #expect(!enhanced.screenFeedbackEnabled)
    }

    @Test("Blocking and pulling helper lists drive the actionable settings copy")
    func dependencyHelperContract() {
        let options = BackgroundExecutionOptions(legacy: .screenShare)
        #expect(options.activeDependentsBlockingDisable(of: .enhancedBackground)
            == [.audio, .pictureInPicture, .screenFeedback])
        #expect(options.activeDependentsBlockingDisable(of: .audio)
            == [.pictureInPicture, .screenFeedback])
        #expect(options.activeDependentsBlockingDisable(of: .pictureInPicture)
            == [.screenFeedback])
        #expect(options.activeDependentsBlockingDisable(of: .screenFeedback).isEmpty)
        #expect(options.activeDependentsBlockingDisable(of: .taskLiveActivity).isEmpty)
        let bare = BackgroundExecutionOptions(enhancedBackgroundEnabled: false)
        #expect(bare.prerequisitesEnabledByTurningOn(.screenFeedback)
            == [.pictureInPicture, .audio, .enhancedBackground])
        #expect(bare.prerequisitesEnabledByTurningOn(.audio) == [.enhancedBackground])
        #expect(bare.prerequisitesEnabledByTurningOn(.enhancedBackground).isEmpty)
        #expect(options.prerequisitesEnabledByTurningOn(.screenFeedback).isEmpty)
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

    @Test("Decoded inconsistent dependency is normalized upward at the settings boundary")
    func decodedDependency() throws {
        let bytes = Data("""
        {"enhancedBackgroundEnabled":false,"pictureInPictureEnabled":false,"screenFeedbackEnabled":true}
        """.utf8)
        let options = try JSONDecoder().decode(BackgroundExecutionOptions.self, from: bytes).normalized
        #expect(options.pictureInPictureEnabled)
        #expect(options.screenFeedbackEnabled)
        #expect(options.audioEnabled)
        // Migration never rewrites a stored explicit enhanced=false: the
        // upgrade must not silently grant continued processing. The full
        // chain applies to the user's NEXT action through the setters.
        #expect(!options.enhancedBackgroundEnabled)
    }

    @Test("A stored visual object from before the audio capability keeps working and never auto-plays")
    func preAudioObjectMigrates() throws {
        // Objects persisted before this round carry no `audioEnabled` key.
        let pip = Data("""
        {"enhancedBackgroundEnabled":true,"pictureInPictureEnabled":true,"screenFeedbackEnabled":false}
        """.utf8)
        let migrated = try JSONDecoder().decode(BackgroundExecutionOptions.self, from: pip)
        #expect(migrated.audioEnabled)
        let standard = Data("""
        {"enhancedBackgroundEnabled":true,"pictureInPictureEnabled":false,"screenFeedbackEnabled":false}
        """.utf8)
        let calm = try JSONDecoder().decode(BackgroundExecutionOptions.self, from: standard)
        #expect(!calm.audioEnabled)
    }

    @Test("An explicitly stored audio off with PiP on repairs up to the prerequisite, never dropping the surface")
    func inconsistentAudioRepairsUpward() throws {
        let bytes = Data("""
        {"enhancedBackgroundEnabled":true,"audioEnabled":false,"pictureInPictureEnabled":true,"screenFeedbackEnabled":false,"taskLiveActivityEnabled":false}
        """.utf8)
        let options = try JSONDecoder().decode(BackgroundExecutionOptions.self, from: bytes).normalized
        #expect(options.pictureInPictureEnabled)
        #expect(options.audioEnabled)
    }

    @Test("The live activity switch stays independent of the whole prerequisite chain")
    func liveActivityStaysIndependent() {
        var options = BackgroundExecutionOptions()
        options.setTaskLiveActivityEnabled(true)
        #expect(options.taskLiveActivityEnabled)
        #expect(!options.audioEnabled)
        // Chain mutations never touch it, and it never touches the chain.
        #expect(options.setScreenFeedbackEnabled(true))
        #expect(options.taskLiveActivityEnabled)
        #expect(options.setScreenFeedbackEnabled(false))
        #expect(options.setPictureInPictureEnabled(false))
        #expect(options.setAudioEnabled(false))
        #expect(options.setEnhancedBackgroundEnabled(false))
        #expect(options.taskLiveActivityEnabled)
        options.setTaskLiveActivityEnabled(false)
        #expect(!options.taskLiveActivityEnabled)
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
        #expect(!restored.audioEnabled)
    }
}
