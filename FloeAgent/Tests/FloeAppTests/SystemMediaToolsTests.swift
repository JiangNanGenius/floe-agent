// FloeAppTests — prepared behavior tests for the local system media tools.
//
// These use fake library and player seams. They never touch MPMediaLibrary,
// MPMusicPlayerController, the Music app, a real media library or a device,
// and they never start playback. They are registered only after the primary
// adds this file to the FloeAppTests source list and regenerates the project.

#if canImport(UIKit) && canImport(MediaPlayer)
import Foundation
import Testing
import FloeCore
import FloeTools
@testable import FloeApp

@Suite("FloeApp.SystemMediaTools")
@MainActor
struct SystemMediaToolsTests {
    private func context(
        conversation: UUID? = UUID(),
        environmentID: String? = nil,
        runID: UUID = UUID(),
        temporary: Bool = false,
        cancellation: CancellationToken = CancellationToken()
    ) -> ToolContext {
        ToolContext(
            runID: runID,
            cancellation: cancellation,
            environmentID: environmentID,
            conversationID: conversation,
            temporaryReadOnly: temporary
        )
    }

    private func caller(
        conversation: UUID,
        environmentID: String? = nil,
        runID: UUID = UUID()
    ) -> SystemMediaCaller {
        SystemMediaCaller(
            owner: PersonalToolOwnerID(
                conversationID: conversation,
                environmentID: environmentID,
                fallbackRunID: runID
            ),
            runID: runID
        )
    }

    private func makeService(
        library: FakeMediaLibrary,
        player: FakeMediaPlayer,
        audio: SystemMediaAudioCoordination = SystemMediaAudioCoordination(),
        attempts: Int = 2
    ) -> SystemMediaPlaybackService {
        SystemMediaPlaybackService(
            library: library,
            player: player,
            audioCoordination: audio,
            probeAttempts: attempts,
            probeIntervalNanoseconds: 0
        )
    }

    private func searchTool(
        _ service: SystemMediaPlaybackService,
        store: ContactsMediaSnapshotStore = ContactsMediaSnapshotStore(),
        foreground: Bool = true
    ) -> AppleMediaSearchTool {
        AppleMediaSearchTool(
            service: service,
            store: store,
            isForeground: { foreground }
        )
    }

    private func playTool(
        _ service: SystemMediaPlaybackService,
        foreground: Bool = true
    ) -> AppleMediaPlayTool {
        AppleMediaPlayTool(service: service, isForeground: { foreground })
    }

    private func controlTool(
        _ service: SystemMediaPlaybackService,
        foreground: Bool = true
    ) -> AppleMediaControlTool {
        AppleMediaControlTool(service: service, isForeground: { foreground })
    }

    private func nowPlayingTool(
        _ service: SystemMediaPlaybackService,
        foreground: Bool = true
    ) -> AppleMediaNowPlayingTool {
        AppleMediaNowPlayingTool(service: service, isForeground: { foreground })
    }

    private func field(_ name: String, in output: String) -> String? {
        guard let firstLine = output.split(separator: "\n", maxSplits: 1).first else {
            return nil
        }
        for token in firstLine.split(separator: " ") where token.hasPrefix("\(name)=") {
            return String(token.dropFirst(name.count + 1))
        }
        return nil
    }

    private func rowIDs(_ output: String) -> [String] {
        output.split(separator: "\n").dropFirst().compactMap { line in
            guard let token = line.split(separator: " ").first(where: { $0.hasPrefix("id=") }) else {
                return nil
            }
            return String(token.dropFirst(3))
        }
    }

    private func item(_ id: UInt64, title: String? = nil) -> SystemMediaItem {
        SystemMediaItem(
            persistentID: String(id),
            title: title ?? "Track \(id)",
            artist: "Artist \(id)",
            album: "Album \(id)",
            durationSeconds: 180,
            mediaType: 1
        )
    }

    // MARK: - Authorization / search

    @Test("Denied media authorization is explicit and reads nothing")
    func deniedIsExplicit() async throws {
        let library = FakeMediaLibrary()
        library.auth = .denied
        let player = FakeMediaPlayer()
        let service = makeService(library: library, player: player)
        let output = try await searchTool(service).execute(
            .init(query: "track"),
            context: context()
        )
        #expect(output.exitStatus == 77)
        #expect(output.summary.contains("status=authorizationDenied"))
        #expect(!output.summary.contains("status=ok"))
        #expect(library.searchCount == 0)
    }

