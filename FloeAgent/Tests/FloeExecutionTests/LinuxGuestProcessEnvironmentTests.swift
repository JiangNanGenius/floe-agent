import Foundation
import XCTest
@testable import FloeExecution

final class LinuxGuestProcessEnvironmentTests: XCTestCase {
    func testGuestPathsDoNotLeakTheHostOrClobberInterpreterActivation() throws {
        let defaults = LinuxGuestProcessEnvironment.defaults(environmentDirectory: "/floe/env/")
        XCTAssertNil(defaults["PATH"])
        XCTAssertEqual(defaults["HOME"], "/floe/env/home")
        for key in ["TMPDIR", "TMP", "TEMP"] {
            XCTAssertEqual(defaults[key], "/floe/env/tmp")
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
            "/floe/env/tmp", "/floe/env/tmp", "/floe/env/tmp", "C.UTF-8", "C.UTF-8"
        ])
        #endif
    }
}
