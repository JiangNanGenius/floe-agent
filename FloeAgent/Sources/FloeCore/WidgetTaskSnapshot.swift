// FloeCore — Home-screen widget task snapshot contract.
//
// The App writes a bounded, privacy-minimal projection of tasks that are
// actually running to the shared App Group container. The widget extension
// reads it in a separate process. This type is the single codec for both
// sides: versioned schema, row/byte/title limits, atomic replacement and
// explicit load results (missing/stale/unavailable/invalid) so neither
// process treats corrupted or old data as live work.
//
// The snapshot deliberately contains no message text, tool arguments, file
// paths, credentials, prompts or temporary-chat rows.

import Foundation

/// Presentation state derived from the durable run state. Only non-terminal
/// runs are published; an unrecognised non-terminal state stays `unknown`
/// rather than being relabelled as running.
public enum WidgetTaskState: String, Codable, CaseIterable, Sendable {
    case starting
    case running
    case waiting
    case paused
    case unknown

    public init(runState: String) {
        switch runState {
        case "queued", "submitted", "preparing", "starting":
            self = .starting
        case "streamingModel", "reconnecting", "executingTool",
             "committingResults", "compacting", "verifying",
             "running", "active", "inProgress":
            self = .running
        case "waitingApproval", "waitingInput", "waiting", "reviewingApproval":
            self = .waiting
        case "checkpointed", "paused", "held", "interrupted", "recoveryFailed":
            self = .paused
        default:
            self = .unknown
        }
    }
}

/// One versioned widget snapshot. Keep this small: five rows of identifiers,
/// a sanitized title, a derived state and timestamps.
public struct WidgetTaskSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let maximumTasks = 5
    public static let maximumTitleCharacters = 80
    /// Hard cap on the encoded file. The schema above cannot reach this with
    /// valid rows; the limit protects the reader from a replaced/oversized file.
    public static let maximumEncodedBytes = 32 * 1024
    /// A snapshot older than this is not live work. The widget shows a
    /// refresh hint instead of presenting old tasks as running.
    public static let freshnessInterval: TimeInterval = 24 * 60 * 60
    /// Small clock skew is tolerated; a snapshot from the future beyond this
    /// tolerance is treated as invalid rather than permanently fresh.
    public static let futureTolerance: TimeInterval = 5 * 60

    public var schemaVersion: Int
    public var generatedAt: Date
    public var tasks: [Item]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        generatedAt: Date,
        tasks: [Item]
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.tasks = tasks
    }

    /// A task row. `id` is the conversation identity, never a run-only id:
    /// tapping the row navigates to the exact task and never launches work.
    public struct Item: Codable, Equatable, Identifiable, Sendable {
        public var id: UUID
        public var runID: UUID
        public var title: String
        public var state: WidgetTaskState
        public var updatedAt: Date

        public init(
            id: UUID,
            runID: UUID,
            title: String,
            state: WidgetTaskState,
            updatedAt: Date
        ) {
            self.id = id
            self.runID = runID
            self.title = title
            self.state = state
            self.updatedAt = updatedAt
        }

        /// Canonical exact-task navigation link. This is a route, not an
        /// execution request.
        public var taskURL: URL {
            FloeAppEntryRoute.task(id).url
        }
    }

    /// Canonical new-task navigation link from the shared route codec.
    public static var newTaskURL: URL {
        FloeAppEntryRoute.newTask.url
    }

    // MARK: - Validation

    /// Structural validation used by the producer before writing and by the
    /// reader after decoding. Unknown schema versions are rejected, not
    /// silently upgraded.
    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw WidgetTaskSnapshotError.unsupportedSchema(schemaVersion)
        }
        guard generatedAt.timeIntervalSinceReferenceDate.isFinite else {
            throw WidgetTaskSnapshotError.invalidDate
        }
        guard tasks.count <= Self.maximumTasks else {
            throw WidgetTaskSnapshotError.tooManyTasks
        }
        var seen: Set<UUID> = []
        var seenRuns: Set<UUID> = []
        for task in tasks {
            guard seen.insert(task.id).inserted else {
                throw WidgetTaskSnapshotError.duplicateTaskID
            }
            guard seenRuns.insert(task.runID).inserted else {
                throw WidgetTaskSnapshotError.duplicateRunID
            }
            guard task.updatedAt.timeIntervalSinceReferenceDate.isFinite else {
                throw WidgetTaskSnapshotError.invalidDate
            }
            guard task.title.count <= Self.maximumTitleCharacters else {
                throw WidgetTaskSnapshotError.titleTooLong
            }
            try Self.validateTitleScalars(task.title)
        }
    }

    public enum Freshness: Equatable, Sendable {
        case fresh
        case stale
        case invalidFuture
    }

    public func freshness(at now: Date) -> Freshness {
        if generatedAt.timeIntervalSince(now) > Self.futureTolerance {
            return .invalidFuture
        }
        if now.timeIntervalSince(generatedAt) > Self.freshnessInterval {
            return .stale
        }
        return .fresh
    }

    /// Produces one bounded, single-line title. Whitespace runs collapse,
    /// control/bidi characters become spaces and the result is truncated by
    /// grapheme cluster, so a snapshot row can never inject line breaks or
    /// grow the file unexpectedly.
    public static func sanitizedTitle(_ raw: String) -> String {
        var cleaned = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            if CharacterSet.newlines.contains(scalar)
                || CharacterSet.controlCharacters.contains(scalar)
                || forbiddenTitleScalars.contains(scalar) {
                cleaned.append(" ")
            } else {
                cleaned.append(scalar)
            }
        }
        let collapsed = String(cleaned)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return String(collapsed.prefix(maximumTitleCharacters))
            .trimmingCharacters(in: .whitespaces)
    }

    private static let forbiddenTitleScalars: Set<Unicode.Scalar> = [
        Unicode.Scalar(0x202A)!, Unicode.Scalar(0x202B)!, Unicode.Scalar(0x202C)!,
        Unicode.Scalar(0x202D)!, Unicode.Scalar(0x202E)!,
        Unicode.Scalar(0x2066)!, Unicode.Scalar(0x2067)!, Unicode.Scalar(0x2068)!,
        Unicode.Scalar(0x2069)!
    ]

    private static func validateTitleScalars(_ title: String) throws {
        for scalar in title.unicodeScalars {
            if CharacterSet.newlines.contains(scalar)
                || CharacterSet.controlCharacters.contains(scalar)
                || forbiddenTitleScalars.contains(scalar) {
                throw WidgetTaskSnapshotError.invalidTitle
            }
        }
    }
}

