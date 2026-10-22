// FloeApp — bounded local media search, readback and owned transport tools.
//
// SPDX-License-Identifier: MPL-2.0
//
// Search output contains exact on-device persistent IDs. Play accepts only
// those IDs (never a store ID or catalog query), and control is restricted to
// the playback queue owned by the same task. No tool edits the library,
// purchases, signs in, or delegates to systemMusicPlayer.

#if canImport(UIKit) && canImport(MediaPlayer)
import Foundation
import FloeCore
import FloeTools

enum AppleMediaOutput {
    static func make(_ text: String, exitStatus: Int32 = 0) -> ToolExecutionOutput {
        ContactsMediaOutput.make(text, exitStatus: exitStatus)
    }

    static func failure(_ error: SystemMediaError) -> ToolExecutionOutput {
        make(
            "status=\(error.status) capability=media message=\(error.errorDescription ?? error.status)",
            exitStatus: error.exitStatus
        )
    }

    static func cursorFailure(_ error: PersonalToolCursorError) -> ToolExecutionOutput {
        make(
            "status=error code=\(error.code) capability=media message=\(error.errorDescription ?? "cursor error")",
            exitStatus: 1
        )
    }

    static func row(_ item: SystemMediaItem) -> String {
        let duration = item.durationSeconds.map { "\($0)s" } ?? "none"
        let line = [
            "id=\(item.persistentID)",
            "title=\(ContactsMediaText.quoted(item.title, limit: 160))",
            "artist=\(ContactsMediaText.quoted(item.artist, limit: 160))",
            "album=\(ContactsMediaText.quoted(item.album, limit: 160))",
            "duration=\(duration)",
            "type=\(item.mediaType)"
        ].joined(separator: " ")
        return ContactsMediaText.boundedRow(line, limit: 900)
    }

    static func nowPlayingFields(_ value: SystemMediaNowPlaying) -> String {
        let queue = value.queueIDs.joined(separator: ",")
        let index = value.queueIndex.map(String.init) ?? "none"
        let current = value.currentTime.map { String(format: "%.1f", $0) } ?? "none"
        return [
            "ownership=owned",
            "playbackState=\(value.state.rawValue)",
            "nowPlayingID=\(value.persistentID ?? "none")",
            "title=\(ContactsMediaText.quoted(value.title ?? "", limit: 160))",
            "artist=\(ContactsMediaText.quoted(value.artist ?? "", limit: 160))",
            "album=\(ContactsMediaText.quoted(value.album ?? "", limit: 160))",
            "queue=\(queue)",
            "queueIndex=\(index)",
            "queueMatches=\(value.queueIDs.contains(value.persistentID ?? ""))",
            "positionSeconds=\(current)",
            "audioAudible=unverified"
        ].joined(separator: " ")
    }