    @Test("Not-determined search requests access once")
    func notDeterminedRequestsOnce() async throws {
        let library = FakeMediaLibrary()
        library.auth = .notDetermined
        library.items = [item(1)]
        let player = FakeMediaPlayer()
        let service = makeService(library: library, player: player)
        let output = try await searchTool(service).execute(
            .init(query: "Track"),
            context: context()
        )
        #expect(output.exitStatus == 0)
        #expect(library.requestCount == 1)
        #expect(output.summary.contains("authorization=authorized"))
        #expect(rowIDs(output.summary) == ["1"])
    }

    @Test("An empty library is an empty success, not unavailable")
    func emptyLibrary() async throws {
        let library = FakeMediaLibrary()
        library.items = []
        let service = makeService(library: library, player: FakeMediaPlayer())
        let output = try await searchTool(service).execute(
            .init(query: "anything"),
            context: context()
        )
        #expect(output.exitStatus == 0)
        #expect(output.summary.contains("status=ok"))
        #expect(output.summary.contains("count=0"))
        #expect(output.summary.contains("emptyResult=true"))
        #expect(output.summary.contains("libraryEmpty=true"))
        #expect(!output.summary.contains("status=unavailable"))
    }

    @Test("Search pages are stable, unique and bounded")
    func searchPaginationIsStable() async throws {
        let library = FakeMediaLibrary()
        library.items = (1...120).map { item(UInt64($0)) }
        let service = makeService(library: library, player: FakeMediaPlayer())
        let store = ContactsMediaSnapshotStore()
        let tool = searchTool(service, store: store)
        let conversation = UUID()
        let first = try await tool.execute(.init(query: "Track", limit: 50), context: context(conversation: conversation))
        #expect(field("totalCount", in: first.summary) == "120")
        #expect(field("hasMore", in: first.summary) == "true")
        library.items = [item(999)]
        var ids = rowIDs(first.summary)
        var cursor = field("nextCursor", in: first.summary)
        var pages = 1
        while let next = cursor, next != "none", pages < 100 {
            let output = try await tool.execute(
                .init(limit: 50, cursor: next),
                context: context(conversation: conversation)
            )
            #expect(output.exitStatus == 0)
            #expect(field("totalCount", in: output.summary) == "120")
            ids.append(contentsOf: rowIDs(output.summary))
            cursor = field("nextCursor", in: output.summary)
            pages += 1
        }
        #expect(ids.count == 120)
        #expect(Set(ids).count == 120)
        #expect(pages > 1)
    }

    @Test("A media cursor belongs to the task that created it")
    func searchCursorOwnerIsolation() async throws {
        let library = FakeMediaLibrary()
        library.items = (1...20).map { item(UInt64($0)) }
        let service = makeService(library: library, player: FakeMediaPlayer())
        let tool = searchTool(service)
        let first = try await tool.execute(.init(query: "Track", limit: 5), context: context(conversation: UUID()))
        guard let cursor = field("nextCursor", in: first.summary), cursor != "none" else {
            Issue.record("expected a cursor")
            return
        }
        let other = try await tool.execute(.init(cursor: cursor), context: context(conversation: UUID()))
        #expect(other.exitStatus == 1)
        #expect(other.summary.contains("code=cursorNotOwned"))
        #expect(rowIDs(other.summary).isEmpty)
    }

    // MARK: - Playback

    @Test("Play preserves the exact requested ID order")
    func playPreservesExactOrder() async throws {
        let library = FakeMediaLibrary()
        library.items = [item(11), item(22), item(33)]
        let player = FakeMediaPlayer()
        let service = makeService(library: library, player: player)
        let output = try await playTool(service).execute(
            .init(persistentIDs: ["33", "11", "22"]),
            context: context()
        )
        #expect(output.exitStatus == 0)
        #expect(output.summary.contains("status=ok"))
        #expect(output.summary.contains("action=play"))
        #expect(output.summary.contains("playbackState=playing"))
        #expect(output.summary.contains("queue=33,11,22"))
        #expect(output.summary.contains("verifiedPlaying=true"))
        #expect(output.summary.contains("audioAudible=unverified"))
        #expect(player.queueIDs == [33, 11, 22])
    }

