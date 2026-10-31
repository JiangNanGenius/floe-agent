import XCTest
@testable import FloeAndroidCore

/// Host test source for the explicit bridge protocol v3 wire contract.
///
/// These tests are synthetic wire fixtures only: no task, provider, model,
/// conversation, credential, effect or run is executed. Every accepted
/// envelope terminates at a typed `runtimeUnavailable` seam unless the test
/// registers a controlled synthetic handler and unregisters it afterwards.
final class BridgeEnvelopeV3Tests: XCTestCase {
    private let task = UUID().uuidString
    private let run = UUID().uuidString
    private let env = UUID().uuidString
    private let job = UUID().uuidString
    private let zero = "00000000-0000-0000-0000-000000000000"

    // MARK: - Fixtures

    private func exchange(_ request: String) throws -> [String: Any] {
        let data = AndroidBridge.exchange(Data(request.utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func request(_ operation: String, _ body: String, id: String = "c-1") -> String {
        "{\"version\":3,\"requestID\":\"\(id)\",\"operation\":\"\(operation)\",\"envelope\":\(body)}"
    }

    private func envelope(schema: String? = BridgeV3.commandSchema,
                          scope: String,
                          configurationScope: String? = nil,
                          command: String,
                          stateful: Bool,
                          owner: String? = nil,
                          revision: String? = nil,
                          cursor: String? = nil,
                          grantID: String? = nil,
                          createIntent: Bool? = nil,
                          effect: String? = nil,
                          payload: String? = nil,
                          statefulLiteral: String? = nil,
                          correlation: String = "\"c-1\"") -> String {
        var parts: [String] = []
        if let schema { parts.append("\"schema\":\"\(schema)\"") }
        parts.append(contentsOf: [
            "\"scope\":\"\(scope)\"",
            "\"command\":\"\(command)\"",
            "\"stateful\":\(statefulLiteral ?? (stateful ? "true" : "false"))",
        ])
        if let configurationScope {
            parts.append("\"configurationScope\":\"\(configurationScope)\"")
        }
        if let owner { parts.append("\"owner\":\(owner)") }
        if let revision { parts.append("\"revision\":\(revision)") }
        if let cursor { parts.append("\"cursor\":\(cursor)") }
        if let grantID { parts.append("\"grantID\":\(grantID)") }
        if let createIntent { parts.append("\"createIntent\":\(createIntent)") }
        if let effect { parts.append("\"effect\":\(effect)") }
        if let payload { parts.append("\"payload\":\(payload)") }
        parts.append("\"correlationID\":\(correlation)")
        return "{" + parts.joined(separator: ",") + "}"
    }

    private func taskOwner(environment: String? = nil, job: String? = nil) -> String {
        var parts = ["\"taskID\":\"\(task)\"", "\"runID\":\"\(run)\""]
        if let environment { parts.append("\"environmentID\":\"\(environment)\"") }
        if let job { parts.append("\"jobID\":\"\(job)\"") }
        return "{" + parts.joined(separator: ",") + "}"
    }

    private func assertInvalid(_ response: [String: Any], _ reason: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(response["ok"] as? Bool, false, file: file, line: line)
        XCTAssertEqual(response["error"] as? String, "invalidEnvelope", file: file, line: line)
        XCTAssertEqual(response["reason"] as? String, reason, file: file, line: line)
    }

    private func assertUnbound(_ response: [String: Any], _ reason: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(response["ok"] as? Bool, false, file: file, line: line)
        XCTAssertEqual(response["error"] as? String, "runtimeUnavailable", file: file, line: line)
        XCTAssertEqual(response["reason"] as? String, reason, file: file, line: line)
        XCTAssertEqual(response["version"] as? Int, 3, file: file, line: line)
    }

    // MARK: - Negotiation

    func testHandshakeNegotiatesV3SchemasAndClaimsNoBusinessCapability() throws {
        let response = try exchange(#"{"version":3,"requestID":"h3","operation":"handshake"}"#)
        XCTAssertEqual(response["ok"] as? Bool, true)
        XCTAssertEqual(response["version"] as? Int, 3)
        XCTAssertEqual(response["requestID"] as? String, "h3")
        XCTAssertEqual(response["supportedVersions"] as? [Int], [1, 2, 3])
        let schemas = try XCTUnwrap(response["schemas"] as? [String: String])
        XCTAssertEqual(schemas["command"], "floe.command-envelope/3")
        XCTAssertEqual(schemas["runEvents"], "floe.event-cursor/3")
        XCTAssertEqual(schemas["operationEffects"], "floe.effect-cursor/3")
        // Envelope validation is not a business capability. Only handshake
        // and the existing fail-closed credential status execute.
        XCTAssertEqual(response["operations"] as? [String], ["handshake", "credential.status"])
        XCTAssertEqual(response["businessCapabilities"] as? [String], [])
        XCTAssertEqual(response["envelopeValidation"] as? String, "structuralOnly")
        let staged = try XCTUnwrap(response["stagedOperations"] as? [[String: Any]])
        XCTAssertEqual(staged.compactMap { $0["operation"] as? String },
                       ["command.submit", "event.poll", "effect.poll"])
        XCTAssertTrue(staged.allSatisfy { ($0["bound"] as? Bool) == false })
        XCTAssertEqual(staged.compactMap { $0["schema"] as? String },
                       ["floe.command-envelope/3", "floe.event-cursor/3", "floe.effect-cursor/3"])
        XCTAssertEqual(response["localLLM"] as? Bool, false)
    }

    func testClosedCommandMatrixIsUniqueAndComplete() throws {
        let rules = BridgeV3.commandRules
        // G07.3B appends thirteen schedule configuration tuples to the
        // preserved Alpha20 matrix. Existing role counts and mailbox bounds
        // are unchanged; the new label grants no execution role by itself.
        XCTAssertEqual(rules.count, 108)
        XCTAssertEqual(rules.filter { $0.scope == .applicationConfiguration }.count, 68)
        XCTAssertEqual(rules.filter { $0.scope == .conversationLifecycle }.count, 21)
        XCTAssertEqual(rules.filter { $0.scope == .launch }.count, 5)
        XCTAssertEqual(rules.filter { $0.scope == .taskExecution }.count, 14)
        // The third content.read entry shares (scope, command) with the
        // conversations entry but has a different configuration label, so the
        // uniqueness key must include the label.
        let keys = rules.map {
            "\($0.scope.rawValue)|\($0.configurationScope ?? "")|\($0.command)"
        }
        XCTAssertEqual(Set(keys).count, rules.count, "matrix entries must be unique")
        for rule in rules {
            XCTAssertFalse(rule.command.isEmpty)
            XCTAssertFalse(rule.command.contains(" "))
            if rule.scope == .applicationConfiguration {
                XCTAssertNotNil(rule.configurationScope, rule.command)
                XCTAssertTrue(BridgeV3.configurationScopes.contains(rule.configurationScope ?? ""),
                              rule.command)
            } else {
                XCTAssertNil(rule.configurationScope, rule.command)
            }
            XCTAssertFalse(rule.isRunEventPoll && rule.command != "event.poll")
            XCTAssertFalse(rule.isRunEventPoll && rule.scope != .taskExecution)
        }
        XCTAssertEqual(Set(rules.filter { $0.allowsCreateIntent }.map { $0.command }),
                       ["config.provider.save", "skills.install", "mcp.connect",
                        "run.startTask", "conversation.create", "temp.start",
                        "memory.add", "memory.delete.bulk", "memory.organize.start",
                        "memory.organize.apply", "personalization.generate"])
        XCTAssertEqual(rules.filter { $0.isRunEventPoll }.map { $0.command }, ["event.poll"])
        // The declared vocabulary is the closed 20 labels. Active command
        // labels must match the approved matrix; the three reserved labels are
        // explicit, not silently dropped or turned into invented commands.
        let declaredLabels: Set<String> = [
            "providers", "models", "preferences", "catalog", "credentials",
            "skills", "mcp", "settings.approval", "settings.websearch",
            "conversations", "capabilities", "system", "operations",
            "attachmentStaging",
            "settings.defaults", "memory", "personalization", "usage", "privacy",
            "schedule",
        ]
        XCTAssertEqual(BridgeV3.configurationScopes.count, 20)
        XCTAssertEqual(Set(BridgeV3.configurationScopes), declaredLabels)
        let activeLabels = Set(rules.compactMap { $0.configurationScope })
        XCTAssertEqual(activeLabels, [
            "providers", "models", "preferences", "catalog", "skills", "mcp",
            "settings.websearch", "conversations", "capabilities", "system",
            "attachmentStaging", "settings.defaults", "memory", "personalization",
            "usage", "privacy", "schedule",
        ])
        // `settings.approval` is reserved/inactive for this wire slice:
        // approval preferences remain implemented through the actual
        // preferences or per-task policy domain, never a dedicated command
        // invented just to make the label active. `credentials` and
        // `operations` are reserved declared labels too.
        XCTAssertEqual(declaredLabels.subtracting(activeLabels),
                       ["settings.approval", "credentials", "operations"])

        // Manual golden matrix: all 90 approved (scope, command) pairs are
        // written here independently of BridgeV3.commandRules, so a source
        // matrix edit that silently adds, drops or relabels a command is
        // caught rather than being derived from the same table. The 57
        // legacy pairs stay FIRST (the prefix(57) proof below).
        let goldenPairs: [(scope: String, configurationScope: String?, command: String)] = [
            // applicationConfiguration (27)
            ("applicationConfiguration", "providers", "config.providers.list"),
            ("applicationConfiguration", "providers", "config.provider.save"),
            ("applicationConfiguration", "providers", "config.provider.delete"),
            ("applicationConfiguration", "providers", "config.provider.probe"),
            ("applicationConfiguration", "models", "config.models.list"),
            ("applicationConfiguration", "models", "config.model.save"),
            ("applicationConfiguration", "catalog", "config.catalog.search"),
            ("applicationConfiguration", "preferences", "config.preferences.get"),
            ("applicationConfiguration", "preferences", "config.preferences.save"),
            ("applicationConfiguration", "settings.websearch", "config.websearch.get"),
            ("applicationConfiguration", "settings.websearch", "config.websearch.save"),
            ("applicationConfiguration", "conversations", "conversation.list"),
            ("applicationConfiguration", "conversations", "conversation.search"),
            ("applicationConfiguration", "capabilities", "capability.tools.list"),
            ("applicationConfiguration", "skills", "skills.list"),
            ("applicationConfiguration", "skills", "skills.install"),
            ("applicationConfiguration", "skills", "skills.uninstall"),
            ("applicationConfiguration", "mcp", "mcp.servers.list"),
            ("applicationConfiguration", "mcp", "mcp.connect"),
            ("applicationConfiguration", "mcp", "mcp.disconnect"),
            ("applicationConfiguration", "system", "system.bootstrap"),
            ("applicationConfiguration", "system", "system.shutdown"),
            ("applicationConfiguration", "system", "system.lifecycle"),
            ("applicationConfiguration", "attachmentStaging", "attachment.stage"),
            ("applicationConfiguration", "attachmentStaging", "attachment.staging.read"),
            ("applicationConfiguration", "attachmentStaging", "attachment.staging.cancel"),
            ("applicationConfiguration", "attachmentStaging", "attachment.staging.discard"),
            // conversationLifecycle (11)
            ("conversationLifecycle", nil, "conversation.get"),
            ("conversationLifecycle", nil, "conversation.rename"),
            ("conversationLifecycle", nil, "conversation.archive"),
            ("conversationLifecycle", nil, "conversation.delete"),
            ("conversationLifecycle", nil, "conversation.messagePage"),
            ("conversationLifecycle", nil, "temp.end"),
            ("conversationLifecycle", nil, "temp.keep"),
            ("conversationLifecycle", nil, "attachment.commit"),
            ("conversationLifecycle", nil, "attachment.read"),
            ("conversationLifecycle", nil, "attachment.cancel"),
            ("conversationLifecycle", nil, "content.read"),
            // content.read configuration/conversations (1)
            ("applicationConfiguration", "conversations", "content.read"),
            // launch (4)
            ("launch", nil, "run.start"),
            ("launch", nil, "run.startTask"),
            ("launch", nil, "conversation.create"),
            ("launch", nil, "temp.start"),
            // taskExecution (14)
            ("taskExecution", nil, "run.cancel"),
            ("taskExecution", nil, "run.retry"),
            ("taskExecution", nil, "run.steer"),
            ("taskExecution", nil, "run.queue"),
            ("taskExecution", nil, "run.input.edit"),
            ("taskExecution", nil, "run.input.remove"),
            ("taskExecution", nil, "run.input.reorder"),
            ("taskExecution", nil, "run.approval.resolve"),
            ("taskExecution", nil, "run.policy.update"),
            ("taskExecution", nil, "run.skillcancel"),
            ("taskExecution", nil, "run.snapshot"),
            ("taskExecution", nil, "child.list"),
            ("taskExecution", nil, "child.entries"),
            ("taskExecution", nil, "event.poll"),
            // Settings-domain P0 additive entries (27; accepted rev3).
            // settings.defaults
            ("applicationConfiguration", "settings.defaults", "config.defaults.get"),
            ("applicationConfiguration", "settings.defaults", "config.defaults.save"),
            // memory
            ("applicationConfiguration", "memory", "memory.list"),
            ("applicationConfiguration", "memory", "memory.get"),
            ("applicationConfiguration", "memory", "memory.add"),
            ("applicationConfiguration", "memory", "memory.update"),
            ("applicationConfiguration", "memory", "memory.delete"),
            ("applicationConfiguration", "memory", "memory.delete.bulk"),
            ("applicationConfiguration", "memory", "memory.search"),
            ("applicationConfiguration", "memory", "memory.candidates.list"),
            ("applicationConfiguration", "memory", "memory.candidate.resolve"),
            ("applicationConfiguration", "memory", "memory.organize.start"),
            ("applicationConfiguration", "memory", "memory.organize.proposal.read"),
            ("applicationConfiguration", "memory", "memory.organize.apply"),
            ("applicationConfiguration", "memory", "memory.organize.cancel"),
            // personalization
            ("applicationConfiguration", "personalization", "personalization.get"),
            ("applicationConfiguration", "personalization", "personalization.revision.read"),
            ("applicationConfiguration", "personalization", "personalization.save"),
            ("applicationConfiguration", "personalization", "personalization.rollback"),
            ("applicationConfiguration", "personalization", "personalization.automatic.set"),
            ("applicationConfiguration", "personalization", "personalization.generate"),
            ("applicationConfiguration", "personalization", "personalization.generate.cancel"),
            ("applicationConfiguration", "personalization", "content.read"),
            // usage
            ("applicationConfiguration", "usage", "usage.statistics.get"),
            // privacy
            ("applicationConfiguration", "privacy", "privacy.summary.get"),
            ("applicationConfiguration", "privacy", "privacy.history.clear"),
            ("applicationConfiguration", "privacy", "privacy.modelConfiguration.clear"),
            // goal-core code batch (2026-10-21): the three appended
            // run-control tuples (append-only; no reorder/rename).
            ("launch", nil, "plan.accept"),
            ("conversationLifecycle", nil, "goal.confirm"),
            ("conversationLifecycle", nil, "conversation.compact"),
            // G04 workspace ledger (2026-10-24): the three appended
            // conversationLifecycle tuples (append-only; no reorder/rename).
            ("conversationLifecycle", nil, "workspace.read"),
            ("conversationLifecycle", nil, "workspace.write"),
            ("conversationLifecycle", nil, "workspace.activate"),
            // G07.3A interaction batch (2026-10-30): current-thread visible
            // search + durable user questions (append-only; no reorder/rename).
            ("conversationLifecycle", nil, "conversation.messageSearch"),
            ("conversationLifecycle", nil, "conversation.messageWindow"),
            ("conversationLifecycle", nil, "question.pending"),
            ("conversationLifecycle", nil, "question.answer"),
            ("conversationLifecycle", nil, "question.cancel"),
            ("applicationConfiguration", "schedule", "schedule.list"),
            ("applicationConfiguration", "schedule", "schedule.get"),
            ("applicationConfiguration", "schedule", "schedule.options"),
            ("applicationConfiguration", "schedule", "schedule.create"),
            ("applicationConfiguration", "schedule", "schedule.update"),
            ("applicationConfiguration", "schedule", "schedule.enable"),
            ("applicationConfiguration", "schedule", "schedule.disable"),
            ("applicationConfiguration", "schedule", "schedule.delete"),
            ("applicationConfiguration", "schedule", "schedule.runNow"),
            ("applicationConfiguration", "schedule", "schedule.history"),
            ("applicationConfiguration", "schedule", "schedule.dispatch"),
            ("applicationConfiguration", "schedule", "schedule.rearm"),
            ("applicationConfiguration", "schedule", "schedule.dispatchPending"),
        ]
        XCTAssertEqual(goldenPairs.count, 108)
        // The uniqueness key includes configurationScope: the third
        // content.read entry intentionally shares scope+command with the
        // conversations entry. The 57 legacy tuples remain unchanged.
        let goldenKeys = goldenPairs.map {
            "\($0.scope)|\($0.configurationScope ?? "")|\($0.command)"
        }
        XCTAssertEqual(Set(goldenKeys).count, 108)
        XCTAssertEqual(Set(goldenPairs.prefix(57).map {
            "\($0.scope)|\($0.configurationScope ?? "")|\($0.command)"
        }).count, 57)
        // distinct (scope, command) pairs: 86 through goal-core +
        // workspace.read + workspace.write + workspace.activate (all three
        // are new distinct commands) => 89 (86+3); distinct COMMAND names are
        // 88 (85+3).
        XCTAssertEqual(Set(goldenPairs.map { "\($0.scope)|\($0.command)" }).count, 107)
        XCTAssertEqual(Set(goldenPairs.map { "\($0.command)" }).count, 106)
        XCTAssertEqual(Set(rules.map {
            "\($0.scope.rawValue)|\($0.configurationScope ?? "")|\($0.command)"
        }), Set(goldenKeys),
                       "Swift matrix must equal the approved 108-entry golden matrix")
    }

    func testScheduleWritesRetainCASAndTheClosedConfigurationRole() {
        let expectedWrites: Set<String> = [
            "schedule.create", "schedule.update", "schedule.enable",
            "schedule.disable", "schedule.delete", "schedule.runNow",
        ]
        let schedules = BridgeV3.commandRules.filter { $0.command.hasPrefix("schedule.") }
        XCTAssertEqual(schedules.count, 13)
        XCTAssertEqual(Set(schedules.filter(\.revisionRequired).map(\.command)), expectedWrites)
        XCTAssertEqual(schedules.filter(\.allowsCreateIntent).map(\.command), ["schedule.create"])
        for rule in schedules {
            XCTAssertEqual(rule.scope, .applicationConfiguration)
            XCTAssertEqual(rule.configurationScope, "schedule")
            XCTAssertFalse(rule.isRunEventPoll)
        }
    }

    func testCredentialStatusStaysFailClosedInV3() throws {
        let response = try exchange(#"{"version":3,"requestID":"s3","operation":"credential.status"}"#)
        XCTAssertEqual(response["version"] as? Int, 3)
        let backend = try XCTUnwrap(response["secretBackend"] as? [String: Any])
        let registered = try XCTUnwrap(backend["registered"] as? Bool)
        XCTAssertEqual(backend["availability"] as? String,
                       registered ? "AVAILABLE" : "NEEDS_CONFIGURATION")
        XCTAssertEqual(backend["memoryFallback"] as? Bool, false)
    }

    func testVersionSelectionKeepsFrozenV1AndV2Paths() throws {
        let v1 = try exchange(#"{"version":1,"requestID":"h1","operation":"handshake"}"#)
        XCTAssertEqual(v1["version"] as? Int, 1)
        XCTAssertEqual(v1["operations"] as? [String], ["handshake", "policy.inspect"])
        let v2 = try exchange(#"{"version":2,"requestID":"h2","operation":"handshake"}"#)
        XCTAssertEqual(v2["version"] as? Int, 2)
        XCTAssertEqual((v2["stagedOperations"] as? [[String: Any]])?.count, 2)
        // G06 additive notes channel: v4 exists and has its own dedicated
        // schema; it never reinterprets v1/v2/v3 bytes.
        let v4 = try exchange(#"{"version":4,"requestID":"h4","operation":"handshake"}"#)
        XCTAssertEqual(v4["version"] as? Int, 4)
        XCTAssertEqual(v4["schema"] as? String, "floe.notes/4")
        let unknown = try exchange(#"{"version":999,"requestID":"h999","operation":"handshake"}"#)
        XCTAssertEqual(unknown["error"] as? String, "unsupportedVersion")
        let unknownV3Operation = try exchange(#"{"version":3,"requestID":"x","operation":"linux.exec"}"#)
        XCTAssertEqual(unknownV3Operation["error"] as? String, "unsupportedOperation")
    }

    func testV2EnvelopeIsNeverReinterpretedAsV3() throws {
        // A structurally valid frozen-v2 envelope, still version 2.
        let v2Body = envelope(schema: nil, scope: "taskExecution", command: "run.snapshot",
                              stateful: false, owner: taskOwner(environment: env, job: job))
        let v2Request = "{\"version\":2,\"requestID\":\"c-1\",\"operation\":\"command.submit\",\"envelope\":\(v2Body)}"
        let v2Response = try exchange(v2Request)
        XCTAssertEqual(v2Response["version"] as? Int, 2)
        XCTAssertEqual(v2Response["ok"] as? Bool, false)
        XCTAssertEqual(v2Response["error"] as? String, "runtimeUnavailable")
        XCTAssertEqual(v2Response["reason"] as? String, "commandBinderUnbound")

        // The same payload under version 3 has no explicit schema.
        let missingSchema = "{\"scope\":\"taskExecution\",\"command\":\"run.snapshot\",\"stateful\":false,\"owner\":\(taskOwner()),\"correlationID\":\"c-1\"}"
        assertInvalid(try exchange(request("command.submit", missingSchema)), "missingSchema")

        // A v2 schema string under version 3 is a typed mismatch, not v2.
        let v2Schema = envelope(schema: "floe.command-envelope/2", scope: "taskExecution",
                                command: "run.snapshot", stateful: false, owner: taskOwner())
        assertInvalid(try exchange(request("command.submit", v2Schema)), "schemaMismatch")

        // Frozen v2 still demands every execution role: v3's optional roles
        // never loosen the v2 validator.
        let v2MissingEnv = "{\"version\":2,\"requestID\":\"c-1\",\"operation\":\"command.submit\",\"envelope\":{\"scope\":\"taskExecution\",\"owner\":{\"taskID\":\"\(task)\",\"runID\":\"\(run)\"},\"command\":\"run.snapshot\",\"stateful\":false,\"correlationID\":\"c-1\"}}"
        assertInvalid(try exchange(v2MissingEnv), "invalidOwnerenvironmentID")
    }

    // MARK: - Task execution scope

    func testTaskExecutionAllowsAbsentOrRealOptionalEnvironmentAndJob() throws {
        // Absent optional roles are the requested correction and still reach
        // the unbound seam, never a fabricated run.
        assertUnbound(try exchange(request("command.submit",
            envelope(scope: "taskExecution", command: "run.snapshot", stateful: false,
                     owner: taskOwner()))), "commandBinderUnbound")
        // Present optional roles must be syntactically valid, non-zero UUIDs.
        assertUnbound(try exchange(request("command.submit",
            envelope(scope: "taskExecution", command: "run.snapshot", stateful: false,
                     owner: taskOwner(environment: env, job: job)))), "commandBinderUnbound")
        // Role aliasing (jobID == runID) is structural, not authority.
        assertUnbound(try exchange(request("command.submit",
            envelope(scope: "taskExecution", command: "run.snapshot", stateful: false,
                     owner: taskOwner(job: run)))), "commandBinderUnbound")
    }

    func testTaskExecutionRejectsMalformedAndAllZeroRoles() throws {
        let ownerCases: [(String, String)] = [
            (taskOwner(environment: zero), "invalidOwnerenvironmentID"),
            (taskOwner(environment: "not-a-uuid"), "invalidOwnerenvironmentID"),
            (taskOwner(job: zero), "invalidOwnerjobID"),
            (taskOwner(job: "job-1"), "invalidOwnerjobID"),
            ("{\"taskID\":\"\(task)\",\"runID\":\"\(zero)\"}", "invalidOwnerrunID"),
            ("{\"taskID\":\"\(zero)\",\"runID\":\"\(run)\"}", "invalidOwnertaskID"),
        ]
        for (owner, reason) in ownerCases {
            assertInvalid(try exchange(request("command.submit",
                envelope(scope: "taskExecution", command: "run.snapshot", stateful: false,
                         owner: owner))), reason)
        }
        // Explicit null and unknown role fields are not "absent".
        let nullEnv = "{\"taskID\":\"\(task)\",\"runID\":\"\(run)\",\"environmentID\":null}"
        assertInvalid(try exchange(request("command.submit",
            envelope(scope: "taskExecution", command: "run.snapshot", stateful: false,
                     owner: nullEnv))), "invalidOwnerenvironmentID")
        let unknownRole = "{\"taskID\":\"\(task)\",\"runID\":\"\(run)\",\"workspaceID\":\"\(env)\"}"
        assertInvalid(try exchange(request("command.submit",
            envelope(scope: "taskExecution", command: "run.snapshot", stateful: false,
                     owner: unknownRole))), "unknownOwnerField")
        // Missing owner entirely.
        assertInvalid(try exchange(request("command.submit",
            envelope(scope: "taskExecution", command: "run.snapshot", stateful: false))),
                      "missingExecutionOwner")
    }

    // MARK: - Conversation lifecycle scope

    func testConversationLifecycleRequiresTaskAndRejectsRunRoles() throws {
        let taskOnly = "{\"taskID\":\"\(task)\"}"
        assertUnbound(try exchange(request("command.submit",
            envelope(scope: "conversationLifecycle", command: "conversation.get",
                     stateful: false, owner: taskOnly))), "commandBinderUnbound")
        // A lifecycle command never needs a run/environment/job, and must not
        // smuggle one in.
        for owner in ["{\"taskID\":\"\(task)\",\"runID\":\"\(run)\"}",
                      "{\"taskID\":\"\(task)\",\"environmentID\":\"\(env)\"}",
                      "{\"taskID\":\"\(task)\",\"jobID\":\"\(job)\"}"] {
            assertInvalid(try exchange(request("command.submit",
                envelope(scope: "conversationLifecycle", command: "conversation.get",
                         stateful: false, owner: owner))),
                          "conversationLifecycleMustNotCarryRunIdentity")
        }
        assertInvalid(try exchange(request("command.submit",
            envelope(scope: "conversationLifecycle", command: "conversation.get",
                     stateful: false))), "missingTaskIdentity")
        // Stateful lifecycle mutations use the resource revision, not a run.
        let revision = "{\"resourceID\":\"conversation.\(task)\",\"version\":\"2026-10-19T00:00:00Z\"}"
        assertUnbound(try exchange(request("command.submit",
            envelope(scope: "conversationLifecycle", command: "conversation.rename",
                     stateful: true, owner: taskOnly, revision: revision))),
                      "commandBinderUnbound")
        assertInvalid(try exchange(request("command.submit",
            envelope(scope: "conversationLifecycle", command: "conversation.rename",
                     stateful: true, owner: taskOnly))), "missingRevisionForStatefulCommand")
    }

    // MARK: - Launch scope

    func testLaunchDistinguishesExistingConversationFromNewIdentity() throws {
        let revision = "{\"resourceID\":\"conversation.\(task)\",\"version\":\"7\"}"
        let existing = "{\"taskID\":\"\(task)\"}"
        assertUnbound(try exchange(request("command.submit",
            envelope(scope: "launch", command: "run.start", stateful: true,
                     owner: existing, revision: revision))), "commandBinderUnbound")
        assertInvalid(try exchange(request("command.submit",
            envelope(scope: "launch", command: "run.start", stateful: true,
                     owner: existing))), "missingRevisionForStatefulCommand")
        assertInvalid(try exchange(request("command.submit",
            envelope(scope: "launch", command: "run.start", stateful: true,
                     revision: revision))), "missingTaskIdentity")
        assertInvalid(try exchange(request("command.submit",
            envelope(scope: "launch", command: "run.start", stateful: true,
                     owner: "{\"taskID\":\"\(task)\",\"runID\":\"\(run)\"}",
                     revision: revision))), "launchMustNotCarryExecutionRoles")
        // New identity: absent taskID plus explicit create intent; no fake
        // revision and no not-yet-created run/conversation ID.
        for command in ["run.startTask", "conversation.create", "temp.start"] {
            assertUnbound(try exchange(request("command.submit",
                envelope(scope: "launch", command: command, stateful: true,
                         createIntent: true))), "commandBinderUnbound")
            assertInvalid(try exchange(request("command.submit",
                envelope(scope: "launch", command: command, stateful: true))),
                          "createIntentRequired")
            assertInvalid(try exchange(request("command.submit",
                envelope(scope: "launch", command: command, stateful: true,
                         revision: revision, createIntent: true))), "revisionForNewIdentity")
            assertInvalid(try exchange(request("command.submit",
                envelope(scope: "launch", command: command, stateful: true,
                         owner: existing, createIntent: true))), "newIdentityMustNotCarryOwner")
        }
        // Existing-conversation launch cannot claim create intent.
        assertInvalid(try exchange(request("command.submit",
            envelope(scope: "launch", command: "run.start", stateful: true,
                     createIntent: true))), "createIntentNotAllowed")
    }

    // MARK: - Application configuration scope

    func testConfigurationScopeUsesClosedLabelMatrix() throws {
        let revision = "{\"resourceID\":\"provider.p1\",\"version\":\"sync-4\"}"
        assertUnbound(try exchange(request("command.submit",
            envelope(scope: "applicationConfiguration", configurationScope: "providers",
                     command: "config.provider.save", stateful: true, revision: revision))),
                      "commandBinderUnbound")
        // A label change cannot smuggle a command into another subsystem.
        assertInvalid(try exchange(request("command.submit",
            envelope(scope: "applicationConfiguration", configurationScope: "system",
                     command: "config.provider.save", stateful: true, revision: revision))),
                      "configurationScopeMismatch")
        assertInvalid(try exchange(request("command.submit",
            envelope(scope: "applicationConfiguration", configurationScope: "providers",
                     command: "config.websearch.save", stateful: true, revision: revision))),
                      "configurationScopeMismatch")
        assertInvalid(try exchange(request("command.submit",
            envelope(scope: "applicationConfiguration", configurationScope: "providers",
                     command: "skills.install", stateful: true, revision: revision))),
                      "configurationScopeMismatch")
        // Unknown and missing labels are typed rejections.
        assertInvalid(try exchange(request("command.submit",
            envelope(scope: "applicationConfiguration", configurationScope: "everything",
                     command: "config.providers.list", stateful: false))),
                      "invalidConfigurationScope")
        assertInvalid(try exchange(request("command.submit",
            envelope(scope: "applicationConfiguration",
                     command: "config.providers.list", stateful: false))),
                      "missingConfigurationScope")
        // Configuration never carries an execution owner.
        assertInvalid(try exchange(request("command.submit",
            envelope(scope: "applicationConfiguration", configurationScope: "providers",
                     command: "config.providers.list", stateful: false,
                     owner: "{\"taskID\":\"\(task)\"}"))),
                      "configurationScopeMustNotCarryOwner")
        // The stateful flag cannot be downgraded to skip a revision.
        assertInvalid(try exchange(request("command.submit",
            envelope(scope: "applicationConfiguration", configurationScope: "providers",
                     command: "config.provider.save", stateful: false, revision: revision))),
                      "statefulMismatch")
        assertInvalid(try exchange(request("command.submit",
            envelope(scope: "applicationConfiguration", configurationScope: "providers",
                     command: "config.providers.list", stateful: false, revision: revision))),
                      "revisionNotAllowed")
    }

    func testConfigurationCreateIntentAndAttachmentStaging() throws {
        // New host-owned resources use explicit create intent, never an
        // invented version.
        for (label, command) in [("providers", "config.provider.save"),
                                 ("skills", "skills.install"),
                                 ("mcp", "mcp.connect")] {
            assertUnbound(try exchange(request("command.submit",
                envelope(scope: "applicationConfiguration", configurationScope: label,
                         command: command, stateful: true, createIntent: true))),
                          "commandBinderUnbound")
        }
        // Attachment staging is pre-conversation configuration vocabulary; it
        // requires neither a run nor a task and never fabricates one.
        for command in ["attachment.stage", "attachment.staging.read",
                        "attachment.staging.cancel", "attachment.staging.discard"] {
            assertUnbound(try exchange(request("command.submit",
                envelope(scope: "applicationConfiguration", configurationScope: "attachmentStaging",
                         command: command, stateful: false))), "commandBinderUnbound")
        }
        // Committed attachment commands live in conversationLifecycle.
        assertInvalid(try exchange(request("command.submit",
            envelope(scope: "applicationConfiguration", configurationScope: "attachmentStaging",
                     command: "attachment.commit", stateful: false))), "commandScopeMismatch")
        // `content.read` is the one explicit dual-scope read.
        assertUnbound(try exchange(request("command.submit",
            envelope(scope: "applicationConfiguration", configurationScope: "conversations",
                     command: "content.read", stateful: false))), "commandBinderUnbound")
        assertUnbound(try exchange(request("command.submit",
            envelope(scope: "conversationLifecycle", command: "content.read",
                     stateful: false, owner: "{\"taskID\":\"\(task)\"}"))),
                      "commandBinderUnbound")
    }

    // MARK: - Effect cursor

    func testEffectPollRepresentsAsyncOperationWithoutRunIdentity() throws {
        let effect = "{\"operationReceiptID\":\"receipt-01JTEST\",\"sequence\":0}"
        let body = envelope(schema: BridgeV3.effectSchema,
                            scope: "applicationConfiguration",
                            configurationScope: "providers",
                            command: "effect.poll", stateful: false, effect: effect)
        assertUnbound(try exchange(request("effect.poll", body)), "effectPumpUnbound")
        // A nonzero cursor is valid shape, still no fabricated effect.
        assertUnbound(try exchange(request("effect.poll",
            envelope(schema: BridgeV3.effectSchema, scope: "applicationConfiguration",
                     configurationScope: "system",
                     command: "effect.poll", stateful: false,
                     effect: "{\"operationReceiptID\":\"receipt-2\",\"sequence\":9}"))),
                      "effectPumpUnbound")
    }

    func testEffectPollRejectsMissingMalformedOrRunScopedCursor() throws {
        let schema = BridgeV3.effectSchema
        func effectBody(effect: String?, scope: String = "applicationConfiguration",
                        label: String? = "providers", cursor: String? = nil,
                        owner: String? = nil) -> String {
            envelope(schema: schema, scope: scope, configurationScope: label,
                     command: "effect.poll", stateful: false,
                     owner: owner, cursor: cursor, effect: effect)
        }
        assertInvalid(try exchange(request("effect.poll", effectBody(effect: nil))),
                      "missingEffectCursor")
        for effect in ["{\"operationReceiptID\":\"r\",\"sequence\":-1}",
                       "{\"operationReceiptID\":\"r\",\"sequence\":\"0\"}",
                       "{\"operationReceiptID\":\"\",\"sequence\":0}",
                       "{\"operationReceiptID\":\"   \",\"sequence\":0}",
                       "{\"operationReceiptID\":\"r\",\"sequence\":1.5}",
                       "{\"operationReceiptID\":\"r\",\"sequence\":0,\"runID\":\"\(run)\"}"] {
            assertInvalid(try exchange(request("effect.poll", effectBody(effect: effect))),
                          "invalidEffectCursor")
        }
        // A run cursor is not an operation cursor, and effect.poll is never
        // a run-scoped channel.
        assertInvalid(try exchange(request("effect.poll",
            effectBody(effect: "{\"operationReceiptID\":\"r\",\"sequence\":0}",
                       cursor: "{\"runID\":\"\(run)\",\"sequence\":0}"))),
                      "cursorRoleMismatch")
        assertInvalid(try exchange(request("effect.poll",
            effectBody(effect: "{\"operationReceiptID\":\"r\",\"sequence\":0}",
                       scope: "taskExecution", label: nil, owner: taskOwner()))),
                      "effectPollRequiresConfigurationScope")
        // A configuration receipt never carries a run owner.
        assertInvalid(try exchange(request("effect.poll",
            effectBody(effect: "{\"operationReceiptID\":\"r\",\"sequence\":0}",
                       owner: "{\"taskID\":\"\(task)\"}"))),
                      "configurationScopeMustNotCarryOwner")
        // An operation effect cannot travel in the command channel.
        assertInvalid(try exchange(request("command.submit",
            envelope(scope: "applicationConfiguration", configurationScope: "providers",
                     command: "config.providers.list", stateful: false,
                     effect: "{\"operationReceiptID\":\"r\",\"sequence\":0}"))),
                      "effectIdentityNotAllowed")
    }

    // MARK: - Run event cursor

    func testRunEventPollRequiresActualRunCursor() throws {
        func poll(_ cursor: String?, command: String = "event.poll",
                  scope: String = "taskExecution", owner: String? = nil) -> String {
            let ownerValue = owner ?? taskOwner()
            return envelope(schema: BridgeV3.runEventSchema, scope: scope,
                            command: command, stateful: false,
                            owner: ownerValue, cursor: cursor)
        }
        // A real run-bound cursor reaches the typed unbound pump.
        assertUnbound(try exchange(request("event.poll",
            poll("{\"runID\":\"\(run)\",\"sequence\":0}"))), "eventPumpUnbound")
        assertUnbound(try exchange(request("event.poll",
            poll("{\"runID\":\"\(run)\",\"sequence\":42}"))), "eventPumpUnbound")
        assertInvalid(try exchange(request("event.poll", poll(nil))), "missingEventCursor")
        for cursor in ["{\"runID\":\"\(run)\",\"sequence\":-1}",
                       "{\"runID\":\"\(run)\",\"sequence\":true}",
                       "{\"runID\":\"\(run)\",\"sequence\":1.5}",
                       "{\"runID\":\"\(env)\",\"sequence\":0}"] {
            assertInvalid(try exchange(request("event.poll", poll(cursor))),
                          cursor.contains(env) ? "cursorRunMismatch" : "invalidEventCursor")
        }
        // The effect schema and the command schema are not run cursor schemas.
        assertInvalid(try exchange(request("event.poll",
            envelope(schema: BridgeV3.effectSchema, scope: "taskExecution",
                     command: "event.poll", stateful: false, owner: taskOwner(),
                     cursor: "{\"runID\":\"\(run)\",\"sequence\":0}"))),
                      "schemaRoleMismatch")
        assertInvalid(try exchange(request("event.poll",
            envelope(schema: BridgeV3.commandSchema, scope: "taskExecution",
                     command: "event.poll", stateful: false, owner: taskOwner(),
                     cursor: "{\"runID\":\"\(run)\",\"sequence\":0}"))),
                      "schemaRoleMismatch")
        // A run event poll cannot be smuggled into a config or submit channel.
        assertInvalid(try exchange(request("event.poll",
            poll("{\"runID\":\"\(run)\",\"sequence\":0}",
                 scope: "applicationConfiguration",
                 owner: nil))), "eventPollRequiresTaskScope")
        assertInvalid(try exchange(request("event.poll",
            poll("{\"runID\":\"\(run)\",\"sequence\":0}",
                 command: "run.snapshot"))), "eventPollRequiresEventCommand")
        assertInvalid(try exchange(request("command.submit",
            envelope(scope: "taskExecution", command: "event.poll", stateful: false,
                     owner: taskOwner(), cursor: "{\"runID\":\"\(run)\",\"sequence\":0}"))),
                      "eventPollRequiresPollOperation")
        // A command submit never accepts a run cursor.
        assertInvalid(try exchange(request("command.submit",
            envelope(scope: "taskExecution", command: "run.snapshot", stateful: false,
                     owner: taskOwner(), cursor: "{\"runID\":\"\(run)\",\"sequence\":0}"))),
                      "cursorRoleMismatch")
    }

    // MARK: - Typed primitives, correlation and revision

    func testStrictPrimitivesAndRevisionRules() throws {
        let revision = "{\"resourceID\":\"r\",\"version\":\"1\"}"
        for literal in ["0", "1", "0.0", "\"false\"", "null"] {
            let body = envelope(scope: "taskExecution", command: "run.cancel",
                                stateful: true, owner: taskOwner(), revision: revision,
                                statefulLiteral: literal)
            assertInvalid(try exchange(request("command.submit", body)), "invalidStatefulFlag")
        }
        assertInvalid(try exchange(request("command.submit",
            envelope(scope: "taskExecution", command: "run.cancel", stateful: true,
                     owner: taskOwner(), revision: "{\"resourceID\":\"  \",\"version\":\"1\"}"))),
                      "invalidRevision")
        assertInvalid(try exchange(request("command.submit",
            envelope(scope: "taskExecution", command: "run.cancel", stateful: true,
                     owner: taskOwner(), revision: "{\"resourceID\":\"r\",\"version\":\"\\t\"}"))),
                      "invalidRevision")
        // Unknown envelope fields are rejected, not ignored.
        let unknownField = envelope(scope: "taskExecution", command: "run.snapshot",
                                    stateful: false, owner: taskOwner())
            .replacingOccurrences(of: "{\"schema\"",
                                  with: "{\"extra\":\"ignored\",\"schema\"")
        assertInvalid(try exchange(request("command.submit", unknownField)),
                      "unknownEnvelopeField")
        // Empty/space commands cannot be smuggled through a known label.
        assertInvalid(try exchange(request("command.submit",
            envelope(scope: "taskExecution", command: "", stateful: false,
                     owner: taskOwner()))), "invalidCommand")
        assertInvalid(try exchange(request("command.submit",
            envelope(scope: "taskExecution", command: "run snapshot", stateful: false,
                     owner: taskOwner()))), "invalidCommand")
    }

    func testCorrelationAndGrantReferenceRules() throws {
        assertInvalid(try exchange(request("command.submit",
            envelope(scope: "taskExecution", command: "run.snapshot", stateful: false,
                     owner: taskOwner(), correlation: "\"other\""))),
                      "correlationMismatch")
        assertInvalid(try exchange(request("command.submit",
            envelope(scope: "taskExecution", command: "run.snapshot", stateful: false,
                     owner: taskOwner(), correlation: "\" \\t \""))),
                      "missingCorrelation")
        // Correlation is an opaque identity: exact bytes, never trimmed.
        assertUnbound(try exchange(request("command.submit",
            envelope(scope: "taskExecution", command: "run.snapshot", stateful: false,
                     owner: taskOwner(), correlation: "\" c-1 \""), id: " c-1 ")),
                      "commandBinderUnbound")
        // Grant references are validated as references only; a valid one does
        // not turn an unbound binder into execution.
        assertUnbound(try exchange(request("command.submit",
            envelope(scope: "taskExecution", command: "run.approval.resolve", stateful: true,
                     owner: taskOwner(),
                     revision: "{\"resourceID\":\"approval.call1\",\"version\":\"1\"}",
                     grantID: "\"\(UUID().uuidString)\""))), "commandBinderUnbound")
        assertInvalid(try exchange(request("command.submit",
            envelope(scope: "taskExecution", command: "run.approval.resolve", stateful: true,
                     owner: taskOwner(),
                     revision: "{\"resourceID\":\"approval.call1\",\"version\":\"1\"}",
                     grantID: "\"nope\""))), "invalidGrantReference")
        assertInvalid(try exchange(request("command.submit",
            envelope(scope: "taskExecution", command: "run.approval.resolve", stateful: true,
                     owner: taskOwner(),
                     revision: "{\"resourceID\":\"approval.call1\",\"version\":\"1\"}",
                     grantID: "\"\(zero)\""))), "invalidGrantReference")
    }

    // MARK: - Binder seam and bounded output

    func testControlledHandlerExecutesOnlyUnderV3ScopedKey() throws {
        let key = BridgeV3.handlerKey(scope: .taskExecution, command: "run.snapshot")
        RuntimeCommandBinder.shared.register(key) { _ in
            Data(#"{"ok":true,"source":"synthetic-v3-host-handler"}"#.utf8)
        }
        defer { RuntimeCommandBinder.shared.unregister(key) }
        let response = try exchange(request("command.submit",
            envelope(scope: "taskExecution", command: "run.snapshot", stateful: false,
                     owner: taskOwner())))
        XCTAssertEqual(response["ok"] as? Bool, true)
        XCTAssertEqual(response["source"] as? String, "synthetic-v3-host-handler")
    }

    func testV2OrWrongScopeHandlerCannotServeV3() throws {
        // A stale v2-style raw-command handler is never consulted by v3.
        RuntimeCommandBinder.shared.register("run.snapshot") { _ in
            Data(#"{"ok":true,"source":"v2-raw-key"}"#.utf8)
        }
        defer { RuntimeCommandBinder.shared.unregister("run.snapshot") }
        assertUnbound(try exchange(request("command.submit",
            envelope(scope: "taskExecution", command: "run.snapshot", stateful: false,
                     owner: taskOwner()))), "commandBinderUnbound")

        // A handler registered for one scope cannot serve another scope even
        // when the command label is identical (`content.read` is dual-scope).
        let configKey = BridgeV3.handlerKey(scope: .applicationConfiguration,
                                            command: "content.read")
        RuntimeCommandBinder.shared.register(configKey) { _ in
            Data(#"{"ok":true,"source":"config-only"}"#.utf8)
        }
        defer { RuntimeCommandBinder.shared.unregister(configKey) }
        assertUnbound(try exchange(request("command.submit",
            envelope(scope: "conversationLifecycle", command: "content.read",
                     stateful: false, owner: "{\"taskID\":\"\(task)\"}"))),
                      "commandBinderUnbound")
    }

    func testEffectAndRunEventPumpsUseSeparateHandlers() throws {
        let effectKey = BridgeV3.effectPumpHandlerKey
        RuntimeCommandBinder.shared.register(effectKey) { data in
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let effect = object?["effect"] as? [String: Any]
            let receipt = effect?["operationReceiptID"] as? String ?? ""
            return (try? JSONSerialization.data(withJSONObject: [
                "ok": true, "state": "accepted", "operationReceiptID": receipt,
            ])) ?? Data("{}".utf8)
        }
        defer { RuntimeCommandBinder.shared.unregister(effectKey) }
        let effectResponse = try exchange(request("effect.poll",
            envelope(schema: BridgeV3.effectSchema, scope: "applicationConfiguration",
                     configurationScope: "providers",
                     command: "effect.poll", stateful: false,
                     effect: "{\"operationReceiptID\":\"receipt-synthetic\",\"sequence\":0}")))
        XCTAssertEqual(effectResponse["ok"] as? Bool, true)
        XCTAssertEqual(effectResponse["operationReceiptID"] as? String, "receipt-synthetic")

        // The effect handler must not serve a run event poll.
        assertUnbound(try exchange(request("event.poll",
            envelope(schema: BridgeV3.runEventSchema, scope: "taskExecution",
                     command: "event.poll", stateful: false, owner: taskOwner(),
                     cursor: "{\"runID\":\"\(run)\",\"sequence\":0}"))),
                      "eventPumpUnbound")
    }

    func testMalformedAndOversizeBinderOutputFailsClosed() throws {
        let key = BridgeV3.handlerKey(scope: .taskExecution, command: "run.snapshot")
        RuntimeCommandBinder.shared.register(key) { _ in Data("not json".utf8) }
        defer { RuntimeCommandBinder.shared.unregister(key) }
        let malformed = try exchange(request("command.submit",
            envelope(scope: "taskExecution", command: "run.snapshot", stateful: false,
                     owner: taskOwner())))
        XCTAssertEqual(malformed["error"] as? String, "invalidBinderOutput")
        XCTAssertEqual(malformed["reason"] as? String, "malformedBinderOutput")

        RuntimeCommandBinder.shared.register(key) { _ in
            Data(repeating: 65, count: BridgeV3.maximumBytes + 1)
        }
        let oversized = try exchange(request("command.submit",
            envelope(scope: "taskExecution", command: "run.snapshot", stateful: false,
                     owner: taskOwner())))
        XCTAssertEqual(oversized["error"] as? String, "invalidBinderOutput")
        XCTAssertEqual(oversized["reason"] as? String, "binderOutputTooLarge")
    }

    // MARK: - Bounds and malformed input

    func testOversizeMalformedUTF8AndMalformedJSONFailClosed() throws {
        let oversized = AndroidBridge.exchange(Data(repeating: 122, count: BridgeV3.maximumBytes + 1))
        let oversizedObject = try JSONSerialization.jsonObject(with: oversized) as? [String: Any]
        XCTAssertEqual(oversizedObject?["error"] as? String, "requestTooLarge")
        // Invalid UTF-8 never reaches the typed v3 validator; the frozen
        // top-level JSON guard fails closed exactly as it did before v3.
        let invalidUTF8 = AndroidBridge.exchange(Data([0x7B, 0xFF, 0xFE, 0x7D]))
        let invalidUTF8Object = try JSONSerialization.jsonObject(with: invalidUTF8) as? [String: Any]
        XCTAssertEqual(invalidUTF8Object?["error"] as? String, "invalidJSON")
        assertInvalid(try exchange(#"{"version":3,"requestID":"c-1","operation":"command.submit","envelope":"not-an-object"}"#),
                      "missingEnvelopeObject")
        assertInvalid(try exchange(#"{"version":3,"requestID":"c-1","operation":"command.submit","envelope":{"schema":1}}"#),
                      "missingSchema")
    }
    // MARK: - Settings-domain P0 additive matrix and payload grammar

    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() {
            lock.lock(); value += 1; lock.unlock()
        }

        var count: Int {
            lock.lock(); defer { lock.unlock() }
            return value
        }
    }

    private func assertRejected(_ response: [String: Any], error: String,
                                reason: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(response["ok"] as? Bool, false, file: file, line: line)
        XCTAssertEqual(response["error"] as? String, error, file: file, line: line)
        XCTAssertEqual(response["reason"] as? String, reason, file: file, line: line)
    }

    func testSettingsDomainMatrixAppendsAcceptedTuplesUnderFiveLabels() throws {
        let newPairs: [(command: String, label: String)] = [
            ("config.defaults.get", "settings.defaults"),
            ("config.defaults.save", "settings.defaults"),
            ("memory.list", "memory"),
            ("memory.get", "memory"),
            ("memory.add", "memory"),
            ("memory.update", "memory"),
            ("memory.delete", "memory"),
            ("memory.delete.bulk", "memory"),
            ("memory.search", "memory"),
            ("memory.candidates.list", "memory"),
            ("memory.candidate.resolve", "memory"),
            ("memory.organize.start", "memory"),
            ("memory.organize.proposal.read", "memory"),
            ("memory.organize.apply", "memory"),
            ("memory.organize.cancel", "memory"),
            ("personalization.get", "personalization"),
            ("personalization.revision.read", "personalization"),
            ("personalization.save", "personalization"),
            ("personalization.rollback", "personalization"),
            ("personalization.automatic.set", "personalization"),
            ("personalization.generate", "personalization"),
            ("personalization.generate.cancel", "personalization"),
            ("content.read", "personalization"),
            ("usage.statistics.get", "usage"),
            ("privacy.summary.get", "privacy"),
            ("privacy.history.clear", "privacy"),
            ("privacy.modelConfiguration.clear", "privacy"),
        ]
        XCTAssertEqual(newPairs.count, 27)
        for pair in newPairs {
            let matches = BridgeV3.commandRules.filter {
                $0.command == pair.command && $0.configurationScope == pair.label
            }
            XCTAssertEqual(matches.count, 1, "\(pair.command)/\(pair.label)")
            XCTAssertEqual(matches.first?.scope, .applicationConfiguration)
        }
        // The existing content.read entries remain; the additive third entry
        // is the only new tuple for an already-known command.
        XCTAssertEqual(BridgeV3.commandRules.filter { $0.command == "content.read" }.count, 3)
        XCTAssertEqual(BridgeV3.commandRules.filter {
            $0.command == "content.read" && $0.configurationScope == "conversations"
        }.count, 1)
        XCTAssertEqual(BridgeV3.commandRules.filter {
            $0.command == "content.read" && $0.configurationScope == "personalization"
        }.count, 1)
        for reserved in ["credentials", "settings.approval", "operations"] {
            XCTAssertTrue(BridgeV3.commandRules.allSatisfy {
                $0.configurationScope != reserved
            }, reserved)
        }
        XCTAssertEqual(SettingsDomainV1.createOnlyCommands, [
            "memory.add", "memory.delete.bulk", "memory.organize.start",
            "memory.organize.apply", "personalization.generate",
        ])
    }

    func testSettingsDomainContentReadSharedHandlerKeyDispatchesLabel() throws {
        let key = BridgeV3.handlerKey(scope: .applicationConfiguration,
                                      command: "content.read")
        let counter = LockedCounter()
        RuntimeCommandBinder.shared.register(key) { data in
            counter.increment()
            // The binder receives the validated envelope bytes themselves;
            // the request wrapper is above this seam.
            let envelope = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let label = envelope?["configurationScope"] as? String ?? "missing"
            return (try? JSONSerialization.data(withJSONObject: [
                "ok": true, "source": "shared-content-read", "label": label,
            ])) ?? Data("{}".utf8)
        }
        defer { RuntimeCommandBinder.shared.unregister(key) }

        let valid = #"{"handle":"h-1","offsetBytes":0,"maxBytes":1024}"#
        let conversations = try exchange(request("command.submit",
            envelope(scope: "applicationConfiguration", configurationScope: "conversations",
                     command: "content.read", stateful: false, payload: valid)))
        XCTAssertEqual(conversations["ok"] as? Bool, true)
        XCTAssertEqual(conversations["label"] as? String, "conversations")

        let personalization = try exchange(request("command.submit",
            envelope(scope: "applicationConfiguration", configurationScope: "personalization",
                     command: "content.read", stateful: false, payload: valid)))
        XCTAssertEqual(personalization["ok"] as? Bool, true)
        XCTAssertEqual(personalization["label"] as? String, "personalization")
        XCTAssertEqual(counter.count, 2)

        // A label without a matching matrix entry is rejected before dispatch.
        assertInvalid(try exchange(request("command.submit",
            envelope(scope: "applicationConfiguration", configurationScope: "usage",
                     command: "content.read", stateful: false, payload: valid))),
                      "configurationScopeMismatch")
        XCTAssertEqual(counter.count, 2)
    }

    func testSettingsDomainCreateIntentPolicyIsEnforced() throws {
        let createPayloads: [(command: String, payload: String)] = [
            ("memory.add", #"{"content":"remember this","scope":{"kind":"user"}}"#),
            ("memory.delete.bulk", #"{"batchID":"\#(UUID().uuidString)","entries":[{"id":"\#(UUID().uuidString)","expectedDigest":"sha256:\#(String(repeating: "a", count: 64))"}],"syncRevision":0}"#),
            ("memory.organize.start", #"{"mode":"reviewFirst","includeSemantic":false}"#),
            ("memory.organize.apply", #"{"handle":"h-1","suggestionID":"\#(UUID().uuidString)","batchID":"\#(UUID().uuidString)","syncRevision":0}"#),
            ("personalization.generate", #"{"kind":"soul"}"#),
        ]
        for entry in createPayloads {
            let command = entry.command
            let payload = entry.payload
            assertUnbound(try exchange(request("command.submit",
                envelope(scope: "applicationConfiguration", configurationScope:
                            command.hasPrefix("memory") ? "memory" : "personalization",
                         command: command, stateful: true, createIntent: true,
                         payload: payload))), "commandBinderUnbound")
            // A create-only command cannot smuggle an existing-resource
            // revision through the generic matrix.
            assertInvalid(try exchange(request("command.submit",
                envelope(scope: "applicationConfiguration", configurationScope:
                            command.hasPrefix("memory") ? "memory" : "personalization",
                         command: command, stateful: true,
                         revision: #"{"resourceID":"r","version":"1"}"#,
                         payload: payload))), "createIntentRequired")
            // Create intent still requires stateful=true.
            assertInvalid(try exchange(request("command.submit",
                envelope(scope: "applicationConfiguration", configurationScope:
                            command.hasPrefix("memory") ? "memory" : "personalization",
                         command: command, stateful: false, createIntent: true,
                         payload: payload))), "statefulMismatch")
        }
        // A read command never accepts create intent.
        assertInvalid(try exchange(request("command.submit",
            envelope(scope: "applicationConfiguration", configurationScope: "memory",
                     command: "memory.list", stateful: true, createIntent: true,
                     payload: "{}"))), "createIntentNotAllowed")
        // A revision command never accepts create intent.
        assertInvalid(try exchange(request("command.submit",
            envelope(scope: "applicationConfiguration", configurationScope: "memory",
                     command: "memory.update", stateful: true, createIntent: true,
                     payload: #"{"id":"\#(UUID().uuidString)","changes":{"importance":0.5}}"#))),
                      "createIntentNotAllowed")
    }

    func testSettingsDomainPayloadValidationRunsBeforeHandler() throws {
        let key = BridgeV3.handlerKey(scope: .applicationConfiguration, command: "memory.add")
        let counter = LockedCounter()
        RuntimeCommandBinder.shared.register(key) { _ in
            counter.increment()
            return Data(#"{"ok":true,"source":"synthetic-settings-handler"}"#.utf8)
        }
        defer { RuntimeCommandBinder.shared.unregister(key) }

        // Unknown closed-DTO field: zero dispatch.
        assertInvalid(try exchange(request("command.submit",
            envelope(scope: "applicationConfiguration", configurationScope: "memory",
                     command: "memory.add", stateful: true, createIntent: true,
                     payload: #"{"content":"hello","scope":{"kind":"user"},"dbPath":"/tmp/x"}"#))),
                      "unknownMemoryField")
        XCTAssertEqual(counter.count, 0)

        // Oversize content is a typed payload rejection, not a silent clamp.
        let oversize = String(repeating: "x", count: 4_097)
        let oversizePayload = #"{"content":"\#(oversize)","scope":{"kind":"user"}}"#
        assertRejected(try exchange(request("command.submit",
            envelope(scope: "applicationConfiguration", configurationScope: "memory",
                     command: "memory.add", stateful: true, createIntent: true,
                     payload: oversizePayload))),
                       error: "payloadTooLarge", reason: "maxChars:4096")
        XCTAssertEqual(counter.count, 0)

        // Valid shape reaches the controlled synthetic handler exactly once.
        let response = try exchange(request("command.submit",
            envelope(scope: "applicationConfiguration", configurationScope: "memory",
                     command: "memory.add", stateful: true, createIntent: true,
                     payload: #"{"content":"hello","scope":{"kind":"user"}}"#)))
        XCTAssertEqual(response["ok"] as? Bool, true)
        XCTAssertEqual(response["source"] as? String, "synthetic-settings-handler")
        XCTAssertEqual(counter.count, 1)
    }

    func testSettingsDomainContentReadLabelIsolation() throws {
        let valid = #"{"handle":"h-1","offsetBytes":0,"maxBytes":1024}"#
        assertUnbound(try exchange(request("command.submit",
            envelope(scope: "applicationConfiguration", configurationScope: "personalization",
                     command: "content.read", stateful: false, payload: valid))),
                      "commandBinderUnbound")
        assertUnbound(try exchange(request("command.submit",
            envelope(scope: "applicationConfiguration", configurationScope: "conversations",
                     command: "content.read", stateful: false, payload: valid))),
                      "commandBinderUnbound")
        assertUnbound(try exchange(request("command.submit",
            envelope(scope: "conversationLifecycle", command: "content.read",
                     stateful: false, owner: "{\"taskID\":\"\(task)\"}"))),
                      "commandBinderUnbound")

        // The personalization entry has a closed chunk payload; the existing
        // conversations entry keeps its frozen structural-only behaviour.
        let invalid = #"{"handle":"","offsetBytes":0,"maxBytes":1024}"#
        assertInvalid(try exchange(request("command.submit",
            envelope(scope: "applicationConfiguration", configurationScope: "personalization",
                     command: "content.read", stateful: false, payload: invalid))),
                      "emptyPayloadField:handle")
        assertUnbound(try exchange(request("command.submit",
            envelope(scope: "applicationConfiguration", configurationScope: "conversations",
                     command: "content.read", stateful: false, payload: invalid))),
                      "commandBinderUnbound")

        // Range and scalar-boundary inputs are typed.
        assertInvalid(try exchange(request("command.submit",
            envelope(scope: "applicationConfiguration", configurationScope: "personalization",
                     command: "content.read", stateful: false,
                     payload: #"{"handle":"h","offsetBytes":0,"maxBytes":32769}"#))),
                      "invalidChunkRange")
        // Wrong label never widens authority.
        assertInvalid(try exchange(request("command.submit",
            envelope(scope: "applicationConfiguration", configurationScope: "usage",
                     command: "memory.list", stateful: false, payload: "{}"))),
                      "configurationScopeMismatch")
    }

    func testSettingsDomainDefaultsPrivacyAndUsagePayloads() throws {
        let revision = #"{"resourceID":"settings.defaults","version":"sha256:\#(String(repeating: "b", count: 64))"}"#
        assertUnbound(try exchange(request("command.submit",
            envelope(scope: "applicationConfiguration", configurationScope: "settings.defaults",
                     command: "config.defaults.save", stateful: true, revision: revision,
                     payload: #"{"values":{"verifyFinalAnswer":true}}"#))),
                      "commandBinderUnbound")
        assertInvalid(try exchange(request("command.submit",
            envelope(scope: "applicationConfiguration", configurationScope: "settings.defaults",
                     command: "config.defaults.save", stateful: true, revision: revision,
                     payload: #"{"values":{"verifyFinalAnswer":true,"extra":1}}"#))),
                      "unknownDefaultsField")
        assertInvalid(try exchange(request("command.submit",
            envelope(scope: "applicationConfiguration", configurationScope: "settings.defaults",
                     command: "config.defaults.save", stateful: true, revision: revision,
                     payload: #"{"values":{"defaultAgentMode":"god"}}"#))),
                      "invalidDefaultsValue:defaultAgentMode")
        assertInvalid(try exchange(request("command.submit",
            envelope(scope: "applicationConfiguration", configurationScope: "settings.defaults",
                     command: "config.defaults.save", stateful: true, revision: revision,
                     payload: #"{"values":{"verifyFinalAnswer":1}}"#))),
                      "invalidDefaultsValue:verifyFinalAnswer")
        assertInvalid(try exchange(request("command.submit",
            envelope(scope: "applicationConfiguration", configurationScope: "settings.defaults",
                     command: "config.defaults.get", stateful: false,
                     payload: #"{"unexpected":true}"#))),
                      "invalidPayload")

        assertUnbound(try exchange(request("command.submit",
            envelope(scope: "applicationConfiguration", configurationScope: "privacy",
                     command: "privacy.summary.get", stateful: false))),
                      "commandBinderUnbound")
        let token = "sha256:" + String(repeating: "c", count: 64)
        let privacyRevision = #"{"resourceID":"privacy.history","version":"\#(token)"}"#
        assertUnbound(try exchange(request("command.submit",
            envelope(scope: "applicationConfiguration", configurationScope: "privacy",
                     command: "privacy.history.clear", stateful: true,
                     revision: privacyRevision,
                     payload: #"{"confirmToken":"\#(token)"}"#))),
                      "commandBinderUnbound")
        assertInvalid(try exchange(request("command.submit",
            envelope(scope: "applicationConfiguration", configurationScope: "privacy",
                     command: "privacy.history.clear", stateful: true,
                     revision: privacyRevision, payload: "{}"))),
                      "missingPayloadField:confirmToken")
        assertInvalid(try exchange(request("command.submit",
            envelope(scope: "applicationConfiguration", configurationScope: "privacy",
                     command: "privacy.history.clear", stateful: true,
                     revision: privacyRevision, payload: #"{"confirmToken":"3"}"#))),
                      "invalidPayloadField:confirmToken")

        assertUnbound(try exchange(request("command.submit",
            envelope(scope: "applicationConfiguration", configurationScope: "usage",
                     command: "usage.statistics.get", stateful: false,
                     payload: #"{"dimension":"model","limit":10}"#))),
                      "commandBinderUnbound")
        for payload in [#"{"dimension":"everything"}"#,
                        #"{"dimension":7}"#,
                        #"{"dimension":null}"#,
                        #"{"dimension":true}"#] {
            assertInvalid(try exchange(request("command.submit",
                envelope(scope: "applicationConfiguration", configurationScope: "usage",
                         command: "usage.statistics.get", stateful: false,
                         payload: payload))),
                          "unknownDimension")
        }
        // Omitted dimension still defaults to total and reaches the seam.
        assertUnbound(try exchange(request("command.submit",
            envelope(scope: "applicationConfiguration", configurationScope: "usage",
                     command: "usage.statistics.get", stateful: false,
                     payload: "{}"))),
                      "commandBinderUnbound")

        let receipt = #"{"operationReceiptID":"receipt-settings-1"}"#
        assertUnbound(try exchange(request("command.submit",
            envelope(scope: "applicationConfiguration", configurationScope: "memory",
                     command: "memory.organize.cancel", stateful: false, payload: receipt))),
                      "commandBinderUnbound")
        assertUnbound(try exchange(request("command.submit",
            envelope(scope: "applicationConfiguration", configurationScope: "personalization",
                     command: "personalization.generate.cancel", stateful: false,
                     payload: receipt))), "commandBinderUnbound")
    }

}
