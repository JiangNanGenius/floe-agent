// SPDX-License-Identifier: MPL-2.0
import Foundation
import Crypto
import FloePersistence
import FloeModels

extension FacadeRunDomain {
    /// A cold/retired run has no live pump window. Read its actual journal,
    /// without attaching a producer or changing its authoritative state.
    public func eventHistory(envelope: RunCommandEnvelope) async -> RunDomainReply {
        let owner: OwnerIdentity
        let before: Int?
        let limit: Int
        let slice: (sequence: Int, offset: Int, digest: String)?
        do {
            owner = try envelope.requireTaskAndRun()
            let payload = try RunPayloadReader.Object(
                envelope.payloadValue ?? .object([:]),
                allowed: ["beforeSequence", "limit", "payloadSequence", "payloadOffset", "payloadDigest"])
            limit = Int(try payload.integer("limit", min: 1, max: 100))
            if case .object(let fields)? = envelope.payloadValue,
               fields["beforeSequence"] != nil {
                before = Int(try payload.integer("beforeSequence", min: 1, max: 1 << 40))
            } else { before = nil }
            if case .object(let fields)? = envelope.payloadValue,
               fields["payloadSequence"] != nil || fields["payloadOffset"] != nil || fields["payloadDigest"] != nil {
                guard before == nil, limit == 1,
                      case .string(let digest)? = fields["payloadDigest"],
                      digest.count == 64,
                      digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                    return RunDomainReply(.rejected(RunDomainError(.invalidState, .payloadInvalid)))
                }
                slice = (Int(try payload.integer("payloadSequence", min: 1, max: 1 << 40)),
                         Int(try payload.integer("payloadOffset", min: 0, max: Int64(RunHistoryPayload.maximumBytes))),
                         digest)
            } else { slice = nil }
        } catch let error as RunDomainError { return RunDomainReply(.rejected(error)) }
        catch { return RunDomainReply(.rejected(RunDomainError(.invalidState, .payloadInvalid))) }

