#if canImport(SwiftUI) && canImport(UIKit)
import Testing
import FloeExecution
@testable import FloeApp

@Suite("FloeApp.BundledPython", .serialized)
struct LocalPythonRuntimeTests {
    @Test("pandas runs natively inside the actual Floe CPython runtime offline")
    @MainActor func nativePandasWorkflow() async throws {
        let service = try #require(CPythonServiceFactory.make())
        let outcome = await service.run(ScriptExecutionRequest(script: """
        import io, json, sys
        try:
            import numpy as np
            import pandas as pd
            import PIL
        except Exception:
            import traceback
            traceback.print_exc()
            raise
        assert sys.platform == 'ios'
        assert pd.__version__ == '3.0.5'
        frame = pd.read_csv(io.StringIO('team,value\\na,1\\na,2\\nb,4\\n'))
        assert frame.groupby('team')['value'].sum().to_dict() == {'a': 3, 'b': 4}
        assert frame.loc[frame['value'] > 1, 'value'].tolist() == [2, 4]
        merged = frame.merge(pd.DataFrame({'team': ['a','b'], 'label': ['A','B']}), on='team')
        assert merged['label'].tolist() == ['A','A','B']
        assert pd.Series([1, None, 3]).fillna(0).tolist() == [1, 0, 3]
        assert pd.to_datetime(['2026-09-07T00:00:00Z'], utc=True).tz_convert('Australia/Sydney')[0].hour == 10
        assert pd.read_json(io.StringIO(frame.to_json())).equals(frame)
        print(json.dumps({'runtime': sys.platform, 'pandas': pd.__version__, 'nativeSmoke': 'passed'}, sort_keys=True))
        """, timeout: 30, maxOutputBytes: 4096), cancellation: nil)
        guard case .ok(_, let stdout, let stderr, false, false, _) = outcome else {
            Issue.record("Native pandas in Floe failed: \(outcome)")
            return
        }
        #expect(stdout.trimmingCharacters(in: .whitespacesAndNewlines) == #"{"nativeSmoke": "passed", "pandas": "3.0.5", "runtime": "ios"}"#)
        #expect(stderr.isEmpty)
        let manifest = await service.runtimeManifest()
        #expect(manifest.contains("3.0.5"))
    }

    @Test("wheelhouse packages import inside the bundled runtime")
    @MainActor func wheelhousePackagesImport() async throws {
        let service = try #require(CPythonServiceFactory.make())
        let outcome = await service.run(ScriptExecutionRequest(script: """
        import json, sys
        import regex
        import yaml
        import markupsafe
        assert sys.platform == 'ios'
        assert regex.compile('a+').findall('caaab') == ['aaa']
        assert regex.__version__ == '2026.9.10'
        assert yaml.safe_load('a: 1') == {'a': 1}
        assert yaml.__version__ == '6.0.3'
        assert str(markupsafe.escape('<b>x</b>')) == '&lt;b&gt;x&lt;/b&gt;'
        assert markupsafe.__version__ == '3.0.3'
        import zstandard, brotli, greenlet, frozenlist, multidict
        data = b'floe wheelhouse smoke' * 64
        assert zstandard.ZstdDecompressor().decompress(zstandard.ZstdCompressor().compress(data)) == data
        assert brotli.decompress(brotli.compress(data)) == data
        g = greenlet.greenlet(lambda: 42)
        assert g.switch() == 42
        fl = frozenlist.FrozenList([1, 2]); fl.freeze()
        assert list(fl) == [1, 2]
        md = multidict.CIMultiDict([('Key', 'a'), ('key', 'b')])
        assert md.getall('KEY') == ['a', 'b']
        print(json.dumps({'wheelhouseSmoke': 'passed', 'regex': regex.__version__, 'yaml': yaml.__version__, 'markupsafe': markupsafe.__version__}, sort_keys=True))
        """, timeout: 30, maxOutputBytes: 4096), cancellation: nil)
        guard case .ok(_, let stdout, let stderr, false, false, _) = outcome else {
            Issue.record("Wheelhouse imports in Floe failed: \(outcome)")
            return
        }
        #expect(stdout.contains("\"wheelhouseSmoke\": \"passed\""))
        #expect(stderr.isEmpty)
    }

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
