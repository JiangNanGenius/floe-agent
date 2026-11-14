// FloeExecution — retired execution-name fence.
//
// The concrete tool implementations were deleted, but old conversations,
// skill manifests and the approval policy still carry these names. They must
// stay historical strings that can never resolve to a descriptor or runner.

import Foundation
import Testing
@testable import FloeExecution
import FloeTools
import FloeCore

@Suite("Retired execution names stay fenced")
struct RetiredExecutionNamesTests {
    @Test("Production catalog and runner reject all six retired execution names")
    func retiredRuntimesAbsent() {
        let registry = ToolRunnerRegistry()
        registerExecutionTools(registry: registry)
        #expect(RetiredExecutionTools.names == Set([
            "exec.localPython", "exec.javascript", "exec.compatEvaluator", "exec.wasm",
            "python.packages", "wasm.packages",
        ]))
        for name in RetiredExecutionTools.names {
            #expect(registry.runner(named: name) == nil)
            #expect(ToolCatalog.descriptor(named: name) == nil)
        }
    }

    @Test("The dotted and underscore spellings both stay fenced")
    func aliasSpellingsAreFenced() {
        for name in RetiredExecutionTools.names {
            #expect(RetiredExecutionTools.contains(name))
            #expect(RetiredExecutionTools.contains(name.replacingOccurrences(of: ".", with: "_")))
        }
    }
}