        var stores = owners[owner.runID]?.bundle
        if stores == nil, let route = await TemporaryLiveRouting.route(
            epoch: epoch, conversationID: owner.taskID) { stores = route.runBundle }
        let bundle = stores ?? components.durable
        do {
            guard let record = try await bundle.runs.run(id: owner.runID),
                  record.conversationID == owner.taskID else {
                return RunDomainReply(.rejected(RunDomainError(.notFound, .runMissing)))
            }
            if let slice {
                // Journal rows are append-only, but every slice still checks
                // current task/run ownership, row identity and stored digest.
                let found = try await bundle.runs.earlierEvents(
                    runID: owner.runID, beforeSequence: slice.sequence + 1, limit: 1)
                guard let row = found.first, row.sequence == slice.sequence else {
                    return RunDomainReply(.rejected(RunDomainError(.notFound, .runMissing)))
                }
                guard let value = RunHistoryPayload.slice(
                    row: row, taskID: owner.taskID, runID: owner.runID,
                    offset: slice.offset, digest: slice.digest) else {
                    return RunDomainReply(.rejected(RunDomainError(.invalidState, .payloadInvalid)))
                }
                let bytes = FacadeFrameBudget.serializedBytes(FacadeRunDomain.unwrap(value))
                guard bytes <= RunDomainLimits.pageBudgetBytes else {
                    return RunDomainReply(.rejected(RunDomainError(.payloadTooLarge, .payloadTooLarge)))
                }
                return RunDomainReply(.completedPage(
                    page: RunTypedPage(object: value, pageBytes: bytes), nextCursor: nil))
            }
            // One look-behind row proves hasEarlier, rather than assuming
            // that a nonzero sequence means there must be older records.
            let fetched: [RunEventRecord]
            if let before {
                fetched = try await bundle.runs.earlierEvents(
                    runID: owner.runID, beforeSequence: before, limit: limit + 1)
            } else {
                fetched = try await bundle.runs.recentEvents(runID: owner.runID, limit: limit + 1)
            }
            var rows = Array(fetched.suffix(limit))
            var referencedPayload = false
            func page() -> SettingsDomainV1.JSONValue {
                .object([
                    "schema": .string(BridgeV3.commandSchema),
                    "taskID": .string(owner.taskID.uuidString),
                    "runID": .string(owner.runID.uuidString),
                    "events": .array(rows.map { row in .object([
                        "sequence": .integer(Int64(row.sequence)),
                        "kind": .string(row.kind.rawValue),
                        "createdAt": .integer(Int64(row.createdAt.timeIntervalSince1970 * 1000)),
                        "payload": referencedPayload ? .null : .string(row.payloadJSON),
                        "payloadReference": referencedPayload ? RunHistoryPayload.reference(row: row) : .null,
                    ]) }),
                    "hasEarlier": .boolean(fetched.count > rows.count),
                    "firstSequence": rows.first.map { .integer(Int64($0.sequence)) } ?? .null,
                ])
            }
            var value = page()
            var bytes = FacadeFrameBudget.serializedBytes(FacadeRunDomain.unwrap(value))
            while bytes > RunDomainLimits.pageBudgetBytes, rows.count > 1 {
                rows.removeFirst()
                value = page(); bytes = FacadeFrameBudget.serializedBytes(FacadeRunDomain.unwrap(value))
            }
            if bytes > RunDomainLimits.pageBudgetBytes, let row = rows.first,
               row.payloadJSON.utf8.count <= RunHistoryPayload.maximumBytes {
                // Retain the actual event identity/cursor. The App materializes
                // this ONE payload through bounded owned reads before replay.
                referencedPayload = true
                value = page(); bytes = FacadeFrameBudget.serializedBytes(FacadeRunDomain.unwrap(value))
            }
            guard bytes <= RunDomainLimits.pageBudgetBytes else {
                // Same 4 MiB materialization ceiling as the existing content
                // reader. Larger records remain available in complete export.
                return RunDomainReply(.rejected(RunDomainError(.payloadTooLarge, .payloadTooLarge)))
            }
            return RunDomainReply(.completedPage(
                page: RunTypedPage(object: value, pageBytes: bytes),
                nextCursor: fetched.count > rows.count ? rows.first.map { String($0.sequence) } : nil))
        } catch {
            return RunDomainReply(.rejected(RunDomainError(.persistenceUnavailable, .storeReadFailed)))
        }
    }
}

/// Stateless journal continuation; never publishes a message-bound handle or
/// stores a second copy beyond the existing persisted/RAM run store.
enum RunHistoryPayload {
    static let maximumBytes = 4 * 1024 * 1024
    static let chunkBytes = 32 * 1024

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func reference(row: RunEventRecord) -> SettingsDomainV1.JSONValue {
        let data = Data(row.payloadJSON.utf8)
        return .object([
            "sequence": .integer(Int64(row.sequence)),
            "totalBytes": .integer(Int64(data.count)),
            "sha256": .string(digest(data)),
        ])
    }

    static func slice(row: RunEventRecord, taskID: UUID, runID: UUID,
                      offset: Int, digest expectedDigest: String) -> SettingsDomainV1.JSONValue? {
        let data = Data(row.payloadJSON.utf8)
        guard !data.isEmpty, data.count <= maximumBytes,
              offset >= 0, offset < data.count, digest(data) == expectedDigest else { return nil }
        let end = min(data.count, offset + chunkBytes)
        // URL-safe base64 never grows through JSON slash escaping. Slice at
        // byte offsets and decode UTF-8 only after complete digest validation.
        let encoded = data.subdata(in: offset..<end).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        return .object([
            "schema": .string(BridgeV3.commandSchema),
            "taskID": .string(taskID.uuidString), "runID": .string(runID.uuidString),
            "payloadSlice": .object([
                "sequence": .integer(Int64(row.sequence)), "kind": .string(row.kind.rawValue),
                "sha256": .string(expectedDigest), "totalBytes": .integer(Int64(data.count)),
                "offset": .integer(Int64(offset)), "base64": .string(encoded),
                "nextOffset": end < data.count ? .integer(Int64(end)) : .null,
            ]),
        ])
    }
}
