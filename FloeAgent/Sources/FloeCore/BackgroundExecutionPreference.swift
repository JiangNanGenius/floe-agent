// FloeCore — Background execution preference for agent runs.
//
// iOS cannot keep a long-running network stream alive indefinitely. This
// enum preserves legacy persisted choices. New settings use independent
// BackgroundExecutionOptions; the enum is only a compatibility projection.

import Foundation

public enum BackgroundExecutionPreference: String, Sendable, Codable, CaseIterable, Hashable {
    /// The 30s completion lease plus an iOS 26 continued-processing task
    /// (progress on the Dynamic Island, checkpoint + resume). No extra UI.
    case standard
    /// An inline Picture-in-Picture source that displays run progress. AVKit
    /// enters the system PiP surface when the user leaves the app.
    case pictureInPicture
    /// Screen sharing with an on-screen operation guide; the Broadcast
    /// Upload Extension stays alive while the user is broadcasting.
    case screenShare
}

/// Enabled background capabilities in the user-approved prerequisite chain
/// (latest plan, 2026-10-27 — it OVERRIDES the older "three fully
/// independent toggles" cascade-off model):
///
///   enhanced background → standalone task audio → Picture-in-Picture → screen feedback
///
/// The chain is central policy (these setters enforce it; Settings and any
/// future surface only reflect it):
///  • Enabling a capability enables every prerequisite above it — screen
///    feedback pulls in PiP, audio and enhanced processing; the PiP surface
///    rides the audio-session promise; audio rides enhanced processing.
///  • A prerequisite CANNOT be disabled while a dependent is still enabled:
///    the setter refuses (no-op, returns `false`) instead of silently
///    cascading the user's other choices off. The UI presents the refusal
///    as a disabled/actionable row listing exactly what must be turned off
///    first (`activeDependentsBlockingDisable`).
///  • Migration never rewrites a stored explicit choice: objects persisted
///    before the audio capability derive `audioEnabled` from the visual
///    choices that always implied it, and a stored
///    `enhancedBackgroundEnabled: false` survives decode untouched (no
///    upgrade silently gains continued processing, gains volume, or starts
///    audio playing — playback always requires a real running task).
///
/// The Lock Screen / Dynamic Island activity stays OUTSIDE the chain:
/// implied by nothing, changing nothing. The legacy enum remains readable
/// for existing settings and callers.
public struct BackgroundExecutionOptions: Sendable, Codable, Equatable, Hashable {
    public var enhancedBackgroundEnabled: Bool
    /// Standalone task audio (the service-owned ambient loop and stage
    /// speech run as the task's session, not as a PiP view accessory). Off
    /// by default: upgrading never auto-plays audio.
    public var audioEnabled: Bool
    public var pictureInPictureEnabled: Bool
    public var screenFeedbackEnabled: Bool
    /// Independent Lock Screen / Dynamic Island presentation of tasks that are
    /// actually running. Off unless the user turns it on: it is never implied
    /// by another capability and never changes one.
    public var taskLiveActivityEnabled: Bool

    /// Raw construction for policy callers and tests. Repairs only the
    /// audio/visual foundation upward (a visual surface never exists
    /// without the audio session promise it rides on); the enhanced flag is
    /// taken verbatim so stored legacy combinations stay inspectable. User
    /// mutations go through the setters, which enforce the FULL chain.
    public init(
        enhancedBackgroundEnabled: Bool = true,
        audioEnabled: Bool = false,
        pictureInPictureEnabled: Bool = false,
        screenFeedbackEnabled: Bool = false,
        taskLiveActivityEnabled: Bool = false
    ) {
        self.enhancedBackgroundEnabled = enhancedBackgroundEnabled
        // A visual surface without its audio foundation is an inconsistent
        // value even at construction: repair up the visual chain only.
        self.audioEnabled = audioEnabled || pictureInPictureEnabled || screenFeedbackEnabled
        self.pictureInPictureEnabled = pictureInPictureEnabled || screenFeedbackEnabled
        self.screenFeedbackEnabled = screenFeedbackEnabled
        self.taskLiveActivityEnabled = taskLiveActivityEnabled
    }

    public init(legacy: BackgroundExecutionPreference) {
        self.init(
            pictureInPictureEnabled: legacy != .standard,
            screenFeedbackEnabled: legacy == .screenShare
        )
    }

    private enum CodingKeys: String, CodingKey {
        case enhancedBackgroundEnabled
        case audioEnabled
        case pictureInPictureEnabled
        case screenFeedbackEnabled
        case taskLiveActivityEnabled
    }

