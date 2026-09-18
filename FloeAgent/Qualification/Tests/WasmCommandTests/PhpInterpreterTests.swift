import Foundation
import Testing
import FloeCore
import FloeTools
import FloeExecution

/// Executes the compilepending PHP WASI interpreter through the production
/// WASI command runtime. Point FLOE_PHP_WASI at php.wasm (CLI SAPI, preferred)
/// or php-cgi.wasm from ThirdParty/PHPWASI/build_wasi.sh.
///
/// Set FLOE_PHP_SAPI=cgi when the artifact is the CGI SAPI: PHP CGI cannot
/// use `-r` and only reads stdin as an HTTP request body, so the stdin check
/// is skipped and the SAPI difference is recorded instead of hidden.
///
/// Integrated 2026-09-19 from Local/Private/build191-feedback/languages/tests/.
@Suite("PHP interpreter through the WASI command runtime")
struct PhpInterpreterTests {
    private var isCGI: Bool {
        ProcessInfo.processInfo.environment["FLOE_PHP_SAPI"]?.lowercased() == "cgi"
    }

    private func artifact() throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["FLOE_PHP_WASI"], !path.isEmpty else {
            throw FloeError.invalidConfiguration("FLOE_PHP_WASI must name the built PHP wasm")
        }
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FloeError.invalidConfiguration("PHP wasm missing at \(path)")
        }
        return url
    }

    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func run(_ arguments: [String], stdin: String? = nil, root: URL, timeout: TimeInterval = 120) async throws -> ShellRunOutcome {
        await WasmKitCommandRuntime().run(
            moduleURL: try artifact(), arguments: arguments, stdin: stdin, environment: [:],
            rootURL: root, workingDirectory: ".", timeout: timeout, maxOutputBytes: 256 * 1024,
            moduleMaxBytes: 32 * 1024 * 1024, memoryMaxBytes: 256 * 1024 * 1024)
    }

    @Test func versionAndScriptInJail() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        guard case .exited(let versionCode, let versionOut, _, _, _, _) = try await run(["--version"], root: root) else {
            Issue.record("PHP did not start"); return
        }
        #expect(versionCode == 0)
        #expect(versionOut.contains("PHP"))

        let script = """
        <?php
        $file = "/workspace/php-out.txt";
        file_put_contents($file, "sum=" . (2 + 40) . "\\n");
        echo file_get_contents($file);
        echo "args=" . implode(",", array_slice($argv, 1)), "\\n";
        """
        try Data(script.utf8).write(to: root.appendingPathComponent("hello.php"))
        guard case .exited(let code, let stdout, _, _, _, _) = try await run(["-q", "/workspace/hello.php", "alpha", "beta"], root: root) else {
            Issue.record("PHP script did not start"); return
        }
        #expect(code == 0)
        #expect(stdout.contains("sum=42"))
        #expect(stdout.contains("args=alpha,beta"))
        #expect(try String(contentsOf: root.appendingPathComponent("php-out.txt"), encoding: .utf8) == "sum=42\n")
    }

    @Test func phpErrorsAreRecovered() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("<?php throw new RuntimeException('boom');".utf8).write(to: root.appendingPathComponent("boom.php"))
        guard case .exited(let code, _, let stderr, _, _, _) = try await run(["-q", "/workspace/boom.php"], root: root) else {
            Issue.record("PHP did not start"); return
        }
        #expect(code != 0)
        #expect(stderr.contains("boom"))
    }

    @Test func stdinOnlyForTheCLISAPI() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        guard !isCGI else {
            // Documented CGI constraint: stdin is an HTTP request body and
            // needs REQUEST_METHOD/CONTENT_LENGTH, so it is not exercised here.
            #expect(true)
            return
        }
        try Data("<?php echo 'echo:', trim(file_get_contents('php://stdin')), \"\\n\";".utf8)
            .write(to: root.appendingPathComponent("stdin.php"))
        guard case .exited(let code, let stdout, _, _, _, _) = try await run(
            ["-q", "/workspace/stdin.php"], stdin: "来自 stdin", root: root) else {
            Issue.record("PHP did not start"); return
        }
        #expect(code == 0)
        #expect(stdout.contains("echo:来自 stdin"))
    }

    @Test func timeoutAndCancellationStopPurePHPLoops() async throws {
        let root = try root()
        defer { try? FileManager.default.removeItem(at: root) }
        let script = "<?php while (true) {}"
        try Data(script.utf8).write(to: root.appendingPathComponent("loop.php"))
        let token = CancellationToken()
        let canceller = Task { try? await Task.sleep(for: .seconds(5)); token.cancel() }
        let outcome = await WasmKitCommandRuntime().run(
            moduleURL: try artifact(), arguments: ["-q", "/workspace/loop.php"], stdin: nil, environment: [:],
            rootURL: root, workingDirectory: ".", timeout: 120, maxOutputBytes: 64 * 1024,
            moduleMaxBytes: 32 * 1024 * 1024, memoryMaxBytes: 256 * 1024 * 1024, cancellation: token)
        canceller.cancel()
        guard case .cancelled = outcome else {
            Issue.record("A cancelled PHP loop must report cancellation, got: \(outcome)"); return
        }
        guard case .timedOut = try await run(["-q", "/workspace/loop.php"], root: root, timeout: 5) else {
            Issue.record("A bounded PHP loop must time out"); return
        }
    }
}
