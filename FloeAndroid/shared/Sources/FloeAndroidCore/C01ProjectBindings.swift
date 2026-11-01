// SPDX-License-Identifier: MPL-2.0
//
// C01ProjectBindings — the closed APPEND-ONLY bridge surface for the real
// user project library.
//
// Six applicationConfiguration commands under the existing `projects`
// configuration label (Main must add the same six tuples to the Swift and
// Kotlin BridgeV3 matrices and the golden matrix; this file registers the
// processors, never a matrix entry):
//
//   project.list    {limit?, offset?}                      stateless
//   project.get     {projectID}                            stateless
//   project.create  {name}                    createIntent
//   project.rename  {projectID, name}         outer revision
//   project.assign  {projectID, conversationID} outer revision
//   project.delete  {projectID, deleteRoot?, stopActiveTasks?} outer revision
//
// The outer revision is ALWAYS `project.<uuid>` with the exact persisted
// `workspaces.updated_at` version. Neither envelope nor payload can carry a
// root, bookmark, URI, environment, run, permission or absolute path.
//
// This source is source-only and NOT compiled/executed by the authoring
// package. Main owns the central DI/registration patch.
import Foundation
#if canImport(CoreFoundation)
import CoreFoundation
#endif
import FloeCore
import FloePersistence

public enum C01ProjectBindings {
    public static let configurationScope = "projects"

    public struct CommandSpec: Sendable, Equatable {
        public let name: String
        public let revisionRequired: Bool
        public let createIntent: Bool

        public init(name: String, revisionRequired: Bool = false,
                    createIntent: Bool = false) {
            self.name = name
            self.revisionRequired = revisionRequired
            self.createIntent = createIntent
        }
    }

    /// The exact closed six-command append. Order is stable for Main's
    /// matrix/golden patch and for deterministic tests.
    public static let commands: [CommandSpec] = [
        CommandSpec(name: "project.list"),
        CommandSpec(name: "project.get"),
        CommandSpec(name: "project.create", createIntent: true),
        CommandSpec(name: "project.rename", revisionRequired: true),
        CommandSpec(name: "project.assign", revisionRequired: true),
        CommandSpec(name: "project.delete", revisionRequired: true),
    ]

    /// Registers the synchronous submit handlers and async processors for
    /// this exact epoch. Returns the exact keys installed; Main appends them
    /// to `registeredHandlerKeys` for the existing retirement path.
    @discardableResult
    public static func install(epoch: UInt64,
                               library: C01ProjectLibrary,
                               registry: RuntimeDomainRegistry) -> [String] {
        var keys: [String] = []
        for spec in commands {
            let key = BridgeV3.handlerKey(scope: .applicationConfiguration,
                                          command: spec.name)
            G02DomainBinder.registerSubmitHandler(
                scope: .applicationConfiguration, command: spec.name,
                configurationScope: configurationScope)
            G02DomainBinder.registerProcessor(registry, handlerKey: key) { job in
                await handle(job: job, epoch: epoch, library: library)
            }
            keys.append(key)
        }
        return keys
    }

    // MARK: - Handler

