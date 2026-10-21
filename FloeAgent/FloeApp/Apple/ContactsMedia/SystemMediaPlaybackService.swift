// FloeApp — task-owned application media playback.
//
// SPDX-License-Identifier: MPL-2.0
//
// Ownership is explicit and in-memory: a play call records the originating
// ToolContext task identity and a generation. Another task cannot pause,
// skip, stop or replace that queue unless it requests an explicit replace and
// the tool authorizes that replace through its own runtime authority. A
// process relaunch starts with no owner and never auto-plays; a playback
// state read is reported as untracked rather than claimed.
//
// Starting a queue is not proof that audio is audible. The service performs
// only a bounded state probe and returns playing / accepted-not-yet-playing /
// interrupted / failed as distinct outcomes. An interruption is never
// auto-resumed. Cancelling a new play stops only that generation's own queue;
// cancellation of a control reports whether the effect was already applied.

#if canImport(UIKit) && canImport(MediaPlayer)
import Foundation
import FloeTools

actor SystemMediaPlaybackService {
    private struct ActivePlayback {
        var owner: PersonalToolOwnerID
        var runID: UUID
        var toolCallID: String?
        var toolIdempotencyKey: String
        var queueIDs: [String]
        var startedAt: Date
        var generation: UInt64
    }

    private let library: any SystemMediaLibraryProviding
    private let player: any SystemMediaPlayerBackend
    private let audioCoordination: SystemMediaAudioCoordination
    private let probeAttempts: Int
    private let probeIntervalNanoseconds: UInt64

    private var active: ActivePlayback?
    private var generation: UInt64 = 0
    /// One play/control mutation at a time. Actor reentrancy at the player
    /// awaits could otherwise let a second play set its queue after the first
    /// and then observe a generation mismatch, leaving the player on the older
    /// request's queue while the service claims the newer owner. A concurrent
    /// mutation is refused as superseded instead.
    private var operationInProgress = false

    init(
        library: any SystemMediaLibraryProviding,
        player: any SystemMediaPlayerBackend,
        audioCoordination: SystemMediaAudioCoordination = .shared,
        probeAttempts: Int = 6,
        probeIntervalNanoseconds: UInt64 = 250_000_000
    ) {
        self.library = library
        self.player = player
        self.audioCoordination = audioCoordination
        self.probeAttempts = max(1, probeAttempts)
        self.probeIntervalNanoseconds = probeIntervalNanoseconds
    }

    var authorization: SystemMediaAccess {
        library.authorization
    }

    var isAvailable: Bool {
        library.isAvailable
    }

    func requestAuthorization(cancellation: CancellationToken) async throws -> SystemMediaAccess {
        try await library.requestAuthorization(cancellation: cancellation)
    }

    func search(
        query: String,
        field: SystemMediaSearchField,
        maxRows: Int,
        cancellation: CancellationToken
    ) async throws -> SystemMediaSearchScan {
        _ = try await ensureAuthorization(requestIfNeeded: true, cancellation: cancellation)
        if cancellation.isCancelled { throw SystemMediaError.cancelled }
        let scan = try await library.search(
            query: query,
            field: field,
            maxRows: maxRows,
            cancellation: cancellation
        )
        if cancellation.isCancelled { throw SystemMediaError.cancelled }
        return scan
    }

    func hasAnyItems() async -> Bool {
        await library.hasAnyItems()
    }

    // MARK: - Play

    func play(
        persistentIDs: [UInt64],
        caller: SystemMediaCaller,
        replaceRequested: Bool,
        authorizeReplace: @escaping @Sendable () async -> Bool,
        cancellation: CancellationToken
    ) async -> SystemMediaPlaybackOutcome {
        guard !caller.temporary else { return .unavailable }
        if cancellation.isCancelled { return .cancelled(effectApplied: false) }
        guard !persistentIDs.isEmpty else { return .emptyQueue }
        guard !operationInProgress else { return .superseded }
        operationInProgress = true
        defer { operationInProgress = false }

        do {
            _ = try await ensureAuthorization(
                requestIfNeeded: true,
                cancellation: cancellation
            )
        } catch let error as SystemMediaError {
            return await authorizationOutcome(error, caller: caller)
        } catch {
            return .failed(code: "authorization")
        }
        if cancellation.isCancelled { return .cancelled(effectApplied: false) }

        if let reason = await audioCoordination.busyReason() {
            return .audioBusy(reason: reason)
        }

        if let active, !active.owner.matches(caller.owner) {
            guard replaceRequested else { return .busy }
            guard await authorizeReplace() else { return .replaceNotAuthorized }
            if cancellation.isCancelled { return .cancelled(effectApplied: false) }
        }

        let items: [SystemMediaItem]
        do {
            items = try await library.lookup(
                persistentIDs: persistentIDs,
                cancellation: cancellation
            )
        } catch let error as SystemMediaError {
            return await authorizationOutcome(error, caller: caller)
        } catch {
            return .failed(code: "lookup")
        }
        guard items.count == persistentIDs.count else {
            return .itemsUnavailable(missing: max(0, persistentIDs.count - items.count))
        }
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.persistentID, $0) })
        let orderedIDs = persistentIDs.compactMap { byID[String($0)]?.persistentID }
        guard orderedIDs.count == persistentIDs.count else {
            return .itemsUnavailable(missing: max(0, persistentIDs.count - orderedIDs.count))
        }

        generation &+= 1
        let thisGeneration = generation
        do {
            try await player.setQueue(persistentIDs: persistentIDs)
        } catch let error as SystemMediaError {
            return Self.outcome(error)
        } catch {
            return .failed(code: "queue")
        }

        // The previous queue is no longer valid once setQueue succeeds. A
        // failed prepare therefore leaves no claimed owner rather than
        // reporting the old task as still owning the replaced queue.
        active = nil
        do {
            _ = try await ContactsMediaRequestRunner.run(
                cancellation: cancellation,
                timeout: 20
            ) {
                try await player.prepareToPlay()
            }
        } catch ContactsMediaRequestError.cancelled {
            await player.stop()
            return .cancelled(effectApplied: false)
        } catch ContactsMediaRequestError.timedOut {
            await player.stop()
            return .timedOut
        } catch let error as SystemMediaError {
            return Self.outcome(error)
        } catch {
            return .failed(code: "prepare")
        }

        if cancellation.isCancelled {
            await player.stop()
            if active?.generation == thisGeneration { active = nil }
            return .cancelled(effectApplied: false)
        }
        // A newer play may have completed while this one awaited prepare.
        // It owns the current queue; never overwrite its ownership or claim
        // this older generation's state.
        guard generation == thisGeneration else { return .superseded }

        active = ActivePlayback(
            owner: caller.owner,
            runID: caller.runID,
            toolCallID: caller.toolCallID,
            toolIdempotencyKey: caller.toolIdempotencyKey,
            queueIDs: orderedIDs,
            startedAt: Date(),
            generation: thisGeneration
        )
        await player.play()
        return await probe(
            generation: thisGeneration,
            caller: caller,
            cancellation: cancellation,
            pausedIsSuccess: false,
            stopOwnPlaybackOnCancellation: true
        )
    }

    // MARK: - Transport

    func control(
        _ action: SystemMediaControlAction,
        caller: SystemMediaCaller,
        cancellation: CancellationToken
    ) async -> SystemMediaPlaybackOutcome {
        guard !caller.temporary else { return .unavailable }
        if cancellation.isCancelled { return .cancelled(effectApplied: false) }
        do {
            _ = try await ensureAuthorization(
                requestIfNeeded: false,
                cancellation: cancellation
            )
        } catch let error as SystemMediaError {
            return await authorizationOutcome(error, caller: caller)
        } catch {
            return .failed(code: "authorization")
        }
        guard !operationInProgress else { return .superseded }
        operationInProgress = true
        defer { operationInProgress = false }
        guard let current = active else { return .noActivePlayback }
        guard current.owner.matches(caller.owner) else { return .notOwner }
        let thisGeneration = current.generation

        if action == .play || action == .toggle {
            if let reason = await audioCoordination.busyReason() {
                return .audioBusy(reason: reason)
            }
        }

        switch action {
        case .stop:
            await player.stop()
            if active?.generation == thisGeneration { active = nil }
            return .stopped
        case .pause:
            await player.pause()
        case .play:
            await player.play()
        case .toggle:
            let snapshot = await player.snapshot()
            if snapshot.state == .playing {
                await player.pause()
            } else {
                await player.play()
            }
        case .next:
            await player.skipToNext()
        case .previous:
            await player.skipToPrevious()
        }

        if cancellation.isCancelled {
            return .cancelled(effectApplied: true)
        }
        return await probe(
            generation: thisGeneration,
            caller: caller,
            cancellation: cancellation,
            pausedIsSuccess: action == .pause || action == .toggle,
            stopOwnPlaybackOnCancellation: false
        )
    }

    // MARK: - Readback

    func nowPlaying(
        caller: SystemMediaCaller,
        cancellation: CancellationToken
    ) async -> SystemMediaPlaybackOutcome {
        guard !caller.temporary else { return .unavailable }
        if cancellation.isCancelled { return .cancelled(effectApplied: false) }
        do {
            _ = try await ensureAuthorization(
                requestIfNeeded: false,
                cancellation: cancellation
            )
        } catch let error as SystemMediaError {
            return await authorizationOutcome(error, caller: caller)
        } catch {
            return .failed(code: "authorization")
        }

        guard let current = active else {
            let snapshot = await player.snapshot()
            if snapshot.state == .stopped, snapshot.nowPlayingID == nil {
                return .idle
            }
            return .untracked(state: snapshot.state)
        }
        guard current.owner.matches(caller.owner) else { return .notOwner }

        let snapshot = await player.snapshot()
        let nowPlaying = makeNowPlaying(active: current, snapshot: snapshot)
        switch snapshot.state {
        case .playing: return .playing(nowPlaying)
        case .paused: return .paused(nowPlaying)
        case .interrupted: return .interrupted(nowPlaying)
        case .stopped: return .stopped
        case .seeking: return .state(nowPlaying)
        }
    }

    // MARK: - Authorization

    private func ensureAuthorization(
        requestIfNeeded: Bool,
        cancellation: CancellationToken
    ) async throws -> SystemMediaAccess {
        var status = library.authorization
        if status == .notDetermined, requestIfNeeded {
            status = try await library.requestAuthorization(cancellation: cancellation)
        }
        switch status {
        case .authorized:
            return status
        case .notDetermined:
            throw SystemMediaError.authorizationRequired
        case .denied:
            throw SystemMediaError.authorizationDenied
        case .restricted:
            throw SystemMediaError.authorizationRestricted
        case .unavailable:
            throw SystemMediaError.unavailable
        }
    }

    private func authorizationOutcome(
        _ error: SystemMediaError,
        caller: SystemMediaCaller
    ) async -> SystemMediaPlaybackOutcome {
        switch error {
        case .authorizationDenied, .authorizationRestricted, .authorizationChanged:
            if let current = active, current.owner.matches(caller.owner) {
                await player.stop()
                active = nil
            }
        default:
            break
        }
        return Self.outcome(error)
    }

    // MARK: - Bounded observation

    private func probe(
        generation: UInt64,
        caller: SystemMediaCaller,
        cancellation: CancellationToken,
        pausedIsSuccess: Bool,
        stopOwnPlaybackOnCancellation: Bool
    ) async -> SystemMediaPlaybackOutcome {
        for attempt in 0..<probeAttempts {
            if cancellation.isCancelled {
                if stopOwnPlaybackOnCancellation,
                   let current = active,
                   current.generation == generation,
                   current.owner.matches(caller.owner) {
                    await player.stop()
                    active = nil
                    return .cancelled(effectApplied: false)
                }
                return .cancelled(effectApplied: true)
            }
            guard let current = active, current.generation == generation else {
                return .superseded
            }
            let snapshot = await player.snapshot()
            let nowPlaying = makeNowPlaying(active: current, snapshot: snapshot)
            switch snapshot.state {
            case .playing:
                return .playing(nowPlaying)
            case .interrupted:
                return .interrupted(nowPlaying)
            case .paused where pausedIsSuccess:
                return .paused(nowPlaying)
            case .stopped:
                return .stopped
            case .paused, .seeking:
                break
            }
            if attempt < probeAttempts - 1, probeIntervalNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: probeIntervalNanoseconds)
            }
        }
        guard let current = active,
              current.generation == generation,
              current.owner.matches(caller.owner) else {
            return .superseded
        }
        let snapshot = await player.snapshot()
        let nowPlaying = makeNowPlaying(active: current, snapshot: snapshot)
        if snapshot.state == .interrupted { return .interrupted(nowPlaying) }
        if snapshot.state == .stopped { return .stopped }
        if snapshot.state == .playing { return .playing(nowPlaying) }
        if snapshot.state == .paused, pausedIsSuccess { return .paused(nowPlaying) }
        return .acceptedNotYetPlaying(nowPlaying)
    }

    private func makeNowPlaying(
        active: ActivePlayback,
        snapshot: SystemMediaPlayerSnapshot
    ) -> SystemMediaNowPlaying {
        let index: Int?
        if let rawIndex = snapshot.index,
           rawIndex >= 0,
           rawIndex < active.queueIDs.count {
            index = rawIndex
        } else {
            index = nil
        }
        return SystemMediaNowPlaying(
            persistentID: snapshot.nowPlayingID ?? active.queueIDs.first,
            title: snapshot.title,
            artist: snapshot.artist,
            album: snapshot.album,
            state: snapshot.state,
            queueIDs: active.queueIDs,
            queueIndex: index,
            currentTime: snapshot.currentTime
        )
    }

    private static func outcome(_ error: SystemMediaError) -> SystemMediaPlaybackOutcome {
        switch error {
        case .unavailable: .unavailable
        case .authorizationRequired: .authorizationRequired
        case .authorizationDenied: .authorizationDenied
        case .authorizationRestricted: .authorizationRestricted
        case .authorizationChanged: .failed(code: "authorizationChanged")
        case .foregroundRequired: .failed(code: "foregroundRequired")
        case .cancelled: .cancelled(effectApplied: false)
        case .timedOut: .timedOut
        case .invalidQuery, .invalidID: .failed(code: error.status)
        case .queryFailed: .failed(code: "queryFailed")
        case .queueUnavailable: .failed(code: "queueUnavailable")
        case .prepareFailed: .failed(code: "prepareFailed")
        }
    }
}
#endif