    static func outcome(
        _ outcome: SystemMediaPlaybackOutcome,
        action: String
    ) -> ToolExecutionOutput {
        switch outcome {
        case .playing(let value):
            return make(
                "status=ok action=\(action) " + nowPlayingFields(value)
                    + " verifiedPlaying=true"
            )
        case .paused(let value):
            return make(
                "status=paused action=\(action) " + nowPlayingFields(value)
                    + " verifiedPlaying=false"
            )
        case .state(let value):
            return make("status=ok action=\(action) " + nowPlayingFields(value))
        case .interrupted(let value):
            return make(
                "status=interrupted action=\(action) " + nowPlayingFields(value)
                    + " verifiedPlaying=false autoResume=false recovery=queryNowPlaying",
                exitStatus: 0
            )
        case .acceptedNotYetPlaying(let value):
            return make(
                "status=acceptedNotYetPlaying action=\(action) " + nowPlayingFields(value)
                    + " verifiedPlaying=false message=QueuePreparedButPlayingStateNotObserved",
                exitStatus: 0
            )
        case .stopped:
            let ownership = action == "stop" ? "released" : "owned"
            return make("status=stopped action=\(action) ownership=\(ownership)")
        case .idle:
            return make("status=ok action=\(action) ownership=none playbackState=stopped")
        case .untracked(let state):
            return make(
                "status=ok action=\(action) ownership=untracked playbackState=\(state.rawValue) canControl=false"
            )
        case .busy:
            return make(
                "status=busy action=\(action) reason=anotherTaskOwnsPlayback",
                exitStatus: 75
            )
        case .replaceNotAuthorized:
            return make(
                "status=replaceNotAuthorized action=\(action) reason=replaceRequiresExplicitAuthority",
                exitStatus: 77
            )
        case .notOwner:
            return make(
                "status=notOwner action=\(action) reason=anotherTaskOwnsPlayback",
                exitStatus: 75
            )
        case .noActivePlayback:
            return make(
                "status=noActivePlayback action=\(action) message=NoPlaybackOwnedByThisTask",
                exitStatus: 75
            )
        case .itemsUnavailable(let missing):
            return make(
                "status=unavailable action=\(action) reason=itemsMissing missing=\(missing)",
                exitStatus: 1
            )
        case .emptyQueue:
            return make(
                "status=error action=\(action) code=emptyQueue",
                exitStatus: 64
            )
        case .audioBusy(let reason):
            return make(
                "status=audioBusy action=\(action) reason=\(ContactsMediaText.bounded(reason, limit: 40))",
                exitStatus: 75
            )
        case .authorizationRequired:
            return make(
                "status=authorizationRequired capability=media message=KeepFloeInForegroundAndTryAgain",
                exitStatus: 77
            )
        case .authorizationDenied:
            return make(
                "status=authorizationDenied capability=media message=NoLibraryDataRead",
                exitStatus: 77
            )
        case .authorizationRestricted:
            return make(
                "status=authorizationRestricted capability=media message=NoLibraryDataRead",
                exitStatus: 77
            )
        case .unavailable:
            return make("status=unavailable capability=media", exitStatus: 75)
        case .cancelled(let effectApplied):
            return make(
                "status=cancelled action=\(action) effectApplied=\(effectApplied)",
                exitStatus: 130
            )
        case .timedOut:
            return make("status=timedOut action=\(action)", exitStatus: 124)
        case .failed(let code):
            return make(
                "status=failed action=\(action) code=\(ContactsMediaText.bounded(code, limit: 80))",
                exitStatus: 1
            )
        case .superseded:
            return make("status=superseded action=\(action) reason=newerRequestWon")
        }
    }
}

// MARK: - Search