    /// Decoding migration: an object stored before a key existed keeps every
    /// choice it does contain and takes the shipping default for the missing
    /// one. A required-key decode would fail the whole object, silently
    /// discarding the user's other background choices. A stored object from
    /// before the audio capability derives `audioEnabled` from the visual
    /// choices that always implied it, so existing surfaces keep working;
    /// this only records the capability — playback still requires a real
    /// running task, and the upgrade itself never starts audio.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enhancedBackgroundEnabled = try container.decodeIfPresent(
            Bool.self, forKey: .enhancedBackgroundEnabled
        ) ?? true
        pictureInPictureEnabled = try container.decodeIfPresent(
            Bool.self, forKey: .pictureInPictureEnabled
        ) ?? false
        screenFeedbackEnabled = try container.decodeIfPresent(
            Bool.self, forKey: .screenFeedbackEnabled
        ) ?? false
        audioEnabled = try container.decodeIfPresent(
            Bool.self, forKey: .audioEnabled
        ) ?? (pictureInPictureEnabled || screenFeedbackEnabled)
        taskLiveActivityEnabled = try container.decodeIfPresent(
            Bool.self, forKey: .taskLiveActivityEnabled
        ) ?? false
    }

    /// Apply after decoding or direct property updates before persistence/use.
    /// Enforces the audio→PiP→feedback foundation chain upward (a surface
    /// never survives without its audio prerequisite, and a stored PiP
    /// choice never loses its audio basis). The enhanced flag is never
    /// repaired here: a stored `enhancedBackgroundEnabled: false` survives
    /// migration unchanged, so no upgrade silently grants continued
    /// processing — the full chain applies to the user's NEXT action
    /// through the setters.
    public var normalized: Self {
        Self(
            enhancedBackgroundEnabled: enhancedBackgroundEnabled,
            audioEnabled: audioEnabled,
            pictureInPictureEnabled: pictureInPictureEnabled,
            screenFeedbackEnabled: screenFeedbackEnabled,
            taskLiveActivityEnabled: taskLiveActivityEnabled
        )
    }

    /// Independent switch: no other capability is enabled, disabled or
    /// downgraded by this choice.
    public mutating func setTaskLiveActivityEnabled(_ enabled: Bool) {
        taskLiveActivityEnabled = enabled
    }

    /// Enhanced background processing is the ROOT of the prerequisite chain.
    /// Enabling it grants nothing else by itself. Disabling it is REFUSED
    /// (no-op, returns `false`) while audio, PiP or screen feedback is still
    /// enabled — the user must turn the dependents off first; nothing is
    /// silently cascaded off and no running task is ever killed by a toggle.
    @discardableResult
    public mutating func setEnhancedBackgroundEnabled(_ enabled: Bool) -> Bool {
        guard enabled || activeDependentsBlockingDisable(of: .enhancedBackground).isEmpty else {
            return false
        }
        enhancedBackgroundEnabled = enabled
        return true
    }

    /// Standalone task audio. Enabling it enables its prerequisite (enhanced
    /// processing). Disabling is REFUSED while PiP or screen feedback still
    /// rides on it. Selection alone never plays sound and never changes any
    /// volume: playback belongs to a real running task (or an explicit
    /// preview action).
    @discardableResult
    public mutating func setAudioEnabled(_ enabled: Bool) -> Bool {
        if enabled {
            audioEnabled = true
            enhancedBackgroundEnabled = true
            return true
        }
        guard activeDependentsBlockingDisable(of: .audio).isEmpty else { return false }
        audioEnabled = false
        return true
    }

    /// The PiP surface. Enabling pulls in audio and enhanced processing;
    /// disabling is REFUSED while screen feedback still presents inside it.
    @discardableResult
    public mutating func setPictureInPictureEnabled(_ enabled: Bool) -> Bool {
        if enabled {
            pictureInPictureEnabled = true
            audioEnabled = true
            enhancedBackgroundEnabled = true
            return true
        }
        guard activeDependentsBlockingDisable(of: .pictureInPicture).isEmpty else { return false }
        pictureInPictureEnabled = false
        return true
    }

    /// Screen feedback presents inside PiP, so enabling it pulls in the
    /// whole prerequisite chain (PiP, audio, enhanced processing). It has
    /// no dependents, so disabling is always allowed.
    @discardableResult
    public mutating func setScreenFeedbackEnabled(_ enabled: Bool) -> Bool {
        if enabled {
            screenFeedbackEnabled = true
            pictureInPictureEnabled = true
            audioEnabled = true
            enhancedBackgroundEnabled = true
        } else {
            screenFeedbackEnabled = false
        }
        return true
    }

    /// The capabilities that currently BLOCK disabling `capability`: the
    /// enabled dependents that would lose their prerequisite. Settings uses
    /// this for the disabled/actionable row state and the "turn off X
    /// first" copy; the setters above enforce the same rule, so the policy
    /// is never UI-only. The deepest capability and the independent live
    /// activity have no dependents.
    public func activeDependentsBlockingDisable(of capability: BackgroundExecutionCapability) -> [BackgroundExecutionCapability] {
        let dependentPairs: [(BackgroundExecutionCapability, Bool)]
        switch capability {
        case .enhancedBackground:
            dependentPairs = [(.audio, audioEnabled),
                              (.pictureInPicture, pictureInPictureEnabled),
                              (.screenFeedback, screenFeedbackEnabled)]
        case .audio:
            dependentPairs = [(.pictureInPicture, pictureInPictureEnabled),
                              (.screenFeedback, screenFeedbackEnabled)]
        case .pictureInPicture:
            dependentPairs = [(.screenFeedback, screenFeedbackEnabled)]
        case .screenFeedback, .taskLiveActivity:
            dependentPairs = []
        }
        return dependentPairs.filter(\.1).map(\.0)
    }

    /// The prerequisites that enabling `capability` pulls in (empty when
    /// nothing is missing). Settings uses this for the "turning this on
    /// also turns on X" copy.
    public func prerequisitesEnabledByTurningOn(_ capability: BackgroundExecutionCapability) -> [BackgroundExecutionCapability] {
        let prerequisitePairs: [(BackgroundExecutionCapability, Bool)]
        switch capability {
        case .enhancedBackground:
            prerequisitePairs = []
        case .audio:
            prerequisitePairs = [(.enhancedBackground, enhancedBackgroundEnabled)]
        case .pictureInPicture:
            prerequisitePairs = [(.audio, audioEnabled), (.enhancedBackground, enhancedBackgroundEnabled)]
        case .screenFeedback:
            prerequisitePairs = [(.pictureInPicture, pictureInPictureEnabled),
                                 (.audio, audioEnabled),
                                 (.enhancedBackground, enhancedBackgroundEnabled)]
        case .taskLiveActivity:
            prerequisitePairs = []
        }
        return prerequisitePairs.filter { !$0.1 }.map(\.0)
    }

    /// Compatibility projection only; continued processing must consult the
    /// independent enhanced-background flag instead of this visual preference.
    public var legacyPreference: BackgroundExecutionPreference {
        if screenFeedbackEnabled { return .screenShare }
        return pictureInPictureEnabled ? .pictureInPicture : .standard
    }
}

