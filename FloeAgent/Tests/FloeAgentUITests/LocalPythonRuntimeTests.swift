#if canImport(SwiftUI) && canImport(UIKit)
import Testing
import FloeExecution
@testable import FloeApp

@Suite("FloeApp.BundledPython")
struct LocalPythonRuntimeTests {
    @Test("the packaged CPython runtime imports the zipped stdlib and executes")
    @MainActor
    func bundledRuntimeSmokeTest() async throws {
        do {
            _ = try FloeCPythonBridge.runtimeVersion()
        } catch {
            Issue.record("CPython initialization failed: \(error.localizedDescription)")
            return
        }
        let service = try #require(CPythonServiceFactory.make())
        let outcome = await service.run(
            ScriptExecutionRequest(
                script: """
                import dis, json, math, select, struct, _opcode
                packed = struct.pack('>I', input['value'])
                print(json.dumps({
                    'answer': input['value'] * 2,
                    'sqrt': math.isqrt(1764),
                    'packed': len(packed),
                    'select': hasattr(select, 'select'),
                    'opcode': hasattr(_opcode, 'stack_effect'),
                    'dis': hasattr(dis, 'dis')
                }, sort_keys=True))
                """,
                inputJSON: #"{"value":21}"#,
                timeout: 5,
                maxOutputBytes: 4_096
            ),
            cancellation: nil
        )
        guard case .ok(_, let stdout, let stderr, false, false, _) = outcome else {
            Issue.record("Bundled CPython failed: \(outcome)")
            return
        }
        #expect(stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            == #"{"answer": 42, "dis": true, "opcode": true, "packed": 4, "select": true, "sqrt": 42}"#)
        #expect(stderr.isEmpty)
    }
}
#endif