struct AppleMediaSearchTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var query: String?
        var field: String?
        var limit: Int?
        var cursor: String?

        init(
            query: String? = nil,
            field: String? = nil,
            limit: Int? = nil,
            cursor: String? = nil
        ) {
            self.query = query
            self.field = field
            self.limit = limit
            self.cursor = cursor
        }
    }

    static let name = "apple.media.library.search"
    static let toolDescription = """
    Search the user's authorized ON-DEVICE media library after Media Library authorization. Returns exact persistent \
    media IDs plus bounded title/artist/album metadata. Search is literal text (no query language) over title, artist \
    and/or album; the first call reads at most 200 matching rows. Pages are stable, task-owned snapshots: limit defaults \
    to 50 (maximum 50); pass nextCursor back as cursor to continue the same snapshot. This tool never looks up the \
    store/cloud catalog, purchases, signs in, edits playlists or reads the library while Floe is backgrounded. An empty \
    result is reported as empty (and libraryEmpty when the library truly has no items), not as an authorization claim.
    """
    static let parametersJSON = #"""
    {"type":"object","properties":{"query":{"type":"string","maxLength":120,"description":"Literal text to find in the local library. Required on the first call; omit when continuing with cursor."},"field":{"type":"string","enum":["any","title","artist","album"],"description":"Field to match; defaults to any."},"limit":{"type":"integer","minimum":1,"maximum":50,"description":"Rows per page; defaults to 50."},"cursor":{"type":"string","maxLength":2048,"description":"Opaque nextCursor from a previous local-media search."}},"additionalProperties":false}
    """#
    static let riskLabels: Set<RiskLabel> = [.persistsPersonalData]
    static let isSideEffecting = false
    static let toolEffect: ToolEffect = .readOnly

    static let kindPrefix = "apple.media.library.search.v1"
    static let maxRawRows = 200

    private let service: SystemMediaPlaybackService
    private let store: ContactsMediaSnapshotStore
    private let isForeground: @Sendable () async -> Bool

    init(
        service: SystemMediaPlaybackService,
        store: ContactsMediaSnapshotStore,
        isForeground: @escaping @Sendable () async -> Bool = {
            await ContactsMediaForeground.isActive()
        }
    ) {
        self.service = service
        self.store = store
        self.isForeground = isForeground
    }

    func validate(_ args: Arguments) throws {
        _ = try Self.plan(args)
    }

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        guard !context.temporaryReadOnly, !context.publicWebOnly else {
            return AppleMediaOutput.make(
                "status=unavailable capability=media reason=temporaryChat",
                exitStatus: 75
            )
        }
        let plan = try Self.plan(args)
        guard await isForeground() else {
            return AppleMediaOutput.failure(.foregroundRequired)
        }

        var authorization = await service.authorization
        if authorization == .notDetermined, plan.cursor == nil {
            do {
                authorization = try await service.requestAuthorization(cancellation: context.cancellation)
            } catch let error as SystemMediaError {
                await store.invalidateKindPrefix(Self.kindPrefix)
                return AppleMediaOutput.failure(error)
            } catch {
                await store.invalidateKindPrefix(Self.kindPrefix)
                return AppleMediaOutput.make(
                    "status=authorizationRequestRejected capability=media",
                    exitStatus: 77
                )
            }
        }
        guard authorization == .authorized else {
            await store.invalidateKindPrefix(Self.kindPrefix)
            return AppleMediaOutput.failure(Self.authorizationError(authorization))
        }

        let owner = PersonalToolOwnerID(context: context)
        if let cursor = plan.cursor {
            do {
                if context.cancellation.isCancelled {
                    return AppleMediaOutput.failure(.cancelled)
                }
                let page = try await store.next(
                    cursor: cursor,
                    owner: owner,
                    kind: Self.kindPrefix,
                    filterKey: nil,
                    pageSize: plan.limit
                )
                return Self.output(
                    page: page,
                    scan: nil,
                    libraryEmpty: false,
                    plan: plan,
                    cursorPage: true
                )
            } catch let error as PersonalToolCursorError {
                await store.invalidateKindPrefix(Self.kindPrefix)
                return AppleMediaOutput.cursorFailure(error)
            } catch {
                await store.invalidateKindPrefix(Self.kindPrefix)
                return AppleMediaOutput.make(
                    "status=error capability=media message=The media cursor could not be continued. Start a new search.",
                    exitStatus: 1
                )
            }
        }

        do {
            if context.cancellation.isCancelled {
                return AppleMediaOutput.failure(.cancelled)
            }
            let scan = try await service.search(
                query: plan.query,
                field: plan.field,
                maxRows: Self.maxRawRows,
                cancellation: context.cancellation
            )
            try context.cancellation.throwIfCancelled()
            let lines = scan.items.map(AppleMediaOutput.row)
            let page = try await store.begin(
                kind: Self.kindPrefix,
                filterKey: "q=\(plan.query)|field=\(plan.field.rawValue)",
                lines: lines,
                owner: owner,
                pageSize: plan.limit,
                truncated: scan.truncated
            )
            var libraryEmpty = false
            if scan.items.isEmpty {
                libraryEmpty = !(await service.hasAnyItems())
            }
            return Self.output(
                page: page,
                scan: scan,
                libraryEmpty: libraryEmpty,
                plan: plan,
                cursorPage: false
            )
        } catch let error as SystemMediaError {
            await store.invalidateKindPrefix(Self.kindPrefix)
            return AppleMediaOutput.failure(error)
        } catch let error as PersonalToolCursorError {
            await store.invalidateKindPrefix(Self.kindPrefix)
            return AppleMediaOutput.cursorFailure(error)
        } catch {
            await store.invalidateKindPrefix(Self.kindPrefix)
            return AppleMediaOutput.make(
                "status=queryFailed capability=media message=The local media search failed.",
                exitStatus: 1
            )
        }
    }

    private static func output(
        page: PersonalToolPage,
        scan: SystemMediaSearchScan?,
        libraryEmpty: Bool,
        plan: MediaSearchPlan,
        cursorPage: Bool
    ) -> ToolExecutionOutput {
        var fields = [
            "status=ok",
            "kind=apple.media.library.search",
            "count=\(page.returnedCount)",
            "totalCount=\(page.totalCount)",
            "hasMore=\(page.hasMore)",
            "nextCursor=\(page.nextCursor ?? "none")",
            "pageCount=\(page.pageCount)",
            "snapshotTime=\(ContactsMediaOutput.iso(page.snapshotTime))",
            "completeness=\(page.completeness)",
            "authorization=authorized",
            "readOnly=true",
            "libraryMutation=false",
            "scanCap=\(maxRawRows)",
            "cursorPage=\(cursorPage)"
        ]
        if let scan {
            fields.append("matchedRaw=\(scan.rawCount)")
            fields.append("scanTruncated=\(scan.truncated)")
        }
        if page.totalCount == 0 {
            fields.append("emptyResult=true")
            fields.append("libraryEmpty=\(libraryEmpty)")
        }
        if page.truncatedRows > 0 {
            fields.append("truncatedRows=\(page.truncatedRows)")
        }
        if !cursorPage {
            fields.append("field=\(plan.field.rawValue)")
        }
        return ContactsMediaOutput.page(
            header: fields.joined(separator: " "),
            page: page
        )
    }

    private static func authorizationError(_ status: SystemMediaAccess) -> SystemMediaError {
        switch status {
        case .notDetermined: .authorizationRequired
        case .denied: .authorizationDenied
        case .restricted: .authorizationRestricted
        case .authorized, .unavailable: .unavailable
        }
    }

    private struct MediaSearchPlan {
        var query: String
        var field: SystemMediaSearchField
        var limit: Int
        var cursor: String?
    }

    private static func plan(_ args: Arguments) throws -> MediaSearchPlan {
        let limit = args.limit ?? 50
        guard (1...50).contains(limit) else {
            throw FloeError.validationFailed("limit must be 1...50")
        }
        let rawCursor = args.cursor?.trimmingCharacters(in: .whitespacesAndNewlines)
        let cursor = rawCursor?.isEmpty == true ? nil : rawCursor
        if let cursor {
            guard cursor.count <= 2_048 else {
                throw FloeError.validationFailed("cursor is too long")
            }
            guard args.query == nil, args.field == nil else {
                throw FloeError.validationFailed("cursor continues a snapshot; omit query and field")
            }
            return MediaSearchPlan(query: "", field: .any, limit: limit, cursor: cursor)
        }
        let rawQuery = args.query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rawQuery.isEmpty else {
            throw FloeError.validationFailed("query is required")
        }
        guard rawQuery.count <= 120, rawQuery.utf8.count <= 480 else {
            throw FloeError.validationFailed("query must be at most 120 characters")
        }
        guard !rawQuery.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw FloeError.validationFailed("query must not contain control characters")
        }
        let field: SystemMediaSearchField
        if let rawField = args.field?.trimmingCharacters(in: .whitespacesAndNewlines), !rawField.isEmpty {
            guard let parsed = SystemMediaSearchField(rawValue: rawField) else {
                throw FloeError.validationFailed(
                    "field must be one of: \(SystemMediaSearchField.allCases.map(\.rawValue).joined(separator: ", "))"
                )
            }
            field = parsed
        } else {
            field = .any
        }
        return MediaSearchPlan(query: rawQuery, field: field, limit: limit, cursor: nil)
    }
}

// MARK: - Now playing

struct AppleMediaNowPlayingTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        init() {}
    }

    static let name = "apple.media.nowPlaying"
    static let toolDescription = """
    Read the current state of the media queue owned by THIS task through the app-scoped application queue player. \
    Reports the exact queue persistent IDs, queue index, current item metadata and the observed playback state. \
    status=ok ownership=none means no playback is owned by this task; ownership=untracked means the player holds state \
    this service did not create (for example after relaunch) and controls are not claimed. Another task's playback is \
    reported as busy without exposing its queue. Playback state is an observed native state; audible output is not \
    proven. An interrupted state is reported with autoResume=false.
    """
    static let parametersJSON = #"{"type":"object","properties":{},"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.persistsPersonalData]
    static let isSideEffecting = false
    static let toolEffect: ToolEffect = .readOnly

    private let service: SystemMediaPlaybackService
    private let isForeground: @Sendable () async -> Bool

    init(
        service: SystemMediaPlaybackService,
        isForeground: @escaping @Sendable () async -> Bool = {
            await ContactsMediaForeground.isActive()
        }
    ) {
        self.service = service
        self.isForeground = isForeground
    }

    func validate(_ args: Arguments) throws {}

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        guard !context.temporaryReadOnly, !context.publicWebOnly else {
            return AppleMediaOutput.make(
                "status=unavailable capability=media reason=temporaryChat",
                exitStatus: 75
            )
        }
        guard await isForeground() else {
            return AppleMediaOutput.failure(.foregroundRequired)
        }
        let outcome = await service.nowPlaying(
            caller: SystemMediaCaller(context: context),
            cancellation: context.cancellation
        )
        return AppleMediaOutput.outcome(outcome, action: "nowPlaying")
    }
}

// MARK: - Play

struct AppleMediaPlayTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var persistentIDs: [String]?
        var replace: Bool?

        init(persistentIDs: [String]? = nil, replace: Bool? = nil) {
            self.persistentIDs = persistentIDs
            self.replace = replace
        }
    }

    static let name = "apple.media.play"
    static let toolDescription = """
    Play exact ON-DEVICE media persistent IDs returned by apple.media.library.search through the application-scoped \
    queue player. This never affects the Music app's own playback and never uses store IDs, the cloud catalog, \
    subscriptions or account sign-in. A task may restart its own queue. If another task owns playback, the call is \
    refused as busy unless replace=true AND this exact approved call carries runtime replace authority; replacing \
    stops claiming the old owner, it does not control the user's unrelated Music app. Preparation success plus an \
    observed playing state is reported as verifiedPlaying=true, but audible output is always unverified. If the \
    bounded probe only sees paused/stopped/seeking, the result is acceptedNotYetPlaying rather than a success claim.
    """
    static let parametersJSON = #"""
    {"type":"object","properties":{"persistentIDs":{"type":"array","minItems":1,"maxItems":25,"items":{"type":"string","maxLength":20},"description":"Exact local-library persistent IDs from a previous search."},"replace":{"type":"boolean","description":"Request an explicit authorized replacement of another task's app-scoped playback. Defaults to false."}},"required":["persistentIDs"],"additionalProperties":false}
    """#
    static let riskLabels: Set<RiskLabel> = [.controlsGUI]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .mutating

    private let service: SystemMediaPlaybackService
    private let isForeground: @Sendable () async -> Bool

    init(
        service: SystemMediaPlaybackService,
        isForeground: @escaping @Sendable () async -> Bool = {
            await ContactsMediaForeground.isActive()
        }
    ) {
        self.service = service
        self.isForeground = isForeground
    }

    func validate(_ args: Arguments) throws {
        _ = try Self.parseIDs(args)
    }

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        guard !context.temporaryReadOnly, !context.publicWebOnly else {
            return AppleMediaOutput.make(
                "status=unavailable capability=media reason=temporaryChat",
                exitStatus: 75
            )
        }
        let ids = try Self.parseIDs(args)
        guard await isForeground() else {
            return AppleMediaOutput.failure(.foregroundRequired)
        }
        let replace = args.replace ?? false
        let outcome = await service.play(
            persistentIDs: ids,
            caller: SystemMediaCaller(context: context),
            replaceRequested: replace,
            authorizeReplace: { [context, args] in
                await Self.authorizeReplace(context: context, arguments: args)
            },
            cancellation: context.cancellation
        )
        return AppleMediaOutput.outcome(outcome, action: "play")
    }

    private static func parseIDs(_ args: Arguments) throws -> [UInt64] {
        guard let rawIDs = args.persistentIDs, !rawIDs.isEmpty else {
            throw FloeError.validationFailed("persistentIDs is required")
        }
        guard rawIDs.count <= 25 else {
            throw FloeError.validationFailed("persistentIDs must contain at most 25 items")
        }
        var ids: [UInt64] = []
        var seen = Set<UInt64>()
        for raw in rawIDs {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.count <= 20,
                  value.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }),
                  let id = UInt64(value), id > 0 else {
                throw SystemMediaError.invalidID
            }
            guard seen.insert(id).inserted else {
                throw FloeError.validationFailed("persistentIDs must be unique")
            }
            ids.append(id)
        }
        return ids
    }

    /// A replace is only accepted from an approved call with runtime-issued
    /// authority bound to this tool, the exact approved arguments and the
    /// runtime's canonical target. The binding mirrors the runtime mint:
    /// default operation "apply", scope fallback target and a digest over the
    /// canonical approved JSON. The token is consumed once; the service calls
    /// this only when another task actually owns playback, so an ordinary
    /// play never burns authority.
    private static func authorizeReplace(
        context: ToolContext,
        arguments: Arguments
    ) async -> Bool {
        guard context.runtimeAuthority != nil else { return false }
        var payload: [String: Any] = [:]
        if let persistentIDs = arguments.persistentIDs {
            payload["persistentIDs"] = persistentIDs
        }
        if let replace = arguments.replace {
            payload["replace"] = replace
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            return false
        }
        let binding = context.runtimeAuthorityBinding(
            toolName: Self.name,
            operation: "apply",
            canonicalTarget: canonicalTarget(context: context),
            baseRevision: RuntimeAuthorityDigest.baseRevision(in: data),
            payloadDigest: RuntimeAuthorityDigest.payloadDigest(data)
        )
        let validation = await context.consumeRuntimeAuthority(binding: binding)
        return validation.isValid
    }

    private static func canonicalTarget(context: ToolContext) -> String {
        // Any mutating tool without a recognized narrow target resolves to
        // the workspace wildcard key. Mirror MediaProjectTool's runtime
        // binding: the canonical root when one exists, "*" otherwise.
        guard let root = context.workspaceRootURL else { return "workspace:*" }
        return "workspace:" + root.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

// MARK: - Transport control

struct AppleMediaControlTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var action: String?

        init(action: String? = nil) {
            self.action = action
        }
    }

    static let name = "apple.media.control"
    static let toolDescription = """
    Control only the app-scoped local media queue owned by THIS task: pause, resume, toggle, next, previous or stop. \
    A task cannot control another task's playback; another owner is reported as notOwner/busy. Pause/resume/skip \
    return the observed native state after a bounded wait. interrupted is reported with autoResume=false. stop clears \
    this task's ownership only; it never tears down the user's unrelated Music app playback or another task's queue.
    """
    static let parametersJSON = #"""
    {"type":"object","properties":{"action":{"type":"string","enum":["play","pause","toggle","next","previous","stop"]}},"required":["action"],"additionalProperties":false}
    """#
    static let riskLabels: Set<RiskLabel> = [.controlsGUI]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .mutating

    private let service: SystemMediaPlaybackService
    private let isForeground: @Sendable () async -> Bool

    init(
        service: SystemMediaPlaybackService,
        isForeground: @escaping @Sendable () async -> Bool = {
            await ContactsMediaForeground.isActive()
        }
    ) {
        self.service = service
        self.isForeground = isForeground
    }

    func validate(_ args: Arguments) throws {
        _ = try Self.action(args)
    }

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        guard !context.temporaryReadOnly, !context.publicWebOnly else {
            return AppleMediaOutput.make(
                "status=unavailable capability=media reason=temporaryChat",
                exitStatus: 75
            )
        }
        let action = try Self.action(args)
        guard await isForeground() else {
            return AppleMediaOutput.failure(.foregroundRequired)
        }
        let outcome = await service.control(
            action,
            caller: SystemMediaCaller(context: context),
            cancellation: context.cancellation
        )
        return AppleMediaOutput.outcome(outcome, action: action.rawValue)
    }

    private static func action(_ args: Arguments) throws -> SystemMediaControlAction {
        guard let raw = args.action?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let action = SystemMediaControlAction(rawValue: raw) else {
            throw FloeError.validationFailed(
                "action must be one of: \(SystemMediaControlAction.allCases.map(\.rawValue).joined(separator: ", "))"
            )
        }
        return action
    }
}
#endif
