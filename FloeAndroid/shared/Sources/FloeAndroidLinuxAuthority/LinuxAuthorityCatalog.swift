// SPDX-License-Identifier: MPL-2.0
//
// G03-R2 addendum — bounded environment-catalog enumeration (`listPage`).
//
// The measured Full1.0.12/code120 failure was a REAL native refusal:
// `authority_replyTooLarge` from `LinuxAuthorityWire.encodeReply` because the
// frozen bare-string `list` result encodes EVERY sorted registry metadata row
// and the global JSON crossed the 65536-byte ceiling. The runtime's
// `environment.list` used to fetch that global reply and only then filter the
// requested project in Kotlin, so a large managed-project registry made the
// first-Send target resolver fail before it could see the project rows.
//
// This file adds the ADDITIVE bounded path; nothing here replaces or widens
// the legacy `list`/`handshake` shapes:
//
// - the trusted project selection (canonical UUID) is resolved to the SAME
//   workspace owner the ORIGINAL acquire path computes
//   (`sha256(canonical workspace path)`), and the ORIGINAL registry metadata
//   rows are filtered BEFORE wire encoding, so foreign projects/sessions never
//   enter a scoped reply;
// - rows keep the legacy order (ascending record id), which is exactly the
//   order the legacy Kotlin filter preserved;
// - a page never exceeds the frozen 65536-byte reply ceiling. Byte fitting
//   only ever REMOVES complete trailing rows and then reports the exact next
//   cursor; a page that cannot fit even one complete row is an explicit
//   `replyTooLarge` failure (never an empty successful partial catalog);
// - the cursor binds the scoped inventory snapshot (row contents + count +
//   base revision + scope). Any inventory change between pages is a typed
//   `catalogChanged` retryable refusal; stale cursors can never mix snapshots,
//   duplicate rows or skip rows;
// - metadata only: no layer paths, variable maps, process data or credentials.

import Foundation
import FloeCore
import FloeEnvironments

/// Which registry rows a metadata enumeration may expose. The project case
/// carries the DERIVED workspace owner id (a sha256 hex digest), never a path.
enum LinuxAuthorityCatalogScope: Equatable {
    case all
    case project(projectID: UUID, workspaceOwnerID: String)

    /// Scope binding inside the cursor fingerprint: a cursor minted for one
    /// scope can never validate against another (even if the row sets happen
    /// to be identical).
    var token: String {
        switch self {
        case .all:
            return "all"
        case .project(let projectID, let owner):
            return "project:" + projectID.uuidString + ":" + owner
        }
    }

    /// Frozen reply discriminant ("all" | "project").
    var wireName: String {
        switch self {
        case .all: return "all"
        case .project: return "project"
        }
    }

    var projectID: UUID? {
        if case .project(let projectID, _) = self { return projectID }
        return nil
    }

    var workspaceOwnerID: String? {
        if case .project(_, let owner) = self { return owner }
        return nil
    }
}

/// Metadata projection + page sizing bounds shared by the authority and its
/// focused host regressions.
enum LinuxAuthorityCatalog {
    /// Hard per-request row ceiling. The wire ceiling remains the real bound;
    /// this only bounds one request's work.
    static let maximumRowsPerPage = 200
    /// Default when the caller omits `limit`.
    static let defaultRowsPerPage = 100

    /// Projects registry records into the FROZEN metadata shape. This is the
    /// single projection used by BOTH the legacy `list` and the new
    /// `listPage`, so the two can never drift.
    ///
    /// Order is ascending record id (the legacy `list` order). Project scope
    /// reproduces the ORIGINAL Kotlin filter exactly: project rows whose
    /// registry owner is the derived workspace digest, plus session rows whose
    /// `parentID` is one of those project ids. No other kind is exposed by a
    /// scoped read.
    static func rows(_ records: [ContainerRecord],
                     scope: LinuxAuthorityCatalogScope) -> [LinuxAuthorityEnvironmentMetadata] {
        let sorted = records.sorted { $0.id < $1.id }
        let metadata = sorted.map(metadata)
        switch scope {
        case .all:
            return metadata
        case .project(_, let owner):
            let projectIDs = Set(metadata
                .filter { $0.kind == ContainerKind.project.rawValue && $0.ownerID == owner }
                .map(\.id))
            return metadata.filter { row in
                if row.kind == ContainerKind.project.rawValue {
                    return row.ownerID == owner
                }
                if row.kind == ContainerKind.session.rawValue, let parent = row.parentID {
                    return projectIDs.contains(parent)
                }
                return false
            }
        }
    }

