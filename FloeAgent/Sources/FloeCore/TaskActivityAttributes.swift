// FloeCore — shared ordinary-task Live Activity contract (App + Widget).
//
// SPDX-License-Identifier: MPL-2.0
//
// The App is the only producer of ordinary-task Live Activity content: it
// converts the tasks that are actually running into one bounded snapshot and
// hands it to ActivityKit. The FloeWidgets extension is the only consumer and
// renders exactly that snapshot. This type is the single codec for both
// sides, so the durable shape stays small, sanitized and navigation-only.
//
// It carries no prompt, tool argument, file path, credential or message body:
// a row is a bounded title, a derived state, a one-line status and the
// canonical exact-task route.
//
// Guard rationale (verified against the installed iOS 27 SDK swiftinterface):
// `ActivityAttributes` is `@available(iOS 16.1, *)` and explicitly
// `@available(macOS, unavailable)` / `@available(macCatalyst, unavailable)`.
// The payload shape itself stays pure Foundation so FloeApp and FloeCore
// tests can build it on every supported platform; only the ActivityKit
// conformance is compiled where the framework exists.

import Foundation

/// One bounded task Live Activity snapshot. Equality is content equality: it
/// deliberately has no timestamp, so an unchanged real state never produces
/// a redundant system update.
public struct FloeTaskActivitySnapshot: Codable, Equatable, Hashable, Sendable {
    /// The Lock Screen list stays short; a Live Activity is a glance surface,
    /// not a task manager. The header count still reports every active task.
    public static let maximumRows = 4
    public static let maximumTitleCharacters = 80
    public static let maximumStatusCharacters = 60
    /// Character caps are grapheme caps, so one character can legitimately be
    /// hundreds of bytes (a base scalar plus many combining marks). ActivityKit
    /// rejects a state payload at 4 KB, so each field also has a hard UTF-8
    /// budget. With four rows, the canonical 48-byte task route, and worst-case
    /// JSON escaping, these caps stay below the payload ceiling.
    public static let maximumTitleBytes = 192
    public static let maximumStatusBytes = 144
    public static let maximumRouteBytes = 256
    public static let maximumActiveCount = 99
    /// At most one planned-wait row is shown in the aggregate activity; other
    /// plans are summarized by `scheduledCount`, never by extra activity rows.
    public static let maximumScheduledShellCount = 1
    /// ActivityKit's documented state payload ceiling (4 KB). The snapshot is
    /// encoded and checked before every request/update; production content is
    /// capped well below it.
    public static let maximumEncodedBytes = 4 * 1024

    public var rows: [Row]
    public var activeCount: Int
    /// Number of enabled planned tasks, not running rows. Nil/zero hides the
    /// header count. This is the "more" summary: one wait row plus a count,
    /// never one Live Activity per plan.
    public var scheduledCount: Int?

    public init(rows: [Row] = [], activeCount: Int = 0, scheduledCount: Int? = nil) {
        self.rows = rows
        self.activeCount = activeCount
        self.scheduledCount = scheduledCount
    }

    public static var empty: Self { Self() }

    public var isIdle: Bool { rows.isEmpty }

    /// One task row. `id` is the run identity; `route` is the canonical
    /// `floe://task/<conversation>` link, never an execution request.
    public struct Row: Codable, Equatable, Hashable, Sendable, Identifiable {
        public var id: String
        public var title: String
        public var state: WidgetTaskState
        public var status: String
        public var route: URL?
        public var startedAt: Date
        /// Non-nil only for the single planned-wait row: the real next clock
        /// fire. The widget renders a system-driven countdown from this value
        /// (`Text(timerInterval:)`), never a one-second database poll or a
        /// keep-alive loop. An event-driven plan has no such value and is
        /// summarized by the header count instead of a fabricated countdown.
        public var waitingUntil: Date?

        public init(
            id: String,
            title: String,
            state: WidgetTaskState,
            status: String,
            route: URL?,
            startedAt: Date,
            waitingUntil: Date? = nil
        ) {
            self.id = id
            self.title = title
            self.state = state
            self.status = status
            self.route = route
            self.startedAt = startedAt
            self.waitingUntil = waitingUntil
        }