public enum WidgetTaskSnapshotError: Error, Equatable, Sendable {
    case unsupportedSchema(Int)
    case tooManyTasks
    case duplicateTaskID
    case duplicateRunID
    case titleTooLong
    case invalidTitle
    case invalidDate
}

/// Result of reading the shared file. `missing` is the expected first-launch
/// state before the App has written anything; `invalid` never exposes partial
/// data to the widget.
public enum WidgetTaskSnapshotLoadResult: Equatable, Sendable {
    case fresh(WidgetTaskSnapshot)
    case stale(WidgetTaskSnapshot)
    case missing
    case unavailable
    case invalid(WidgetTaskSnapshotStoreError)
}

public enum WidgetTaskSnapshotStoreError: Error, Equatable, Sendable {
    case appGroupUnavailable
    case unsafePath
    case readFailed
    case writeFailed
    case tooLarge
    case malformed
    case invalidSnapshot(WidgetTaskSnapshotError)
}

/// File-backed snapshot store shared by the App and the widget extension.
///
/// The App is the only writer. Writes are staged in the destination directory
/// and atomically replace `tasks.json`, so a reader either sees the previous
/// complete file or the new complete file. A failed write leaves the previous
/// valid snapshot untouched; the caller must surface the failure.
public struct WidgetTaskSnapshotStore: Sendable {
    public static let appGroupIdentifier = FloeL10n.appGroupIdentifier
    public static let directoryName = "WidgetSnapshot"
    public static let fileName = "tasks.json"

    /// App Group container root, or nil when the App Group is unavailable.
    public let containerURL: URL?

    public init(containerURL: URL?) {
        self.containerURL = containerURL
    }