    static func handle(job: RuntimeCommandEnvelopeJob, epoch: UInt64,
                       library: C01ProjectLibrary) async -> RuntimeCommandResult {
        guard library.epoch == epoch else {
            return G02DomainBinder.wireError("retired", reason: nil)
        }
        guard let object = G02DomainBinder.parseObject(job.envelope) else {
            return G02DomainBinder.internalError()
        }
        do {
            switch job.command {
            case "project.list":
                let query = try ProjectListQuery.parse(object["payload"])
                let rows = try await library.list(limit: query.limit,
                                                  offset: query.offset)
                return G02DomainBinder.completedWireObject([
                    "projects": rows.map(projectWire),
                    "hasMore": rows.count == query.limit,
                ])
            case "project.get":
                let request = try ProjectGetRequest.parse(object["payload"])
                let detail = try await library.get(projectID: request.projectID)
                return G02DomainBinder.completedWireObject(detailWire(detail))
            case "project.create":
                let request = try ProjectCreateRequest.parse(object["payload"])
                let created = try await library.create(name: request.name)
                return G02DomainBinder.completedWireObject([
                    "project": projectWire(created),
                ])
            case "project.rename":
                let request = try ProjectRenameRequest.parse(object["payload"])
                let revision = try revisionVersion(
                    object["revision"], projectID: request.projectID)
                let renamed = try await library.rename(
                    projectID: request.projectID, name: request.name,
                    expectedRevision: revision)
                return G02DomainBinder.completedWireObject([
                    "project": projectWire(renamed),
                ])
            case "project.assign":
                let request = try ProjectAssignRequest.parse(object["payload"])
                let revision = try revisionVersion(
                    object["revision"], projectID: request.projectID)
                let receipt = try await library.assign(
                    projectID: request.projectID,
                    conversationID: request.conversationID,
                    expectedRevision: revision)
                return G02DomainBinder.completedWireObject([
                    "projectID": receipt.projectID.uuidString,
                    "conversationID": receipt.conversationID.uuidString,
                    "revision": receipt.revision,
                    "assigned": true,
                    "alreadyAssigned": receipt.alreadyAssigned,
                    "filesMoved": false,
                    "fenceSettled": receipt.fenceSettled,
                ])
            case "project.delete":
                let request = try ProjectDeleteRequest.parse(object["payload"])
                let revision = try revisionVersion(
                    object["revision"], projectID: request.projectID)
                let receipt = try await library.delete(
                    projectID: request.projectID,
                    expectedRevision: revision,
                    deleteRoot: request.deleteRoot,
                    stopActiveTasks: request.stopActiveTasks)
                var wire: [String: Any] = [
                    "projectID": receipt.projectID.uuidString,
                    "deleted": true,
                    "rootRetained": receipt.rootRetained,
                    "fencesSettled": receipt.fencesSettled,
                ]
                if let retained = receipt.retainedRelativeRoot {
                    wire["retainedRelativeRoot"] = retained
                }
                if let removal = receipt.rootRemoval {
                    switch removal {
                    case .removed:
                        wire["rootRemoval"] = "removed"
                    case .absent:
                        wire["rootRemoval"] = "absent"
                    case .failed(let reason):
                        wire["rootRemoval"] = "failed"
                        wire["rootRemoveError"] = reason
                    }
                }
                return G02DomainBinder.completedWireObject(wire)
            default:
                return G02DomainBinder.wireError("invalidPayload",
                                                 reason: "unknownProjectCommand")
            }
        } catch let error as C01ProjectError {
            return G02DomainBinder.wireError(error.wireCode,
                                             reason: error.wireReason)
        } catch {
            return G02DomainBinder.internalError()
        }
    }

    // MARK: - Closed payload grammar

    private struct ProjectListQuery {
        var limit = C01ProjectLibrary.defaultPageLimit
        var offset = 0

        static func parse(_ raw: Any?) throws -> ProjectListQuery {
            guard let raw else { return ProjectListQuery() }
            let object = try closedObject(raw, allowed: ["limit", "offset"])
            var query = ProjectListQuery()
            if let value = object["limit"] {
                query.limit = try boundedInteger(value, name: "limit",
                                                 minimum: 1,
                                                 maximum: C01ProjectLibrary.maximumPageLimit)
            }
            if let value = object["offset"] {
                query.offset = try boundedInteger(value, name: "offset",
                                                  minimum: 0, maximum: 100_000)
            }
            return query
        }
    }

    private struct ProjectGetRequest {
        let projectID: UUID
        static func parse(_ raw: Any?) throws -> ProjectGetRequest {
            let object = try closedObject(raw, allowed: ["projectID"])
            return ProjectGetRequest(projectID: try uuidValue(object["projectID"],
                                                               name: "projectID"))
        }
    }

    private struct ProjectCreateRequest {
        let name: String
        static func parse(_ raw: Any?) throws -> ProjectCreateRequest {
            let object = try closedObject(raw, allowed: ["name"])
            return ProjectCreateRequest(name: try nameValue(object["name"]))
        }
    }

    private struct ProjectRenameRequest {
        let projectID: UUID
        let name: String
        static func parse(_ raw: Any?) throws -> ProjectRenameRequest {
            let object = try closedObject(raw, allowed: ["projectID", "name"])
            return ProjectRenameRequest(
                projectID: try uuidValue(object["projectID"], name: "projectID"),
                name: try nameValue(object["name"]))
        }
    }

    private struct ProjectAssignRequest {
        let projectID: UUID
        let conversationID: UUID
        static func parse(_ raw: Any?) throws -> ProjectAssignRequest {
            let object = try closedObject(raw, allowed: ["projectID", "conversationID"])
            return ProjectAssignRequest(
                projectID: try uuidValue(object["projectID"], name: "projectID"),
                conversationID: try uuidValue(object["conversationID"],
                                               name: "conversationID"))
        }
    }