        /// Production factory: sanitizes both text fields, derives the route
        /// from the owning conversation and never accepts caller-authored
        /// URLs. A task without an owned conversation has no route.
        public static func task(
            runID: UUID,
            conversationID: UUID?,
            title: String,
            state: WidgetTaskState,
            status: String,
            startedAt: Date
        ) -> Self {
            Self(
                id: runID.uuidString,
                title: boundedText(
                    title,
                    characters: FloeTaskActivitySnapshot.maximumTitleCharacters,
                    bytes: FloeTaskActivitySnapshot.maximumTitleBytes
                ),
                state: state,
                status: boundedText(
                    status,
                    characters: FloeTaskActivitySnapshot.maximumStatusCharacters,
                    bytes: FloeTaskActivitySnapshot.maximumStatusBytes
                ),
                route: conversationID.map { FloeAppEntryRoute.task($0).url },
                startedAt: startedAt
            )
        }

        /// The single planned-wait row. Its identity is namespaced by the
        /// schedule so it can never collide with a run UUID, its state is
        /// always `.waiting` (truthful: nothing runs yet) and its countdown is
        /// the real next fire time. `route` is the plan's trusted origin
        /// conversation, when one exists; no route is invented otherwise.
        public static func scheduledWait(
            scheduleID: UUID,
            conversationID: UUID?,
            title: String,
            nextFireAt: Date
        ) -> Self {
            Self(
                id: "schedule:" + scheduleID.uuidString,
                title: boundedText(
                    title,
                    characters: FloeTaskActivitySnapshot.maximumTitleCharacters,
                    bytes: FloeTaskActivitySnapshot.maximumTitleBytes
                ),
                state: .waiting,
                status: "",
                route: conversationID.map { FloeAppEntryRoute.task($0).url },
                startedAt: nextFireAt,
                waitingUntil: nextFireAt
            )
        }

        /// Character cap first (fast, natural read), then a hard UTF-8 cap.
        /// Combining marks can make one grapheme far larger than its character
        /// count suggests, so the byte budget is enforced on every output path.
        private static func boundedText(
            _ raw: String,
            characters: Int,
            bytes: Int
        ) -> String {
            let sanitized = WidgetTaskSnapshot.sanitizedTitle(raw)
            let characterBounded = String(sanitized.prefix(characters))
            guard characterBounded.utf8.count > bytes else { return characterBounded }

            var truncated = ""
            truncated.reserveCapacity(min(characterBounded.count, bytes))
            var used = 0
            for character in characterBounded {
                let size = String(character).utf8.count
                guard used + size <= bytes else { break }
                truncated.append(character)
                used += size
            }
            if truncated.isEmpty {
                // A single grapheme cluster exceeds the whole byte budget.
                // Fall back to a scalar-safe prefix: bounded, valid UTF-8,
                // without splitting a Unicode scalar or emitting a replacement
                // character.
                for scalar in characterBounded.unicodeScalars {
                    let size = String(scalar).utf8.count
                    guard used + size <= bytes else { break }
                    truncated.unicodeScalars.append(scalar)
                    used += size
                }
            }
            return String(
                truncated
                    .trimmingCharacters(in: .whitespaces)
                    .prefix(characters)
            )
        }
    }

    /// Actual encoded size of the state payload. Matches what the coordinator
    /// checks before handing content to ActivityKit; `Int.max` means the
    /// payload could not be encoded and must be refused.
    public var encodedByteCount: Int {
        (try? JSONEncoder().encode(self).count) ?? Int.max
    }

    // MARK: - Validation