    public static func appGroup(
        fileManager: FileManager = .default
    ) -> WidgetTaskSnapshotStore? {
        guard let container = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            return nil
        }
        return WidgetTaskSnapshotStore(containerURL: container)
    }

    public var directoryURL: URL? {
        containerURL?.appendingPathComponent(Self.directoryName, isDirectory: true)
    }

    public var snapshotURL: URL? {
        directoryURL?.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    // MARK: - Read

    public func load(now: Date = Date()) -> WidgetTaskSnapshotLoadResult {
        guard let directory = directoryURL, let url = snapshotURL else {
            return .unavailable
        }
        let fileManager = FileManager.default
        guard !Self.isSymbolicLink(directory) else {
            return .invalid(.unsafePath)
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
            return .missing
        }
        guard isDirectory.boolValue else {
            return .invalid(.unsafePath)
        }
        guard !Self.isSymbolicLink(url) else {
            return .invalid(.unsafePath)
        }
        guard fileManager.fileExists(atPath: url.path) else {
            return .missing
        }
        guard let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .fileSizeKey]
        ) else {
            return .invalid(.readFailed)
        }
        guard values.isRegularFile == true else {
            return .invalid(.unsafePath)
        }
        guard let size = values.fileSize, size > 0 else {
            return .invalid(.malformed)
        }
        guard size <= WidgetTaskSnapshot.maximumEncodedBytes else {
            return .invalid(.tooLarge)
        }
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              data.count <= WidgetTaskSnapshot.maximumEncodedBytes else {
            return .invalid(.readFailed)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        guard let snapshot = try? decoder.decode(WidgetTaskSnapshot.self, from: data) else {
            return .invalid(.malformed)
        }
        do {
            try snapshot.validate()
        } catch let error as WidgetTaskSnapshotError {
            return .invalid(.invalidSnapshot(error))
        } catch {
            return .invalid(.malformed)
        }
        switch snapshot.freshness(at: now) {
        case .fresh:
            return .fresh(snapshot)
        case .stale:
            return .stale(snapshot)
        case .invalidFuture:
            return .invalid(.invalidSnapshot(.invalidDate))
        }
    }

    // MARK: - Write

    public func write(_ snapshot: WidgetTaskSnapshot) throws {
        guard let directory = directoryURL, let destination = snapshotURL else {
            throw WidgetTaskSnapshotStoreError.appGroupUnavailable
        }
        try snapshot.validate()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(snapshot)
        } catch {
            throw WidgetTaskSnapshotStoreError.writeFailed
        }
        guard data.count <= WidgetTaskSnapshot.maximumEncodedBytes else {
            throw WidgetTaskSnapshotStoreError.tooLarge
        }

        let fileManager = FileManager.default
        guard !Self.isSymbolicLink(directory), !Self.isSymbolicLink(destination) else {
            throw WidgetTaskSnapshotStoreError.unsafePath
        }
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw WidgetTaskSnapshotStoreError.unsafePath
            }
        } else {
            do {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
            } catch {
                throw WidgetTaskSnapshotStoreError.writeFailed
            }
        }
        // Best effort for the directory; the file itself below must carry the
        // widget-appropriate protection.
        _ = try? Self.applyFileProtection(to: directory, fileManager: fileManager)

        if fileManager.fileExists(atPath: destination.path) {
            guard let values = try? destination.resourceValues(
                forKeys: [.isSymbolicLinkKey, .isRegularFileKey]
            ) else {
                throw WidgetTaskSnapshotStoreError.writeFailed
            }
            guard values.isSymbolicLink != true, values.isRegularFile == true else {
                throw WidgetTaskSnapshotStoreError.unsafePath
            }
        }

        // Same-directory staging keeps the final rename/replace atomic and
        // avoids a cross-volume copy. The dot prefix keeps a crashed stage out
        // of any directory listing; it is removed by the defer below.
        let staged = directory.appendingPathComponent(
            ".tasks-\(UUID().uuidString).tmp",
            isDirectory: false
        )
        defer { try? fileManager.removeItem(at: staged) }
        do {
            try data.write(to: staged)
            try Self.applyFileProtection(to: staged, fileManager: fileManager)
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: staged)
            } else {
                try fileManager.moveItem(at: staged, to: destination)
            }
            // The staged file already carries the protection; replacing can
            // preserve destination metadata, so reapply best-effort without
            // turning a completed replacement into a false failure.
            _ = try? Self.applyFileProtection(to: destination, fileManager: fileManager)
        } catch let error as WidgetTaskSnapshotStoreError {
            throw error
        } catch {
            throw WidgetTaskSnapshotStoreError.writeFailed
        }
    }

    // MARK: - Filesystem helpers

    private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }

    /// The widget must be readable after the first unlock while the device is
    /// locked; `completeUntilFirstUserAuthentication` is the appropriate
    /// protection for a system widget container.
    private static func applyFileProtection(
        to url: URL,
        fileManager: FileManager
    ) throws {
        #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        #if targetEnvironment(simulator)
        // The Simulator runs on the host filesystem, which does not implement
        // iOS data protection. A write must not fail for an unsupported
        // attribute there; device builds still enforce it below.
        _ = try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #else
        try fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        #endif
        #endif
    }
}