    @Test("A missing exact ID does not replace the current queue")
    func missingIDDoesNotReplaceQueue() async throws {
        let library = FakeMediaLibrary()
        library.items = [item(11)]
        let player = FakeMediaPlayer()
        let service = makeService(library: library, player: player)
        let conversation = UUID()
        _ = try await playTool(service).execute(
            .init(persistentIDs: ["11"]),
            context: context(conversation: conversation)
        )
        let before = player.setQueueCount
        let output = try await playTool(service).execute(
            .init(persistentIDs: ["11", "99"]),
            context: context(conversation: conversation)
        )
        #expect(output.exitStatus == 1)
        #expect(output.summary.contains("status=unavailable"))
        #expect(output.summary.contains("missing=1"))
        #expect(player.setQueueCount == before)
        #expect(player.queueIDs == [11])
    }

    @Test("Another task cannot pause, control or replace without authority")
    func ownerIsolation() async throws {
        let library = FakeMediaLibrary()
        library.items = [item(11), item(22)]
        let player = FakeMediaPlayer()
        let service = makeService(library: library, player: player)
        let ownerA = UUID()
        let ownerB = UUID()
        _ = try await playTool(service).execute(
            .init(persistentIDs: ["11"]),
            context: context(conversation: ownerA)
        )

        let pause = try await controlTool(service).execute(
            .init(action: "pause"),
            context: context(conversation: ownerB)
        )
        #expect(pause.exitStatus == 75)
        #expect(pause.summary.contains("status=notOwner"))
        #expect(player.pauseCount == 0)

        let busy = try await playTool(service).execute(
            .init(persistentIDs: ["22"]),
            context: context(conversation: ownerB)
        )
        #expect(busy.exitStatus == 75)
        #expect(busy.summary.contains("status=busy"))
        #expect(player.queueIDs == [11])

        let unapproved = try await playTool(service).execute(
            .init(persistentIDs: ["22"], replace: true),
            context: context(conversation: ownerB)
        )
        #expect(unapproved.exitStatus == 77)
        #expect(unapproved.summary.contains("status=replaceNotAuthorized"))
        #expect(player.queueIDs == [11])

        // The service accepts a replace only through its explicit injected
        // authority seam; the default tool path above did not have a token.
        let replaced = await service.play(
            persistentIDs: [22],
            caller: caller(conversation: ownerB),
            replaceRequested: true,
            authorizeReplace: { true },
            cancellation: CancellationToken()
        )
        guard case .playing(let nowPlaying) = replaced else {
            Issue.record("expected a playing replacement, got \(replaced)")
            return
        }
        #expect(nowPlaying.queueIDs == ["22"])
        #expect(player.queueIDs == [22])
    }

    @Test("A cancelled play never touches the queue")
    func cancelledPlayDoesNotTouchQueue() async {
        let library = FakeMediaLibrary()
        library.items = [item(11)]
        let player = FakeMediaPlayer()
        let service = makeService(library: library, player: player)
        let token = CancellationToken()
        token.cancel()
        let outcome = await service.play(
            persistentIDs: [11],
            caller: caller(conversation: UUID()),
            replaceRequested: false,
            authorizeReplace: { true },
            cancellation: token
        )
        #expect(outcome == .cancelled(effectApplied: false))
        #expect(player.setQueueCount == 0)
        #expect(player.playCount == 0)
    }

    @Test("Interruption is not reported as playing and is never auto-resumed")
    func interruptionIsNotPlaying() async throws {
        let library = FakeMediaLibrary()
        library.items = [item(11)]
        let player = FakeMediaPlayer()
        player.playState = .interrupted
        let service = makeService(library: library, player: player)
        let output = try await playTool(service).execute(
            .init(persistentIDs: ["11"]),
            context: context()
        )
        #expect(output.exitStatus == 0)
        #expect(output.summary.contains("status=interrupted"))
        #expect(output.summary.contains("autoResume=false"))
        #expect(!output.summary.contains("status=ok action=play"))
        #expect(player.playCount == 1)
    }

    @Test("Prepare success without a playing observation is accepted, not played")
    func acceptedNotYetPlaying() async throws {
        let library = FakeMediaLibrary()
        library.items = [item(11)]
        let player = FakeMediaPlayer()
        player.playState = .paused
        let service = makeService(library: library, player: player)
        let output = try await playTool(service).execute(
            .init(persistentIDs: ["11"]),
            context: context()
        )
        #expect(output.exitStatus == 0)
        #expect(output.summary.contains("status=acceptedNotYetPlaying"))
        #expect(output.summary.contains("verifiedPlaying=false"))
        #expect(!output.summary.contains("status=ok action=play"))
    }

