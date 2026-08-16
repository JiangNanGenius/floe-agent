// FloeCore — Streaming text display animator.
//
// Receives a monotonically growing target text (the provider snapshot) and
// advances a displayed prefix one Unicode grapheme cluster at a time, so a
// large network chunk still appears as a continuous stream instead of one
// abrupt paragraph. Chinese characters, emoji and composed sequences are
// never split. A network-terminal condition is NOT a display-terminal
// condition: callers must wait for `drain()` before promoting the live
// tail to a persisted final message.
//
// Diagnostics are structured and redacted: the animator never logs the
// transcript itself, only counts and flags.

import Foundation

/// Structured diagnostics sink for the animator. The UI layer forwards
/// these into FloeLogger; tests capture them directly.
public protocol StreamingTextAnimatorDiagnostics: Sendable {
    /// A new, longer target was accepted.
    func streamTargetAdvanced(pendingCharacters: Int)
    /// A target that is not a prefix of the displayed text was rejected
    /// and safely rebuilt. This indicates an upstream ordering bug.
    func streamNonPrefixDetected()
    /// The caller asked the animator to finish (network terminal reached).
    func streamDrainStarted(pendingCharacters: Int)
    /// The animator displayed every pending character.
    func streamDrainCompleted()
}

/// MainActor display coordinator for streamed assistant text.
///
/// Rules of record:
/// - `update(target:)` only accepts targets that extend the current target
///   (the provider snapshot is append-only). Non-prefix targets trigger
///   `streamNonPrefixDetected` and a safe rebuild from the new target.
/// - Exactly one animation task exists at any time; rapid updates never
///   stack competing loops.
/// - The nominal cadence is one grapheme cluster around 30 fps. A large
///   backlog adaptively widens to 2–6 clusters per tick, but never dumps
///   the whole remainder in one assignment.
/// - `cancel()` stops the animation immediately and keeps the partially
///   displayed prefix — it never jumps to the full target.
@MainActor
public final class StreamingTextAnimator {

    /// The currently visible prefix of the target text.
    public private(set) var displayedText: String = "" {
        didSet {
            guard displayedText != oldValue else { return }
            onDisplayedTextChange?(displayedText)
        }
    }
    /// The most recent accepted target (the full provider text so far).
    public private(set) var targetText: String = ""

    /// Main-actor display callback used by presentation layers that cannot
    /// observe this cross-platform core type directly. Keeping the callback
    /// here avoids a Combine dependency in FloeCore while still making each
    /// animation tick invalidate SwiftUI.
    public var onDisplayedTextChange: (@MainActor (String) -> Void)?

    private let diagnostics: (any StreamingTextAnimatorDiagnostics)?
    /// Nominal presentation interval; clamped to a UI-friendly 24–40 ms.
    private let baseIntervalNanoseconds: UInt64
    private var animationTask: Task<Void, Never>?
    /// Latched while a drain is in progress; after the target stops
    /// growing the drain waits for the display to catch up.
    private var drainRequested = false

    public init(
        diagnostics: (any StreamingTextAnimatorDiagnostics)? = nil,
        baseIntervalNanoseconds: UInt64 = 33_000_000
    ) {
        self.diagnostics = diagnostics
        self.baseIntervalNanoseconds = min(40_000_000, max(24_000_000, baseIntervalNanoseconds))
    }

    deinit {
        animationTask?.cancel()
    }

    /// True when every accepted character is on screen.
    public var isSettled: Bool { displayedText == targetText }

    /// Number of grapheme clusters accepted but not yet displayed.
    public var pendingCount: Int {
        guard targetText.hasPrefix(displayedText) else { return 0 }
        return targetText.dropFirst(displayedText.count).count
    }