    static func metadata(_ record: ContainerRecord) -> LinuxAuthorityEnvironmentMetadata {
        LinuxAuthorityEnvironmentMetadata(
            id: record.id,
            kind: record.kind.rawValue,
            ownerID: record.ownerID,
            name: record.name,
            state: record.state.rawValue,
            baseRevision: record.baseRevision,
            requiresRebuild: record.requiresRebuild,
            rebuildReason: record.rebuildReason,
            executionBackend: record.executionBackend?.rawValue,
            bytes: record.bytes,
            packageCount: record.packageCount,
            parentID: record.parentID,
            templateID: record.templateID,
            layerFormat: record.layerFormat
        )
    }
}

/// Opaque, strictly validated continuation cursor.
///
/// Wire form: `v1.<64 lowercase sha256 hex>.<decimal offset>` (at most 78
/// bytes). The digest is a scope-bound snapshot fingerprint over every row a
/// scoped enumeration can return; the offset is the index of the next row in
/// that filtered, id-sorted inventory. Both fields are re-derived on every
/// page request, so a forged/stale/mixed cursor fails closed instead of
/// duplicating or skipping rows.
enum LinuxAuthorityCatalogCursor {
    static let versionToken = "v1"
    static let maximumBytes = 96
    static let fingerprintHexLength = 64

    struct Decoded: Equatable {
        var fingerprint: String
        var offset: Int
    }

    static func encode(fingerprint: String, offset: Int) -> String {
        versionToken + "." + fingerprint + "." + String(offset)
    }

    /// Strict shape gate: exact version token, exactly 64 lowercase hex
    /// characters, a decimal offset without sign/whitespace/leading zeros and
    /// a bounded total length. Returns nil for ANY deviation (callers map that
    /// to `invalidWire`).
    static func decode(_ raw: String) -> Decoded? {
        guard !raw.isEmpty, raw.utf8.count <= maximumBytes else { return nil }
        let pieces = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 3, pieces[0] == Substring(versionToken) else { return nil }
        let fingerprint = String(pieces[1])
        guard fingerprint.utf8.count == fingerprintHexLength,
              fingerprint.unicodeScalars.allSatisfy({ isLowercaseHexDigit($0.value) }) else { return nil }
        let digits = String(pieces[2])
        guard !digits.isEmpty, digits.utf8.count <= 10,
              digits.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }),
              digits == "0" || !digits.hasPrefix("0"),
              let offset = Int(digits) else { return nil }
        return Decoded(fingerprint: fingerprint, offset: offset)
    }

    /// Deterministic scope-bound snapshot fingerprint. Length-prefixed row
    /// JSON removes any ambiguity between fields/rows; sorted keys keep the
    /// bytes identical across processes and restarts. Foreign (out-of-scope)
    /// rows are not part of the preimage, so an unrelated project's change
    /// never invalidates a scoped cursor.
    static func fingerprint(scope: LinuxAuthorityCatalogScope,
                            baseRevision: String,
                            rows: [LinuxAuthorityEnvironmentMetadata]) -> String {
        var preimage = Data("floe-android-authority-catalog-v1\n".utf8)
        preimage.append(Data((scope.token + "\n").utf8))
        preimage.append(Data((baseRevision + "\n").utf8))
        preimage.append(Data("\(rows.count)\n".utf8))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for row in rows {
            if let data = try? encoder.encode(row) {
                preimage.append(Data("\(data.count):".utf8))
                preimage.append(data)
            } else {
                // Unreachable for the frozen metadata struct (every field is a
                // JSON-safe scalar). Keeps the fingerprint total and
                // deterministic: the same value fails the same way.
                preimage.append(Data("!:".utf8))
            }
            preimage.append(Data("\n".utf8))
        }
        return FloeDigest.sha256Hex(preimage)
    }

    private static func isLowercaseHexDigit(_ value: UInt32) -> Bool {
        (value >= 48 && value <= 57) || (value >= 97 && value <= 102)
    }
}