    @Test("Now-playing reads the owned queue and exact IDs")
    func nowPlayingReadback() async throws {
        let library = FakeMediaLibrary()
        library.items = [item(11), item(22)]
        let player = FakeMediaPlayer()
        let service = makeService(library: library, player: player)
        let conversation = UUID()
        _ = try await playTool(service).execute(
            .init(persistentIDs: ["22", "11"]),
            context: context(conversation: conversation)
        )
        let output = try await nowPlayingTool(service).execute(
            .init(),
            context: context(conversation: conversation)
        )
        #expect(output.exitStatus == 0)
        #expect(output.summary.contains("ownership=owned"))
        #expect(output.summary.contains("playbackState=playing"))
        #expect(output.summary.contains("queue=22,11"))
        #expect(output.summary.contains("queueIndex=0"))
        #expect(output.summary.contains("queueMatches=true"))
        #expect(output.summary.contains("nowPlayingID=22"))
        #expect(output.summary.contains("audioAudible=unverified"))
    }

    @Test("A cold service never claims or auto-starts old playback")
    func coldStartDoesNotClaimOwnership() async throws {
        let library = FakeMediaLibrary()
        library.items = [item(9)]
        let player = FakeMediaPlayer()
        player.state = .playing
        player.nowPlayingID = "9"
        player.queueIDs = [9]
        player.index = 0
        let service = makeService(library: library, player: player)

        let read = try await nowPlayingTool(service).execute(.init(), context: context())
        #expect(read.exitStatus == 0)
        #expect(read.summary.contains("ownership=untracked"))
        #expect(read.summary.contains("canControl=false"))
        #expect(!read.summary.contains("ownership=owned"))

        let control = try await controlTool(service).execute(
            .init(action: "pause"),
            context: context()
        )
        #expect(control.exitStatus == 75)
        #expect(control.summary.contains("status=noActivePlayback"))
        #expect(player.playCount == 0)
        #expect(player.pauseCount == 0)
        #expect(player.setQueueCount == 0)
    }

    @Test("Authorization loss clears only this task's ownership")
    func authorizationLossClearsOwnership() async throws {
        let library = FakeMediaLibrary()
        library.items = [item(11)]
        let player = FakeMediaPlayer()
        let service = makeService(library: library, player: player)
        let conversation = UUID()
        _ = try await playTool(service).execute(
            .init(persistentIDs: ["11"]),
            context: context(conversation: conversation)
        )
        library.auth = .denied
        let denied = try await nowPlayingTool(service).execute(
            .init(),
            context: context(conversation: conversation)
        )
        #expect(denied.exitStatus == 77)
        #expect(denied.summary.contains("status=authorizationDenied"))
        #expect(player.stopCount == 1)

        library.auth = .authorized
        let idle = try await nowPlayingTool(service).execute(
            .init(),
            context: context(conversation: conversation)
        )
        #expect(idle.summary.contains("ownership=none"))
        #expect(idle.summary.contains("playbackState=stopped"))
    }

    @Test("Existing Floe audio ownership refuses a new queue without touching it")
    func audioBusyRefusesNewPlayback() async throws {
        let library = FakeMediaLibrary()
        library.items = [item(11)]
        let player = FakeMediaPlayer()
        let audio = SystemMediaAudioCoordination(probe: { "speech" })
        let service = makeService(library: library, player: player, audio: audio)
        let output = try await playTool(service).execute(
            .init(persistentIDs: ["11"]),
            context: context()
        )
        #expect(output.exitStatus == 75)
        #expect(output.summary.contains("status=audioBusy"))
        #expect(output.summary.contains("reason=speech"))
        #expect(player.setQueueCount == 0)
    }

    @Test("Temporary and backgrounded calls cannot touch media")
    func temporaryAndBackground() async throws {
        let library = FakeMediaLibrary()
        library.items = [item(11)]
        let service = makeService(library: library, player: FakeMediaPlayer())

        let temporary = try await searchTool(service).execute(
            .init(query: "Track"),
            context: context(temporary: true)
        )
        #expect(temporary.exitStatus == 75)
        #expect(temporary.summary.contains("reason=temporaryChat"))
        #expect(library.searchCount == 0)

        let background = try await searchTool(service, foreground: false)
            .execute(.init(query: "Track"), context: context())
        #expect(background.exitStatus == 75)
        #expect(background.summary.contains("status=foregroundRequired"))
        #expect(library.searchCount == 0)
    }

