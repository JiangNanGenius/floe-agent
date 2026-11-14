// FloeExecution — managed Python package spec parsing.
//
// These assertions moved with the retired exec.localPython tool: the parser
// remains live on the exec.shell pip route (approval policy and guest
// installation), so its rejection rules stay covered.

import Foundation
import Testing
@testable import FloeExecution
import FloeCore

@Suite("Managed Python package specs")
struct ManagedPythonPackageSpecParserTests {
    @Test func shellPipPreservesArgumentsAndRejectsTargetOrCodeInjection() throws {
        if case .install(let specs) = try ManagedPythonPackageSpecParser.parseShell(arguments: ["install", "-U", "httpx==0.28.1", "requests"]) {
            #expect(specs == ["httpx==0.28.1", "requests"])
        } else { Issue.record("Install was not routed") }
        if case .remove(let name) = try ManagedPythonPackageSpecParser.parseShell(arguments: ["uninstall", "-y", "requests"]) {
            #expect(name == "requests")
        } else { Issue.record("Uninstall was not routed") }
        if case .inspect(let command, let args) = try ManagedPythonPackageSpecParser.parseShell(arguments: ["list", "--format=json"]) {
            #expect(command == "list" && args == ["--format=json"])
        } else { Issue.record("Inventory was not routed") }
        for arguments in [["install", "--target", "/tmp", "requests"], ["install", "https://example.com/p.whl"],
                          ["install", "requests;print(1)"], ["uninstall", "one", "two"], ["show", "os.system('x')"]] {
            #expect(throws: (any Error).self) { try ManagedPythonPackageSpecParser.parseShell(arguments: arguments) }
        }
    }

    @Test("Direct URLs, paths and shell syntax never become package specs")
    func directSpecsRejected() {
        for spec in ["https://example.com/a.whl", "../local.whl", "/tmp/a.whl",
                     "git+https://example.com/x", "requests;print(1)"] {
            #expect(throws: (any Error).self) { try ManagedPythonPackageSpecParser.validate(spec) }
        }
        #expect(throws: Never.self) { try ManagedPythonPackageSpecParser.validate("requests==2.32.4") }
    }
}
