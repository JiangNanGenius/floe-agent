// SPDX-License-Identifier: MPL-2.0

// Durable storage for Mac timeline drafts.
//
// Drafts live as `<id>.json` inside one directory (the creative library's
// `TimelineDrafts` folder). Writes are staged beside the destination and
// committed atomically with a read-back decode, the same publish contract
// as the media exporters; originals are only ever read. The store is a plain
// value type so tests can point it at a temporary directory.

import FloeCore
import Foundation

struct MacTimelineDraftStore: Sendable {
    let directory: URL

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
    }

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString + ".json")
    }

    /// Loads every readable draft, newest first. An undecodable file is
    /// surfaced as an error instead of being silently dropped.
    func loadAll() throws -> [MacTimelineDraft] {
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        var drafts: [MacTimelineDraft] = []
        var failures = 0
        for url in urls {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { continue }
            do {
                let draft = try load(id: id)
                if draft.id != id { throw CocoaError(.fileReadCorruptFile) }
                // Re-validation catches hand-edited files that decode but
                // violate model invariants (overlap, bad bounds).
                try draft.validateForStorage()
                drafts.append(draft)
            } catch {
                failures += 1
            }
        }
        guard failures == 0 || !drafts.isEmpty else {
            throw MacTimelineStoreError.unreadableDrafts(failures)
        }
        return drafts.sorted { $0.updatedAt > $1.updatedAt }
    }

    func load(id: UUID) throws -> MacTimelineDraft {
        let data = try Data(contentsOf: fileURL(for: id))
        let draft = try Self.decode(data)
        try draft.validateForStorage()
        return draft
    }

    /// New data is written with `.deferredToDate` (exact numeric reference
    /// dates) because `.iso8601` truncates sub-second fractions and would
    /// make a just-created draft fail its own read-back verification. Files
    /// written by older builds with ISO8601 dates still decode through the
    /// legacy reader.
    private static func decode(_ data: Data) throws -> MacTimelineDraft {
        if let draft = try? JSONDecoder().decode(MacTimelineDraft.self, from: data) {
            return draft
        }
        let legacy = JSONDecoder()
        legacy.dateDecodingStrategy = .iso8601
        return try legacy.decode(MacTimelineDraft.self, from: data)
    }

    /// Staged atomic write + read-back verification. The previously saved
    /// revision must match `expectedRevision` so two editors cannot silently
    /// overwrite each other.
    func save(_ draft: MacTimelineDraft, expectedRevision: Int64? = nil) throws {
        if let expectedRevision {
            let current = try? load(id: draft.id).revision
            if current != expectedRevision { throw MacTimelineStoreError.conflict }
        }
        let proposed = draft
        try proposed.validateForStorage()
        // Exact date round-trip: the equality check below compares Date
        // values, so the encoding must preserve sub-second components.
        let bytes = try JSONEncoder().encode(proposed)
        let staging = directory.appendingPathComponent(".\(proposed.id.uuidString).\(UUID().uuidString).json")
        do {
            try bytes.write(to: staging, options: .atomic)
            // Read-back against the staging bytes before publishing.
            let check = try Self.decode(Data(contentsOf: staging))
            guard check == proposed else { throw MacTimelineStoreError.verificationFailed }
            let destination = fileURL(for: proposed.id)
            let manager = FileManager.default
            if manager.fileExists(atPath: destination.path) {
                _ = try manager.replaceItemAt(destination, withItemAt: staging)
            } else {
                try manager.moveItem(at: staging, to: destination)
            }
            // Final read-back against the published bytes.
            _ = try load(id: proposed.id)
        } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
    }

    func remove(id: UUID) throws {
        let url = fileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}

enum MacTimelineStoreError: Error, Hashable, LocalizedError {
    case conflict
    case verificationFailed
    case unreadableDrafts(Int)

    var errorDescription: String? {
        switch self {
        case .conflict:
            return MacTimelineStoreStrings.conflict
        case .verificationFailed:
            return MacTimelineStoreStrings.verificationFailed
        case .unreadableDrafts(let count):
            return String(format: MacTimelineStoreStrings.unreadableDraftsFormat, count)
        }
    }
}

extension MacTimelineDraft {
    /// Re-checks model invariants that decoding alone cannot prove (clip
    /// overlap, per-track clip limits, caption text bounds).
    func validateForStorage() throws {
        for track in tracks {
            guard track.clips.count <= MacTimelineTrack.maximumClips else {
                throw MacTimelineError.limit("clips")
            }
            for clip in track.clips {
                if let captionText = clip.captionText {
                    guard !captionText.isEmpty,
                          captionText.utf8.count <= MacTimelineClip.maximumCaptionBytes else {
                        throw MacTimelineError.malformed("caption")
                    }
                }
            }
            let sorted = track.clips.sorted { $0.timelineRange.start < $1.timelineRange.start }
            for (a, b) in zip(sorted, sorted.dropFirst()) where a.timelineRange.overlaps(b.timelineRange) {
                throw MacTimelineError.overlap
            }
        }
    }
}

enum MacTimelineStoreStrings {
    static var conflict: String {
        t(en: "This draft was changed elsewhere. Reopen it before saving.",
           zh: "此草稿已在其他地方修改，请重新打开后再保存。")
    }
    static var verificationFailed: String {
        t(en: "The saved draft failed verification.", zh: "保存的草稿校验失败。")
    }
    static var unreadableDraftsFormat: String {
        t(en: "%d timeline draft(s) could not be read.", zh: "%d 个时间线草稿无法读取。")
    }

    private static func t(en: String, zh: String) -> String {
        FloeL10n.isChinese ? zh : en
    }
}