    @Test("Playback IDs are exact decimal persistent IDs")
    func invalidIDs() throws {
        let tool = AppleMediaPlayTool(service: makeService(
            library: FakeMediaLibrary(),
            player: FakeMediaPlayer()
        ))
        #expect(throws: (any Error).self) {
            try tool.validate(.init(persistentIDs: ["abc"]))
        }
        #expect(throws: (any Error).self) {
            try tool.validate(.init(persistentIDs: ["0"]))
        }
        #expect(throws: (any Error).self) {
            try tool.validate(.init(persistentIDs: ["1", "1"]))
        }
        #expect(throws: (any Error).self) {
            try tool.validate(.init(persistentIDs: (1...26).map(String.init)))
        }
        #expect(throws: Never.self) {
            try tool.validate(.init(persistentIDs: ["18446744073709551615"]))
        }
    }

    @Test("Media search input is literal and bounded")
    func searchBounds() throws {
        let tool = searchTool(makeService(
            library: FakeMediaLibrary(),
            player: FakeMediaPlayer()
        ))
        #expect(throws: (any Error).self) {
            try tool.validate(.init(query: "   "))
        }
        #expect(throws: (any Error).self) {
            try tool.validate(.init(query: String(repeating: "a", count: 121)))
        }
        #expect(throws: (any Error).self) {
            try tool.validate(.init(query: "a\nb"))
        }
        #expect(throws: (any Error).self) {
            try tool.validate(.init(query: "a", field: "genre"))
        }
        #expect(throws: (any Error).self) {
            try tool.validate(.init(query: "a", cursor: "cmc1.x"))
        }
    }

    @Test("A concurrent play is superseded and cannot claim the in-flight queue")
    func concurrentPlayIsSuperseded() async throws {
        let library = FakeMediaLibrary()
        library.items = [item(11), item(22)]
        let player = FakeMediaPlayer()
        player.holdNextPrepare = true
        let service = makeService(library: library, player: player, attempts: 2)
        let owner = UUID()

        let first = Task {
            await service.play(
                persistentIDs: [11],
                caller: caller(conversation: owner),
                replaceRequested: false,
                authorizeReplace: { true },
                cancellation: CancellationToken()
            )
        }
        while player.prepareWaiterCount == 0 {
            await Task.yield()
        }
        let concurrent = await service.play(
            persistentIDs: [22],
            caller: caller(conversation: owner),
            replaceRequested: false,
            authorizeReplace: { true },
            cancellation: CancellationToken()
        )
        #expect(concurrent == .superseded)

        player.releasePrepare()
        let firstResult = await first.value
        guard case .playing(let firstPlaying) = firstResult else {
            Issue.record("expected the in-flight play to finish, got \(firstResult)")
            return
        }
        #expect(firstPlaying.queueIDs == ["11"])

        // A later, non-concurrent play from the same task is the explicit
        // replacement path and wins with the exact new queue.
        let later = await service.play(
            persistentIDs: [22],
            caller: caller(conversation: owner),
            replaceRequested: false,
            authorizeReplace: { true },
            cancellation: CancellationToken()
        )
        guard case .playing(let laterPlaying) = later else {
            Issue.record("expected the later play to win, got \(later)")
            return
        }
        #expect(laterPlaying.queueIDs == ["22"])
        #expect(player.queueIDs == [22])
    }
}

// MARK: - Fakes

