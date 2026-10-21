// FloeApp — real MediaPlayer service seam for the local library and app queue.
//
// SPDX-License-Identifier: MPL-2.0
//
// Only public, current MediaPlayer APIs are used:
//   * MPMediaLibrary authorization + MPMediaQuery for on-device items;
//   * MPMediaPropertyPredicate for exact persistent IDs and bounded text
//     search;
//   * MPMusicPlayerController.applicationQueuePlayer for application-scoped
//     playback. The header explicitly says this player does not affect the
//     Music app's state; systemMusicPlayer is deliberately absent.
//
// No store IDs, cloud catalog, subscription, account or library mutation API
// appears in this file.

#if canImport(UIKit) && canImport(MediaPlayer)
import Foundation
@preconcurrency import MediaPlayer
import FloeTools

/// Queries only items stored on this device. A cloud-only library entry
/// must not silently turn a local-library request into account streaming.
private func localDeviceMediaQuery() -> MPMediaQuery {
    MPMediaQuery(filterPredicates: [
        MPMediaPropertyPredicate(value: false, forProperty: MPMediaItemPropertyIsCloudItem)
    ])
}

final class SystemMediaLibrary: SystemMediaLibraryProviding, @unchecked Sendable {
    var isAvailable: Bool { true }

    var authorization: SystemMediaAccess {
        Self.map(MPMediaLibrary.authorizationStatus())
    }

    func requestAuthorization(cancellation: CancellationToken) async throws -> SystemMediaAccess {
        do {
            _ = try await ContactsMediaRequestRunner.run(
                cancellation: cancellation,
                timeout: 120
            ) {
                _ = await MPMediaLibrary.requestAuthorization()
            }
        } catch ContactsMediaRequestError.cancelled {
            throw SystemMediaError.cancelled
        } catch ContactsMediaRequestError.timedOut {
            throw SystemMediaError.timedOut
        } catch {
            throw SystemMediaError.authorizationRequired
        }
        let status = authorization
        if status == .notDetermined {
            throw SystemMediaError.authorizationRequired
        }
        return status
    }

    func search(
        query: String,
        field: SystemMediaSearchField,
        maxRows: Int,
        cancellation: CancellationToken
    ) async throws -> SystemMediaSearchScan {
        guard isAvailable else { throw SystemMediaError.unavailable }
        let status = authorization
        guard status == .authorized else { throw Self.authorizationError(status) }
        let limit = min(max(1, maxRows), 200)
        let properties: [String]
        switch field {
        case .any:
            properties = [
                MPMediaItemPropertyTitle,
                MPMediaItemPropertyArtist,
                MPMediaItemPropertyAlbumTitle
            ]
        case .title:
            properties = [MPMediaItemPropertyTitle]
        case .artist:
            properties = [MPMediaItemPropertyArtist]
        case .album:
            properties = [MPMediaItemPropertyAlbumTitle]
        }

        var merged: [String: SystemMediaItem] = [:]
        var rawCount = 0
        var truncated = false
        for property in properties {
            if cancellation.isCancelled { throw SystemMediaError.cancelled }
            let mediaQuery = localDeviceMediaQuery()
            mediaQuery.addFilterPredicate(MPMediaPropertyPredicate(
                value: query,
                forProperty: property,
                comparisonType: .contains
            ))
            guard let items = mediaQuery.items else {
                throw SystemMediaError.queryFailed(code: 0)
            }
            rawCount += items.count
            if items.count > limit { truncated = true }
            for item in items.prefix(limit) {
                let mapped = Self.map(item)
                merged[mapped.persistentID] = mapped
            }
        }
        if cancellation.isCancelled { throw SystemMediaError.cancelled }
        var ordered = merged.values.sorted(by: Self.stableOrder)
        if ordered.count > limit {
            ordered = Array(ordered.prefix(limit))
            truncated = true
        }
        if authorization != status { throw SystemMediaError.authorizationChanged }
        return SystemMediaSearchScan(
            items: ordered,
            rawCount: rawCount,
            truncated: truncated,
            authorization: status
        )
    }

