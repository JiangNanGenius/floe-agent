import Foundation
import XCTest
@testable import FloeExecution

final class LinuxGuestProcessEnvironmentTests: XCTestCase {
    func testScratchPreparationPreservesExactArgvAndSensitiveOverrideNames() {
        let original = ["/bin/sh", "-c", "printf '%s' \"$TMPDIR\"", "argument with spaces", "quote'and\nnewline"]
        let prepared = LinuxGuestProcessEnvironment.preparedArgv(original, excludingTemporaryNames: ["TMPDIR"])
        XCTAssertEqual(Array(prepared.suffix(original.count)), original)
        XCTAssertTrue(prepared[2].contains("mkdir -p -m 700 /var/tmp/floe-runtime"))
        XCTAssertFalse(prepared[2].contains("export TMPDIR="))
        XCTAssertTrue(prepared[2].contains("export TMP="))
        XCTAssertTrue(prepared[2].contains("exec \"$@\""))
        XCTAssertEqual(LinuxGuestProcessEnvironment.preparedArgv(["floe-host", "read", "input.csv"]), ["floe-host", "read", "input.csv"])
        XCTAssertEqual(LinuxGuestProcessEnvironment.preparedArgv([]), [])
    }

    func testGuestPathsDoNotLeakTheHostOrClobberInterpreterActivation() throws {
        let defaults = LinuxGuestProcessEnvironment.defaults(environmentDirectory: "/floe/env/")
        XCTAssertNil(defaults["PATH"])
        XCTAssertEqual(defaults["HOME"], "/floe/env/home")
        for key in ["TMPDIR", "TMP", "TEMP"] {
            XCTAssertEqual(defaults[key], "/var/tmp/floe-runtime")
        }
        XCTAssertFalse(defaults.values.contains { $0.contains(NSHomeDirectory()) })

        #if os(macOS) || os(Linux)
        // Exercise actual shell export semantics: a previously activated guest
        // interpreter must survive, and host temp/locale values must not.
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.environment = [
            "PATH": "/floe/env/usr/bin:/floe/env/python/venv/bin:/usr/bin:/bin",
            "HOME": "/host-only/home", "TMPDIR": "/host-only/ShellTmp",
            "TMP": "/host-only/tmp", "TEMP": "/host-only/temp",
            "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"
        ]
        let exports = defaults.sorted { $0.key < $1.key }.map { key, value in
            "export \(key)='\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
        }.joined(separator: "\n")
        process.arguments = ["-c", exports + "\nprintf '%s\\n' \"$PATH\" \"$HOME\" \"$TMPDIR\" \"$TMP\" \"$TEMP\" \"$LANG\" \"$LC_ALL\""]
        process.standardOutput = output
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(decoding: bytes, as: UTF8.self).split(separator: "\n").map(String.init), [
            "/floe/env/usr/bin:/floe/env/python/venv/bin:/usr/bin:/bin", "/floe/env/home",
            "/var/tmp/floe-runtime", "/var/tmp/floe-runtime", "/var/tmp/floe-runtime", "C.UTF-8", "C.UTF-8"
        ])
        #endif
    }
}

// MARK: - Temp/cache paths

final class LinuxGuestWritablePathsTests: XCTestCase {
    func testAllCachesLiveUnderEnvironmentShare() {
        let vars = LinuxGuestWritablePaths.environmentVariables()
        for key in ["XDG_CACHE_HOME", "PIP_CACHE_DIR", "npm_config_cache"] {
            XCTAssertTrue(vars[key]!.hasPrefix("/floe/env/"), "Caches retain their existing environment share")
        }
        XCTAssertEqual(vars["TMPDIR"], "/var/tmp/floe-runtime")
        XCTAssertEqual(vars["TMP"], "/var/tmp/floe-runtime")
        XCTAssertEqual(vars["TEMP"], "/var/tmp/floe-runtime")
        XCTAssertEqual(vars["XDG_CACHE_HOME"], "/floe/env/cache/xdg")
        XCTAssertEqual(vars["PIP_CACHE_DIR"], "/floe/env/cache/pip")
        XCTAssertEqual(vars["npm_config_cache"], "/floe/env/cache/npm")
        // Source builds use disk scratch instead of RAM-backed /tmp; final
        // package caches retain the existing environment share.
        XCTAssertNotEqual(vars["TMPDIR"], "/tmp")
        let modes = Dictionary(uniqueKeysWithValues: LinuxGuestWritablePaths.bootDirectories.map { ($0.path, $0.mode) })
        XCTAssertEqual(modes["/var/tmp/floe-runtime"], 0o700, "scratch is private to the resolved guest namespace")
    }
}