final class FakeMediaLibrary: SystemMediaLibraryProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _auth: SystemMediaAccess = .authorized
    private var _items: [SystemMediaItem] = []
    private var _requestCount = 0
    private var _searchCount = 0

    var auth: SystemMediaAccess {
        get { lock.lock(); defer { lock.unlock() }; return _auth }
        set { lock.lock(); _auth = newValue; lock.unlock() }
    }

    var items: [SystemMediaItem] {
        get { lock.lock(); defer { lock.unlock() }; return _items }
        set { lock.lock(); _items = newValue; lock.unlock() }
    }

    var requestCount: Int {
        lock.lock(); defer { lock.unlock() }; return _requestCount
    }

    var searchCount: Int {
        lock.lock(); defer { lock.unlock() }; return _searchCount
    }

    var isAvailable: Bool { true }

    var authorization: SystemMediaAccess { auth }

    func requestAuthorization(cancellation: CancellationToken) async throws -> SystemMediaAccess {
        let next = lock.withLock {
            _requestCount += 1
            let next = _auth == .notDetermined ? SystemMediaAccess.authorized : _auth
            _auth = next
            return next
        }
        if cancellation.isCancelled { throw SystemMediaError.cancelled }
        return next
    }

    func search(
        query: String,
        field: SystemMediaSearchField,
        maxRows: Int,
        cancellation: CancellationToken
    ) async throws -> SystemMediaSearchScan {
        let (status, all) = lock.withLock {
            _searchCount += 1
            return (_auth, _items)
        }
        if cancellation.isCancelled { throw SystemMediaError.cancelled }
        guard status == .authorized else {
            throw SystemMediaError.authorizationDenied
        }
        let normalized = query.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let matches = all.filter { item in
            func contains(_ value: String) -> Bool {
                value.folding(
                    options: [.caseInsensitive, .diacriticInsensitive],
                    locale: Locale(identifier: "en_US_POSIX")
                ).contains(normalized)
            }
            switch field {
            case .any: return contains(item.title) || contains(item.artist) || contains(item.album)
            case .title: return contains(item.title)
            case .artist: return contains(item.artist)
            case .album: return contains(item.album)
            }
        }
        let limit = min(max(1, maxRows), 200)
        return SystemMediaSearchScan(
            items: Array(matches.prefix(limit)),
            rawCount: matches.count,
            truncated: matches.count > limit,
            authorization: status
        )
    }

    func lookup(
        persistentIDs: [UInt64],
        cancellation: CancellationToken
    ) async throws -> [SystemMediaItem] {
        if cancellation.isCancelled { throw SystemMediaError.cancelled }
        let all = lock.withLock { _items }
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.persistentID, $0) })
        return persistentIDs.compactMap { byID[String($0)] }
    }

    func hasAnyItems() async -> Bool {
        lock.withLock { !_items.isEmpty }
    }
}

@MainActor
final class FakeMediaPlayer: SystemMediaPlayerBackend {
    var queueIDs: [UInt64] = []
    var state: SystemMediaPlaybackState = .stopped
    var nowPlayingID: String?
    var index: Int?
    var title = "Test Track"
    var artist = "Test Artist"
    var album = "Test Album"
    var playState: SystemMediaPlaybackState = .playing
    var setQueueCount = 0
    var prepareCount = 0
    var playCount = 0
    var pauseCount = 0
    var stopCount = 0
    var nextCount = 0
    var previousCount = 0
    var prepareError: SystemMediaError?
    var holdNextPrepare = false

    private var prepareWaiters: [CheckedContinuation<Void, Never>] = []

    var prepareWaiterCount: Int { prepareWaiters.count }

    func setQueue(persistentIDs: [UInt64]) throws {
        setQueueCount += 1
        queueIDs = persistentIDs
        nowPlayingID = persistentIDs.first.map(String.init)
        index = persistentIDs.isEmpty ? nil : 0
        state = .paused
    }

    func prepareToPlay() async throws {
        prepareCount += 1
        if holdNextPrepare {
            holdNextPrepare = false
            await withCheckedContinuation { continuation in
                prepareWaiters.append(continuation)
            }
        }
        if let prepareError { throw prepareError }
    }

    func releasePrepare() {
        let waiters = prepareWaiters
        prepareWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    func play() {
        playCount += 1
        state = playState
        if let first = queueIDs.first {
            nowPlayingID = String(first)
            index = 0
        }
    }

    func pause() {
        pauseCount += 1
        state = .paused
    }

    func stop() {
        stopCount += 1
        state = .stopped
        nowPlayingID = nil
        index = nil
    }

    func skipToNext() {
        nextCount += 1
        guard let current = index, current + 1 < queueIDs.count else {
            state = .stopped
            return
        }
        index = current + 1
        nowPlayingID = String(queueIDs[current + 1])
    }

    func skipToPrevious() {
        previousCount += 1
        guard let current = index, current > 0 else {
            state = .stopped
            return
        }
        index = current - 1
        nowPlayingID = String(queueIDs[current - 1])
    }

    func snapshot() -> SystemMediaPlayerSnapshot {
        SystemMediaPlayerSnapshot(
            state: state,
            nowPlayingID: nowPlayingID,
            title: title,
            artist: artist,
            album: album,
            index: index,
            currentTime: state == .stopped ? 0 : 12.5
        )
    }
}
#endif
