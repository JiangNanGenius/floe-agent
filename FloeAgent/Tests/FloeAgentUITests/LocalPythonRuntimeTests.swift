#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import Testing
import FloeExecution
import FloeTools
@testable import FloeApp

@Suite("FloeApp.BundledPython", .serialized)
struct LocalPythonRuntimeTests {
    @Test("A managed Python HTTP service survives foreground runs and stops only for its owner")
    func persistentHTTPService() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let owner = UUID().uuidString
        defer {
            if !CPythonLocalRuntime.hasActiveWork(environmentID: owner) { try? FileManager.default.removeItem(at: root) }
        }
        let runtime = CPythonLocalRuntime.shared
        let started = await runtime.startService(.init(script: """
            from http.server import HTTPServer, BaseHTTPRequestHandler
            from pathlib import Path
            class Handler(BaseHTTPRequestHandler):
                def do_GET(self):
                    self.send_response(200)
                    self.end_headers()
                    self.wfile.write(b'floe-python-service')
                def log_message(self, *args): pass
            server = HTTPServer(('127.0.0.1', 0), Handler)
            Path('port').write_text(str(server.server_address[1]))
            try: server.serve_forever(poll_interval=0.05)
            finally: server.server_close()
            """, pythonContext: .init(environmentID: owner, workingDirectory: root.path)), environmentID: owner)
        let id = try #require(started.serviceID, "\(started.state): \(started.error ?? "")")
        do {
            let portFile = root.appendingPathComponent("port")
            let deadline = Date().addingTimeInterval(15)
            while !FileManager.default.fileExists(atPath: portFile.path), Date() < deadline {
                try await Task.sleep(for: .milliseconds(25))
            }
            let port = try String(contentsOf: portFile, encoding: .utf8)
            let url = try #require(URL(string: "http://127.0.0.1:\(port)/"))
            let foreground = try #require(CPythonServiceFactory.make())
            for _ in 0..<3 {
                let result = await foreground.run(.init(script: "print('foreground-ready')", timeout: 5), cancellation: nil)
                guard case .ok(_, let output, _, _, _, _) = result else { throw NSError(domain: "PythonServiceTest", code: 1) }
                #expect(output.contains("foreground-ready"))
                let (data, _) = try await URLSession.shared.data(from: url)
                #expect(String(decoding: data, as: UTF8.self) == "floe-python-service")
            }
            #expect(await runtime.stopService(id: id, environmentID: "wrong-owner").state == "notFound")
            #expect(CPythonLocalRuntime.hasActiveWork(environmentID: owner))
            try await runtime.stopServices(environmentID: owner)
            #expect(!CPythonLocalRuntime.hasActiveWork(environmentID: owner))
            #expect(await runtime.serviceStatus(id: id, environmentID: owner).state == "stopped")
            var request = URLRequest(url: url); request.timeoutInterval = 2
            do {
                _ = try await URLSession.shared.data(for: request)
                Issue.record("Stopped Python service still accepts HTTP")
            } catch { /* Connection failure is the required post-stop state. */ }
        } catch {
            try await runtime.stopServices(environmentID: owner)
            throw error
        }
    }

    @Test("Cancelled Python keeps its environment lease and expired queued scripts never run")
    func cancellationAndQueuedDeadline() async throws {
        let service = try #require(CPythonServiceFactory.make())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let token = CancellationToken()
        let id = UUID().uuidString
        let task = Task {
            await service.run(.init(script: "from pathlib import Path; import time; Path('started').write_text('yes'); time.sleep(2); Path('late').write_text('bad')", timeout: 10,
                pythonContext: .init(environmentID: id, workingDirectory: root.path)), cancellation: token)
        }
        let deadline = Date().addingTimeInterval(10)
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent("started").path) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent("started").path))
        token.cancel()
        #expect(await task.value == .cancelled)
        #expect(CPythonLocalRuntime.hasActiveWork(environmentID: id))
        let queued = await service.run(.init(script: "from pathlib import Path; Path('queued-late').write_text('bad')", timeout: 0.05,
            pythonContext: .init(environmentID: id, workingDirectory: root.path)), cancellation: nil)
        guard case .timedOut = queued else { Issue.record("Queued work ignored its deadline: \(queued)"); return }
        while CPythonLocalRuntime.hasActiveWork(environmentID: id) && Date() < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(!CPythonLocalRuntime.hasActiveWork(environmentID: id))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("late").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("queued-late").path))
    }

    @Test("Python execution restores cwd, imports, environment and stdin between projects")
    func projectExecutionScope() async throws {
        let service = try #require(CPythonServiceFactory.make())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for value in ["first", "second"] {
            let directory = root.appendingPathComponent(value)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try "value = '\(value)'".write(to: directory.appendingPathComponent("floe_scope_probe.py"), atomically: true, encoding: .utf8)
            let outcome = await service.run(.init(script: """
                import os, sys, floe_scope_probe
                assert floe_scope_probe.value == os.environ['FLOE_PYTHON_SCOPE']
                assert input() == 'stdin-data'
                assert sys.stdin.read() == 'remainder'
                printJSON({'scope': floe_scope_probe.value})
                """, pythonContext: .init(workingDirectory: directory.path,
                    environment: ["FLOE_PYTHON_SCOPE": value, "PYTHONPATH": directory.path],
                    standardInput: "stdin-data\nremainder")), cancellation: nil)
            guard case .ok(let result, _, _, _, _, _) = outcome else { Issue.record("Scoped Python failed: \(outcome)"); return }
            #expect(result?.contains(value) == true)
        }
        let final = await service.run(.init(script: """
            import os, sys
            assert 'FLOE_PYTHON_SCOPE' not in os.environ
            assert 'floe_scope_probe' not in sys.modules
            print('restored')
            """), cancellation: nil)
        guard case .ok(_, let output, _, _, _, _) = final else { Issue.record("Python scope was not restored"); return }
        #expect(output.contains("restored"))
    }

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
        import markupsafe, importlib.metadata
        assert sys.platform == 'ios'
        assert regex.compile('a+').findall('caaab') == ['aaa']
        assert regex.__version__ == '2026.9.10'
        assert yaml.safe_load('a: 1') == {'a': 1}
        assert yaml.__version__ == '6.0.3'
        assert str(markupsafe.escape('<b>x</b>')) == '&lt;b&gt;x&lt;/b&gt;'
        assert importlib.metadata.version('markupsafe') == '3.0.3'
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
        print(json.dumps({'wheelhouseSmoke': 'passed', 'regex': regex.__version__, 'yaml': yaml.__version__, 'markupsafe': importlib.metadata.version('markupsafe')}, sort_keys=True))
        """, timeout: 30, maxOutputBytes: 4096), cancellation: nil)
        guard case .ok(_, let stdout, let stderr, false, false, _) = outcome else {
            Issue.record("Wheelhouse imports in Floe failed: \(outcome)")
            return
        }
        #expect(stdout.contains("\"wheelhouseSmoke\": \"passed\""))
        #expect(stderr.isEmpty)
    }

    @Test("bundled networking packages verify HTTPS and pytest executes a real test", .timeLimit(.minutes(1)))
    @MainActor func bundledNetworkingAndPytest() async throws {
        let service = try #require(CPythonServiceFactory.make())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("python-presets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let outcome = await service.run(.init(script: """
            import requests, httpx, pytest, pathlib
            assert requests.Session().verify is True
            response = requests.get('https://example.com', timeout=15)
            assert response.status_code == 200 and 'Example Domain' in response.text
            with httpx.Client(timeout=15) as client:
                response = client.get('https://example.com')
                assert response.status_code == 200 and 'Example Domain' in response.text
            pathlib.Path('test_bundled_preset.py').write_text('def test_real_execution():\\n    assert sum([20, 22]) == 42\\n')
            assert pytest.main(['-q', '--capture=sys', '-p', 'no:cacheprovider', '-p', 'no:faulthandler', 'test_bundled_preset.py']) == 0
            print('bundled-network-and-pytest-passed')
            """, timeout: 50, maxOutputBytes: 4096, pythonContext: .init(
                workingDirectory: root.path, environment: ["PYTEST_DISABLE_PLUGIN_AUTOLOAD": "1"])), cancellation: nil)
        guard case .ok(_, let stdout, _, false, _, _) = outcome else {
            Issue.record("Bundled networking/test presets failed: \(outcome)")
            return
        }
        #expect(stdout.contains("1 passed"))
        #expect(stdout.contains("bundled-network-and-pytest-passed"))
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
