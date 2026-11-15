// SPDX-License-Identifier: MPL-2.0
import Foundation

if CommandLine.arguments.contains("--cli") {
    exit(SampleCLI.run())
}

#if canImport(AppKit)
SampleGUI.run()
#else
print("floe-game-editing-sample: GUI host is available on macOS; use --cli anywhere.")
exit(SampleCLI.run())
#endif