/// Builds the largest coherent page that fits the frozen reply ceiling.
enum LinuxAuthorityCatalogPageBuilder {
    /// Fitting is measured against the WORST-CASE request id (64 quote
    /// characters escape to 130 JSON bytes), so the later reply encoding with
    /// the caller's REAL (≤64-byte, control-character-free) request id can
    /// never grow the envelope past the ceiling.
    private static let worstCaseRequestID = String(repeating: "\"", count: LinuxAuthorityWire.maximumRequestIDBytes)

    static func page(scope: LinuxAuthorityCatalogScope,
                     baseRevision: String,
                     fingerprint: String,
                     rows: [LinuxAuthorityEnvironmentMetadata],
                     offset: Int,
                     limit: Int) throws -> LinuxAuthorityEnvironmentPage {
        let total = rows.count
        precondition(offset >= 0 && offset <= total, "catalog page offset outside the filtered inventory")
        precondition(limit >= 1 && limit <= LinuxAuthorityCatalog.maximumRowsPerPage,
                     "catalog page limit outside the bounded range")
        let available = min(limit, total - offset)
        if available == 0 {
            return pageValue(scope: scope, baseRevision: baseRevision, rows: [],
                             nextCursor: nil, total: total)
        }

        func fits(_ count: Int) -> Bool {
            let end = offset + count
            let next = end < total ? LinuxAuthorityCatalogCursor.encode(fingerprint: fingerprint, offset: end) : nil
            let candidate = pageValue(scope: scope, baseRevision: baseRevision,
                                      rows: Array(rows[offset..<end]), nextCursor: next, total: total)
            let reply = LinuxAuthorityReply(version: LinuxAuthorityWire.version,
                                            requestID: worstCaseRequestID,
                                            outcome: .ok(.listPage(candidate)))
            return LinuxAuthorityWire.encodeReplyData(reply) != nil
        }

        // Largest complete-row count that fits. Row bytes dominate, so the
        // predicate is monotonic except for the terminal page where the cursor
        // disappears; the full-page fast path and the upward extension below
        // handle that case exactly.
        var best = 0
        if fits(available) {
            best = available
        } else {
            var low = 1
            var high = available - 1
            while low <= high {
                let mid = (low + high) / 2
                if fits(mid) {
                    best = mid
                    low = mid + 1
                } else {
                    high = mid - 1
                }
            }
            while best < available && fits(best + 1) { best += 1 }
        }
        guard best > 0 else {
            // NOT an empty success: one complete row cannot fit the ceiling.
            throw LinuxAuthorityError(
                code: .replyTooLarge,
                message: "the environment catalog page cannot fit one complete row within the 65536-byte wire ceiling; no row was dropped or truncated")
        }
        let end = offset + best
        let next = end < total ? LinuxAuthorityCatalogCursor.encode(fingerprint: fingerprint, offset: end) : nil
        return pageValue(scope: scope, baseRevision: baseRevision,
                         rows: Array(rows[offset..<end]), nextCursor: next, total: total)
    }

    private static func pageValue(scope: LinuxAuthorityCatalogScope,
                                  baseRevision: String,
                                  rows: [LinuxAuthorityEnvironmentMetadata],
                                  nextCursor: String?,
                                  total: Int) -> LinuxAuthorityEnvironmentPage {
        LinuxAuthorityEnvironmentPage(
            baseRevision: baseRevision,
            environments: rows,
            nextCursor: nextCursor,
            projectID: scope.projectID?.uuidString,
            workspaceOwnerID: scope.workspaceOwnerID,
            scope: scope.wireName,
            total: total
        )
    }
}
