import Foundation
import Testing
@testable import FloeExecution

/// Contract tests for the host-side launch line that SSHCommandService.runRouted
/// generates for NEW disposable task containers, plus fidelity of the frozen
/// shared-Skills wire fixtures the daemon (floe_remote_agent.py 1.5.0) emits.
/// Existing containers are never touched by this path, so the suite pins that
/// the string only ever launches (`run`) and reports the mount truthfully.
@Suite("Remote shared Skill container routing")
struct RemoteSharedSkillMountTests {
    private let taskID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    @Test("New Docker task containers mount the host shared Skill root read-only")
    func dockerLaunchMountsSkillsReadOnly() {
        let command = SSHCommandService.containerCommand(
            "ls /opt/floe/skills", runtime: .docker, networkEnabled: false, taskID: taskID)
        #expect(command.contains(
            "_floe_mount=missing; if [ -d \"$HOME/.floe/shared/skills\" ]; then _floe_mount=present; fi"))
        #expect(command.contains("if [ \"$_floe_mount\" = present ]"))
        #expect(command.contains("-v \"$HOME/.floe/shared/skills:/opt/floe/skills:ro\""))
        #expect(command.count(of: "/opt/floe/skills:ro") == 1)  // present branch only; else branch has none
        #expect(command.contains("floeSharedSkillsMount=%s"))
        #expect(command.contains("\"$_floe_mount\""))
        #expect(command.contains("docker run --rm --pull=never --network none"))
        #expect(command.contains("--security-opt no-new-privileges"))
        #expect(!command.contains("docker exec") && !command.contains("docker start"))  // new containers only
    }

    @Test("Podman launches carry the identical read-only mount and status marker")
    func podmanUsesSameMount() {
        let command = SSHCommandService.containerCommand(
            "true", runtime: .podman, networkEnabled: true, taskID: taskID)
        #expect(command.contains("podman run --rm --pull=never --network bridge"))
        #expect(command.contains("-v \"$HOME/.floe/shared/skills:/opt/floe/skills:ro\""))
        #expect(command.contains("floeSharedSkillsMount=%s"))
    }

    @Test("Request text stays inert base64 and cannot forge the mount marker")
    func payloadCannotForgeMarker() {
        let sneaky = "echo floeSharedSkillsMount=fake; exit 0"
        let command = SSHCommandService.containerCommand(
            sneaky, runtime: .docker, networkEnabled: false, taskID: taskID)
        #expect(!command.contains("floeSharedSkillsMount=fake"))
        #expect(command.contains(Data(sneaky.utf8).base64EncodedString()))
    }

    @Test("Launch reports the pinned task directory and preserves the container exit status")
    func taskDirectoryAndStatusPreserved() {
        let command = SSHCommandService.containerCommand(
            "true", runtime: .podman, networkEnabled: false, taskID: taskID)
        #expect(command.contains("floeTaskDirectory=$HOME/.floe/tasks/\(taskID.uuidString)"))
        #expect(command.contains("_floe_status=$?"))
        #expect(command.hasSuffix("exit $_floe_status"))
    }

    @Test("Daemon listing fixture decodes into the frozen native DTO")
    func daemonListingMatchesNativeDTO() throws {
        let digest = String(repeating: "3", count: 64)
        let revision = String(repeating: "a", count: 40)
        let listingJSON = Data("""
        {"schema_version":1,"skills":[{"id":"writing-guide","name":"Writing Guide","version":null,\
        "repository":"https://git.example.invalid/library-skills.git","ref":"main",\
        "subdirectory":"skills/writing-guide","revision":"\(revision)","digest":"\(digest)",\
        "relative_path":"packages/writing-guide/\(digest)","updated_at":1762000000.25}]}
        """.utf8)
        struct Listing: Decodable {
            var schemaVersion: Int
            var skills: [RemoteSharedSkill]
            enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version"; case skills }
        }
        let listing = try JSONDecoder().decode(Listing.self, from: listingJSON)
        #expect(listing.schemaVersion == 1)
        #expect(listing.skills.count == 1)
        let skill = listing.skills[0]
        #expect(RemoteSharedSkillsService.isValid(skill))
        #expect(skill.version == nil)
        #expect(skill.containerPath == "/opt/floe/skills/packages/writing-guide/" + digest)
    }

    @Test("Pull entry with the optional version omitted decodes and validates")
    func omittedVersionDecodesHonestly() throws {
        let digest = String(repeating: "b", count: 64)
        let entryJSON = Data("""
        {"id":"writing-guide","name":"Writing Guide",\
        "repository":"https://git.example.invalid/library-skills.git","ref":"main","subdirectory":"",\
        "revision":"\(String(repeating: "a", count: 40))","digest":"\(digest)",\
        "relative_path":"packages/writing-guide/\(digest)","updated_at":1762000000}
        """.utf8)
        let entry = try JSONDecoder().decode(RemoteSharedSkill.self, from: entryJSON)
        #expect(entry.version == nil)
        #expect(RemoteSharedSkillsService.isValid(entry))
    }

    @Test("Fixed-digest read fixture satisfies the native document checks")
    func readFixtureRoundTrips() throws {
        let digest = String(repeating: "c", count: 64)
        let readJSON = Data("""
        {"skill_id":"writing-guide","digest":"\(digest)","path":"SKILL.md","content":"# Writing Guide\\n","byte_count":16}
        """.utf8)
        let document = try JSONDecoder().decode(RemoteSharedSkillDocument.self, from: readJSON)
        #expect(document.skillID == "writing-guide")
        #expect(document.digest == digest)
        #expect(document.path == "SKILL.md")
        #expect(document.byteCount == document.content.utf8.count)
        #expect(document.byteCount <= 1_048_576)
    }
}

private extension String {
    func count(of needle: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var total = 0
        var search = startIndex
        while let range = range(of: needle, range: search..<endIndex) {
            total += 1
            search = range.upperBound
        }
        return total
    }
}
