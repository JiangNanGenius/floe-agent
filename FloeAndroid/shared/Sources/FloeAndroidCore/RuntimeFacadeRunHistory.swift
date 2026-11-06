// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloePersistence
import FloeModels

extension FacadeRunDomain {
    /// A cold/retired run has no live pump window. Read its actual journal,
    /// without attaching a producer or changing its authoritative state.
    public func eventHistory(envelope: RunCommandEnvelope) async -> RunDomainReply {
        let owner: OwnerIdentity
        let before: Int?
        let limit: Int
        do {
            owner = try envelope.requireTaskAndRun()
            let payload = try RunPayloadReader.Object(
                envelope.payloadValue ?? .object([:]), allowed: ["beforeSequence", "limit"])
            limit = Int(try payload.integer("limit", min: 1, max: 100))
            if case .object(let fields)? = envelope.payloadValue,
               fields["beforeSequence"] != nil {
                before = Int(try payload.integer("beforeSequence", min: 1, max: 1 << 40))
            } else { before = nil }
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
            func page() -> SettingsDomainV1.JSONValue {
                .object([
                    "schema": .string(BridgeV3.commandSchema),
                    "taskID": .string(owner.taskID.uuidString),
                    "runID": .string(owner.runID.uuidString),
                    "events": .array(rows.map { row in .object([
                        "sequence": .integer(Int64(row.sequence)),
                        "kind": .string(row.kind.rawValue),
                        "createdAt": .integer(Int64(row.createdAt.timeIntervalSince1970 * 1000)),
                        "payload": .string(row.payloadJSON),
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
            guard bytes <= RunDomainLimits.pageBudgetBytes else {
                // No zero-progress cursor or silently clipped payload.
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