/// The hierarchy positions plus the independent live activity surface. The
/// raw values are stable diagnostics labels, not user copy.
public enum BackgroundExecutionCapability: String, Sendable, Codable, CaseIterable, Hashable {
    case enhancedBackground
    case audio
    case pictureInPicture
    case screenFeedback
    case taskLiveActivity
}

public extension BackgroundExecutionPreference {
    /// Short user-facing label for the settings row.
    ///
    /// FloeCore is Foundation-only and cannot use the app's String Catalog, so
    /// (like the other Foundation-layer surfaces) both languages are kept
    /// together and resolved from the current locale.
    var title: String {
        switch self {
        case .standard: return BackgroundExecutionPreferenceText.t(
            "普通后台任务", "Regular background task"
        )
        case .pictureInPicture: return BackgroundExecutionPreferenceText.t(
            "系统画中画", "System Picture-in-Picture"
        )
        case .screenShare: return BackgroundExecutionPreferenceText.t(
            "屏幕共享引导", "On-screen sharing guide"
        )
        }
    }

    /// One-line explanation shown under the picker. Describes what the user
    /// experiences, not the implementation (no lease windows or checkpoints).
    var subtitle: String {
        switch self {
        case .standard: return BackgroundExecutionPreferenceText.t(
            "切到其他 App 后任务可继续运行，返回 Floe 时可恢复未完成的工作；具体时长由系统决定。",
            "The task can keep running after you leave the app and resume where it left off when you return; the system decides how long this lasts."
        )
        case .pictureInPicture: return BackgroundExecutionPreferenceText.t(
            "前台仅显示工具栏内嵌画面；离开 Floe 时自动进入系统画中画，也可手动控制。",
            "In Floe the picture stays embedded in the toolbar; leaving the app opens system Picture-in-Picture automatically, and you can control it manually."
        )
        case .screenShare: return BackgroundExecutionPreferenceText.t(
            "任务开始时打开系统共享授权；需要时可从工具栏手动显示进度画中画。",
            "Starts the system sharing permission when a task begins; you can show the progress picture from the toolbar whenever needed."
        )
        }
    }
}

/// Bilingual strings for the Foundation-only layer. Keep both languages
/// together so no user-facing text is added in one language only.
enum BackgroundExecutionPreferenceText {
    static func t(_ zh: String, _ en: String) -> String {
        FloeL10n.isChinese ? zh : en
    }
}
