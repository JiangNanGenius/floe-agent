import XCTest
import Foundation
import FloeCore
import FloeSkills
import FloeTools

final class AndroidSkillToolRegistrationTests: XCTestCase, @unchecked Sendable {
    private actor Manager: SkillManaging, SkillCreating {
        var reads = 0
        var mutations = 0
        func read(id: String?) async throws -> [ManagedSkill] {
            reads += 1
            return [ManagedSkill(id: "floe-pdf", name: "PDF Workbench", version: "1.0.0",
                enabled: true, digest: String(repeating: "a", count: 64),
                markdown: "Use exec.shell in the selected task Linux environment.",
                requiredToolNames: ["exec.shell"], description: "PDF workflow guide")]
                .filter { id == nil || $0.id == id }
        }
        func manage(_ request: SkillManageTool.Arguments) async throws -> String {
            mutations += 1
            return "applied"
        }
        func create(_ request: SkillCreationRequest) async throws -> CreatedSkill {
            mutations += 1
            return CreatedSkill(id: "new-guide", name: request.name, version: "1.0.0")
        }
    }
    private final class Availability: @unchecked Sendable {
        private let lock = NSLock()
        private var value = true
        func set(_ newValue: Bool) { lock.withLock { value = newValue } }
        func get() -> Bool { lock.withLock { value } }
    }
    private func context() -> ToolContext {
        ToolContext(runID: UUID(), cancellation: CancellationToken())
    }

    func testRegisteredDiscoveryAndExactReadUseRealToolContracts() async throws {
        let registry = ToolRunnerRegistry()
        let manager = Manager()
        registerSkillTools(registry: registry, creator: manager, manager: manager)
        XCTAssertEqual(Set(registry.allDescriptors.map(\.name)),
            ["skill.list", "skill.search", "skill.read", "skill.create", "skill.manage"])
        for (name, arguments, expectedBody) in [
            ("skill.list", "{}", false),
            ("skill.search", #"{"query":"PDF"}"#, false),
            ("skill.read", #"{"id":"floe-pdf"}"#, true)
        ] {
            let runner = try XCTUnwrap(registry.runner(named: name))
            let output = try await runner.execute(argumentsJSON: Data(arguments.utf8), context: context())
            let data = Data(output.summary.utf8)
            _ = try JSONSerialization.jsonObject(with: data)
            XCTAssertEqual(output.summary.contains("Use exec.shell"), expectedBody)
            XCTAssertTrue(output.summary.contains("floe-pdf"))
        }
        let reads = await manager.reads
        XCTAssertEqual(reads, 3)
    }

    func testRetiredAvailabilityHidesToolsAndRejectsRetainedRunner() async throws {
        let registry = ToolRunnerRegistry()
        let manager = Manager()
        let availability = Availability()
        registerSkillTools(registry: registry, creator: manager, manager: manager,
                           isAvailable: { availability.get() })
        let retained = try XCTUnwrap(registry.runner(named: "skill.read"))
        availability.set(false)
        XCTAssertTrue(registry.allDescriptors.isEmpty)
        XCTAssertNil(registry.runner(named: "skill.read"))
        do {
            _ = try await retained.execute(argumentsJSON: Data(#"{"id":"floe-pdf"}"#.utf8),
                                           context: context())
            XCTFail("A retained runner must refuse after generation retirement")
        } catch {}
        let reads = await manager.reads
        XCTAssertEqual(reads, 0)
    }

    func testRegistrationKeepsMutationApprovalGate() async throws {
        let registry = ToolRunnerRegistry()
        let manager = Manager()
        registerSkillTools(registry: registry, creator: manager, manager: manager)
        let runner = try XCTUnwrap(registry.runner(named: "skill.manage"))
        XCTAssertTrue(runner.descriptor.isSideEffecting)
        let arguments = try JSONSerialization.data(withJSONObject: [
            "action": "setEnabled", "id": "floe-pdf",
            "expectedDigest": String(repeating: "a", count: 64), "enabled": false])
        do {
            _ = try await runner.execute(argumentsJSON: arguments, context: context())
            XCTFail("Registering the tool must not grant approval")
        } catch {}
        let mutations = await manager.mutations
        XCTAssertEqual(mutations, 0)
    }
}