    /// Advances the target. `target` must contain the previous target as a
    /// prefix; otherwise the update is logged and the display safely
    /// restarts from the new target without interleaving characters.
    public func update(target: String) {
        if target == targetText { return }
        guard target.hasPrefix(targetText), target.hasPrefix(displayedText) else {
            diagnostics?.streamNonPrefixDetected()
            // Safe rebuild: drop the animation, reset to the new target's
            // first screenful, and stream forward from there. Characters
            // never appear out of order and nothing is duplicated.
            animationTask?.cancel()
            animationTask = nil
            targetText = target
            displayedText = Self.initialScreenful(of: target)
            guard displayedText != targetText else { return }
            startAnimationIfNeeded()
            return
        }
        targetText = target
        diagnostics?.streamTargetAdvanced(pendingCharacters: pendingCount)
        startAnimationIfNeeded()
    }

    /// Signals that the network stream is finished and asks the animator
    /// to display everything that remains. Awaits completion.
    public func drain(maximumDuration: Duration? = nil) async {
        guard !isSettled else { return }
        drainRequested = true
        diagnostics?.streamDrainStarted(pendingCharacters: pendingCount)
        startAnimationIfNeeded()
        let clock = ContinuousClock()
        let deadline = maximumDuration.map { clock.now.advanced(by: $0) }
        while !isSettled {
            if Task.isCancelled { return }
            if let deadline, clock.now >= deadline {
                animationTask?.cancel()
                animationTask = nil
                displayedText = targetText
                break
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        drainRequested = false
        diagnostics?.streamDrainCompleted()
    }

    /// Stops the animation immediately. The displayed prefix is kept; the
    /// animator never jumps to the full target on cancellation.
    public func cancel() {
        drainRequested = false
        animationTask?.cancel()
        animationTask = nil
    }

    /// Resets both target and display (a new run begins).
    public func reset() {
        cancel()
        targetText = ""
        displayedText = ""
    }

    // MARK: - Animation loop

    private func startAnimationIfNeeded() {
        guard animationTask == nil, !isSettled else { return }
        animationTask = Task { [weak self] in
            guard let self else { return }
            await self.runLoop()
        }
    }

    private func runLoop() async {
        while !Task.isCancelled {
            if isSettled { break }
            let backlog = pendingCount
            let requested = drainRequested
                ? min(max(8, backlog / 10), 48)
                : Self.clustersPerTick(backlog: backlog)
            // A terminal signal may accelerate a backlog, but it must not
            // collapse a multi-character tail into one final line jump.
            let clustersThisTick = backlog > 1
                ? min(requested, backlog - 1)
                : requested
            advance(by: clustersThisTick)
            // Under backlog pressure, shorten the interval slightly (never
            // below 20 ms) so long answers still catch up promptly.
            let interval = backlog > 120
                ? max(20_000_000, baseIntervalNanoseconds - 8_000_000)
                : baseIntervalNanoseconds
            try? await Task.sleep(nanoseconds: interval)
        }
        animationTask = nil
    }

    /// Appends the next `count` grapheme clusters of the target to the
    /// display. String subscripting by Character guarantees grapheme
    /// integrity for Chinese, emoji and composed sequences.
    private func advance(by count: Int) {
        guard targetText.hasPrefix(displayedText) else { return }
        let remaining = targetText.dropFirst(displayedText.count)
        guard !remaining.isEmpty else { return }
        displayedText.append(contentsOf: remaining.prefix(count))
    }

    /// Adaptive batch size: 1 cluster at a steady trickle, up to 6 under
    /// heavy backlog. Never the whole remainder at once.
    static func clustersPerTick(backlog: Int) -> Int {
        switch backlog {
        case ..<1: return 0
        case 1..<24: return 1
        case 24..<96: return 2
        case 96..<480: return 4
        default: return 6
        }
    }

    /// After a non-prefix rebuild, show at most the first line's worth of
    /// the new target and stream the rest, so a rebuilt answer does not
    /// pop in as a full paragraph either.
    private static func initialScreenful(of target: String) -> String {
        let cap = 24
        guard target.count > cap else { return target }
        return String(target.prefix(cap))
    }
}