    private struct ProjectDeleteRequest {
        let projectID: UUID
        let deleteRoot: Bool
        let stopActiveTasks: Bool
        static func parse(_ raw: Any?) throws -> ProjectDeleteRequest {
            let object = try closedObject(raw, allowed: [
                "projectID", "deleteRoot", "stopActiveTasks",
            ])
            return ProjectDeleteRequest(
                projectID: try uuidValue(object["projectID"], name: "projectID"),
                deleteRoot: (try boolValue(object["deleteRoot"], name: "deleteRoot")) ?? false,
                stopActiveTasks: (try boolValue(object["stopActiveTasks"],
                                                name: "stopActiveTasks")) ?? false)
        }
    }

    // MARK: - Wire helpers

    private static func projectWire(_ project: C01ProjectRow) -> [String: Any] {
        [
            "projectID": project.id.uuidString,
            "name": project.name,
            "revision": project.revision,
            "createdAt": project.createdAtRaw,
            "updatedAt": project.updatedAtRaw,
            "taskCount": project.taskCount,
        ]
    }

    private static func detailWire(_ detail: C01ProjectDetail) -> [String: Any] {
        var wire = projectWire(detail.project)
        wire["rootState"] = detail.rootState.wireValue
        if let issue = detail.rootState.issue { wire["rootIssue"] = issue }
        wire["tasks"] = detail.tasks.map { task -> [String: Any] in
            [
                "conversationID": task.id.uuidString,
                "title": task.title,
                "purpose": task.purpose,
                "updatedAt": task.updatedAtRaw,
                "pinned": task.isPinned,
                "archived": task.isArchived,
            ]
        }
        wire["tasksTruncated"] = detail.tasksTruncated
        return wire
    }

    private static func revisionVersion(_ raw: Any?, projectID: UUID) throws -> String {
        guard let revision = raw as? [String: Any],
              let resourceID = revision["resourceID"] as? String,
              let version = revision["version"] as? String else {
            throw C01ProjectError.invalidPayload("missingProjectRevision")
        }
        let prefix = "project."
        guard resourceID.hasPrefix(prefix),
              let parsed = UUID(uuidString: String(resourceID.dropFirst(prefix.count))),
              parsed == projectID else {
            throw C01ProjectError.invalidPayload("projectRevisionResource")
        }
        guard !version.isEmpty, version.utf8.count <= 256 else {
            throw C01ProjectError.invalidPayload("projectRevisionVersion")
        }
        return version
    }

    private static func closedObject(_ raw: Any?, allowed: Set<String>) throws
        -> [String: Any] {
        guard let raw else { return [:] }
        guard let object = raw as? [String: Any] else {
            throw C01ProjectError.invalidPayload("invalidPayload")
        }
        guard Set(object.keys).isSubset(of: allowed) else {
            throw C01ProjectError.invalidPayload("unknownProjectField")
        }
        return object
    }

    private static func uuidValue(_ raw: Any?, name: String) throws -> UUID {
        guard let text = raw as? String, let value = UUID(uuidString: text),
              value.uuidString.caseInsensitiveCompare(text) == .orderedSame else {
            throw C01ProjectError.invalidPayload(name)
        }
        return value
    }

    private static func nameValue(_ raw: Any?) throws -> String {
        guard let text = raw as? String else {
            throw C01ProjectError.invalidPayload("name")
        }
        return text
    }

    private static func boolValue(_ raw: Any?, name: String) throws -> Bool? {
        guard let raw else { return nil }
        guard let number = raw as? NSNumber, isBoolean(number) else {
            throw C01ProjectError.invalidPayload(name)
        }
        return number.boolValue
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        #if canImport(CoreFoundation)
        return CFGetTypeID(number) == CFBooleanGetTypeID()
        #else
        let type = String(cString: number.objCType)
        return type == "c" || type == "B"
        #endif
    }

    private static func boundedInteger(_ raw: Any, name: String,
                                       minimum: Int, maximum: Int) throws -> Int {
        guard let number = raw as? NSNumber, !isBoolean(number) else {
            throw C01ProjectError.invalidPayload(name)
        }
        let type = String(cString: number.objCType)
        guard ["c", "i", "s", "l", "q", "C", "I", "S", "L", "Q"].contains(type) else {
            throw C01ProjectError.invalidPayload(name)
        }
        let value = number.intValue
        guard value >= minimum, value <= maximum,
              NSNumber(value: value) == number else {
            throw C01ProjectError.invalidPayload(name)
        }
        return value
    }
}