    /// Structural validation used by the producer before a system update and
    /// by focused tests. The widget's render path treats an invalid payload
    /// as an empty state instead of displaying partial content.
    public func validate() throws {
        guard rows.count <= Self.maximumRows else {
            throw FloeTaskActivitySnapshotError.tooManyRows
        }
        guard (0...Self.maximumActiveCount).contains(activeCount) else {
            throw FloeTaskActivitySnapshotError.activeCountOutOfRange
        }
        if let scheduledCount {
            guard (0...Self.maximumActiveCount).contains(scheduledCount) else {
                throw FloeTaskActivitySnapshotError.scheduledCountOutOfRange
            }
        }
        var seen: Set<String> = []
        var waitRows = 0
        for row in rows {
            guard seen.insert(row.id).inserted else {
                throw FloeTaskActivitySnapshotError.duplicateRow
            }
            if let waitingUntil = row.waitingUntil {
                waitRows += 1
                guard row.state == .waiting else {
                    throw FloeTaskActivitySnapshotError.invalidWaitingUntil
                }
                guard waitingUntil.timeIntervalSinceReferenceDate.isFinite else {
                    throw FloeTaskActivitySnapshotError.invalidWaitingUntil
                }
            }
            guard row.title.count <= Self.maximumTitleCharacters,
                  row.title.utf8.count <= Self.maximumTitleBytes else {
                throw FloeTaskActivitySnapshotError.titleTooLong
            }
            guard row.status.count <= Self.maximumStatusCharacters,
                  row.status.utf8.count <= Self.maximumStatusBytes else {
                throw FloeTaskActivitySnapshotError.statusTooLong
            }
            guard !row.title.contains(where: { $0.isNewline }),
                  !row.status.contains(where: { $0.isNewline }) else {
                throw FloeTaskActivitySnapshotError.multilineText
            }
            guard row.startedAt.timeIntervalSinceReferenceDate.isFinite else {
                throw FloeTaskActivitySnapshotError.invalidDate
            }
            if let route = row.route {
                guard route.absoluteString.utf8.count <= Self.maximumRouteBytes else {
                    throw FloeTaskActivitySnapshotError.routeTooLong
                }
                guard let parsed = try? FloeAppEntryRoute.parse(route),
                      case .task = parsed else {
                    throw FloeTaskActivitySnapshotError.invalidRoute
                }
            }
        }
        guard encodedByteCount <= Self.maximumEncodedBytes else {
            throw FloeTaskActivitySnapshotError.payloadTooLarge
        }
        guard waitRows <= Self.maximumScheduledShellCount else {
            throw FloeTaskActivitySnapshotError.tooManyScheduledShells
        }
    }
}

public enum FloeTaskActivitySnapshotError: Error, Equatable, Sendable {
    case tooManyRows
    case activeCountOutOfRange
    case scheduledCountOutOfRange
    case duplicateRow
    case titleTooLong
    case statusTooLong
    case multilineText
    case invalidDate
    case invalidRoute
    case routeTooLong
    case payloadTooLarge
    case invalidWaitingUntil
    case tooManyScheduledShells

    /// Log-safe classifier; never includes user content.
    public var logKind: String {
        switch self {
        case .tooManyRows: "too_many_rows"
        case .activeCountOutOfRange: "active_count"
        case .scheduledCountOutOfRange: "scheduled_count"
        case .duplicateRow: "duplicate_row"
        case .titleTooLong: "title_too_long"
        case .statusTooLong: "status_too_long"
        case .multilineText: "multiline"
        case .invalidDate: "invalid_date"
        case .invalidRoute: "invalid_route"
        case .routeTooLong: "route_too_long"
        case .payloadTooLarge: "payload_too_large"
        case .invalidWaitingUntil: "invalid_waiting_until"
        case .tooManyScheduledShells: "too_many_scheduled_shells"
        }
    }
}

#if os(iOS) && canImport(ActivityKit) && !targetEnvironment(macCatalyst)
import ActivityKit

/// The exact attributes type the App requests and the widget renders. The
/// attributes stay immutable for the activity's lifetime: only the batch
/// start date, so the Lock Screen timer reflects the real work.
public struct FloeTaskActivityAttributes: ActivityAttributes, Sendable {
    public typealias ContentState = FloeTaskActivitySnapshot

    public var startDate: Date

    public init(startDate: Date) {
        self.startDate = startDate
    }
}
#endif