    func lookup(
        persistentIDs: [UInt64],
        cancellation: CancellationToken
    ) async throws -> [SystemMediaItem] {
        guard isAvailable else { throw SystemMediaError.unavailable }
        let status = authorization
        guard status == .authorized else { throw Self.authorizationError(status) }
        var result: [SystemMediaItem] = []
        for persistentID in persistentIDs {
            if cancellation.isCancelled { throw SystemMediaError.cancelled }
            let mediaQuery = localDeviceMediaQuery()
            mediaQuery.addFilterPredicate(MPMediaPropertyPredicate(
                value: NSNumber(value: persistentID),
                forProperty: MPMediaItemPropertyPersistentID
            ))
            guard let item = mediaQuery.items?.first else { continue }
            result.append(Self.map(item))
        }
        return result
    }

    func hasAnyItems() async -> Bool {
        guard authorization == .authorized else { return false }
        let items = localDeviceMediaQuery().items ?? []
        return !items.isEmpty
    }

    private static func map(_ status: MPMediaLibraryAuthorizationStatus) -> SystemMediaAccess {
        switch status {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        case .authorized: .authorized
        @unknown default: .unavailable
        }
    }

    private static func authorizationError(_ status: SystemMediaAccess) -> SystemMediaError {
        switch status {
        case .notDetermined: .authorizationRequired
        case .denied: .authorizationDenied
        case .restricted: .authorizationRestricted
        case .authorized, .unavailable: .unavailable
        }
    }

    private static func map(_ item: MPMediaItem) -> SystemMediaItem {
        let duration = item.playbackDuration
        return SystemMediaItem(
            persistentID: String(item.persistentID),
            title: ContactsMediaText.bounded(item.title ?? "", limit: 160),
            artist: ContactsMediaText.bounded(item.artist ?? "", limit: 160),
            album: ContactsMediaText.bounded(item.albumTitle ?? "", limit: 160),
            durationSeconds: duration.isFinite && duration >= 0 ? Int(duration.rounded()) : nil,
            mediaType: item.mediaType.rawValue
        )
    }

    private static func stableOrder(_ lhs: SystemMediaItem, _ rhs: SystemMediaItem) -> Bool {
        let left = lhs.title.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let right = rhs.title.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        if left != right { return left < right }
        let leftArtist = lhs.artist.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let rightArtist = rhs.artist.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        if leftArtist != rightArtist { return leftArtist < rightArtist }
        return lhs.persistentID < rhs.persistentID
    }
}

@MainActor
final class ApplicationQueueMediaPlayer: SystemMediaPlayerBackend {
    private let player = MPMusicPlayerController.applicationQueuePlayer

    func setQueue(persistentIDs: [UInt64]) throws {
        var items: [MPMediaItem] = []
        for persistentID in persistentIDs {
            let query = localDeviceMediaQuery()
            query.addFilterPredicate(MPMediaPropertyPredicate(
                value: NSNumber(value: persistentID),
                forProperty: MPMediaItemPropertyPersistentID
            ))
            guard let item = query.items?.first else {
                throw SystemMediaError.queueUnavailable
            }
            items.append(item)
        }
        guard items.count == persistentIDs.count else {
            throw SystemMediaError.queueUnavailable
        }
        player.setQueue(with: MPMediaItemCollection(items: items))
    }

    func prepareToPlay() async throws {
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                player.prepareToPlay { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        } catch {
            throw SystemMediaError.prepareFailed(code: (error as NSError).code)
        }
    }

    func play() {
        player.play()
    }

    func pause() {
        player.pause()
    }

    func stop() {
        player.stop()
    }

    func skipToNext() {
        player.skipToNextItem()
    }

    func skipToPrevious() {
        player.skipToPreviousItem()
    }

    func snapshot() -> SystemMediaPlayerSnapshot {
        let state: SystemMediaPlaybackState
        switch player.playbackState {
        case .stopped: state = .stopped
        case .playing: state = .playing
        case .paused: state = .paused
        case .interrupted: state = .interrupted
        case .seekingForward, .seekingBackward: state = .seeking
        @unknown default: state = .stopped
        }
        let item = player.nowPlayingItem
        let rawIndex = player.indexOfNowPlayingItem
        return SystemMediaPlayerSnapshot(
            state: state,
            nowPlayingID: item.map { String($0.persistentID) },
            title: item.flatMap { $0.title }.map { ContactsMediaText.bounded($0, limit: 160) },
            artist: item.flatMap { $0.artist }.map { ContactsMediaText.bounded($0, limit: 160) },
            album: item.flatMap { $0.albumTitle }.map { ContactsMediaText.bounded($0, limit: 160) },
            index: rawIndex == NSNotFound ? nil : rawIndex,
            currentTime: player.currentPlaybackTime
        )
    }
}
#endif
