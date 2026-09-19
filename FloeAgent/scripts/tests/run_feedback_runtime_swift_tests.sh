#!/bin/bash
# Build and run the Build191 runtime feedback tests without the root package.
#
# Why this exists: the root FloeAgent package build is cloud CI's job. This
# harness compiles only the modules under test (FloeCore, FloeModels,
# FloeTools, FloeSecurity, FloeEnvironments and the focused FloeExecution
# subset) plus the two persistent feedback test files, from the current
# working-tree sources. Nothing is resolved from the network: swift-crypto,
# swift-system and the vendored WasmKit come from this checkout.
#
# Usage:
#   FloeAgent/scripts/tests/run_feedback_runtime_swift_tests.sh [--filter PATTERN]
#
# Environment:
#   DEVELOPER_DIR   Xcode used for `swift test` (default /Applications/Xcode-beta.app/Contents/Developer)
#   HARNESS_SCRATCH directory for the generated package (default $TMPDIR/...)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
REPO="$ROOT/FloeAgent"

FILTER_ARGS=()
if [ "${1:-}" = "--filter" ]; then
  FILTER_ARGS=(--filter "${2:?pattern required}")
fi

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode-beta.app/Contents/Developer}"
SWIFT="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift"
[ -x "$SWIFT" ] || { echo "swift not found under DEVELOPER_DIR=$DEVELOPER_DIR" >&2; exit 2; }

CRYPTO="$REPO/.build/checkouts/swift-crypto"
SYSTEM="$REPO/.build/checkouts/swift-system"
WASMKIT="$REPO/ThirdParty/WasmKit"
for dir in "$CRYPTO" "$SYSTEM" "$WASMKIT"; do
  [ -d "$dir" ] || { echo "missing dependency checkout: $dir" >&2; exit 2; }
done

SCRATCH="${HARNESS_SCRATCH:-${TMPDIR:-/tmp}/floe-feedback-runtime-swift}"
PKG="$SCRATCH/package"
if [ "${HARNESS_CLEAN:-0}" = "1" ]; then rm -rf "$SCRATCH"; fi
mkdir -p "$PKG/Sources" "$PKG/Tests" "$PKG/vendor"
# Sources are re-copied on every run so the harness always tests the current
# working tree; the SwiftPM build directory is kept for incremental runs.
rm -rf "$PKG/Sources" "$PKG/Tests"

copy_tree() {
  local src="$1" dst="$2"
  mkdir -p "$dst"
  (cd "$src" && tar cf - .) | (cd "$dst" && tar xf -)
}

echo "== staging focused sources in $PKG"
for module in FloeCore FloeModels FloeTools FloeSecurity FloeEnvironments FloeExecution; do
  copy_tree "$REPO/Sources/$module" "$PKG/Sources/$module"
done
# Only WasmKit is copied: its Package.swift is patched to stay offline. The
# other dependencies are referenced in place so the harness stays cheap.
[ -e "$PKG/vendor/swift-crypto" ] || ln -s "$CRYPTO" "$PKG/vendor/swift-crypto"
[ -e "$PKG/vendor/swift-system" ] || ln -s "$SYSTEM" "$PKG/vendor/swift-system"
[ -e "$PKG/vendor/ZIPFoundation" ] || ln -s "$REPO/.build/checkouts/ZIPFoundation" "$PKG/vendor/ZIPFoundation"
if [ ! -e "$PKG/vendor/WasmKit/Package.swift" ]; then copy_tree "$WASMKIT" "$PKG/vendor/WasmKit"; fi

# The vendored WasmKit declares swift-system by URL. Point it at the copied
# checkout so resolution stays offline and deterministic.
if ! grep -q 'path: "../swift-system"' "$PKG/vendor/WasmKit/Package.swift"; then
python3 - "$PKG/vendor/WasmKit/Package.swift" <<'PY'
import re, sys
path = sys.argv[1]
text = open(path).read()
patched = re.sub(r'\.package\(url:\s*"https://github\.com/apple/swift-system",\s*from:\s*"[^"]+"\)',
                 '.package(path: "../swift-system")', text)
assert patched != text, "WasmKit swift-system dependency was not patched"
open(path, "w").write(patched)
PY
fi

mkdir -p "$PKG/Tests/FloeExecutionTests" "$PKG/Tests/FloePackagesTests"
cp "$REPO/Tests/FloeExecutionTests/feedback_RuntimeShellGateTests.swift" "$PKG/Tests/FloeExecutionTests/"
cp "$REPO/Tests/FloePackagesTests/feedback_PythonEnvironmentPathTests.swift" "$PKG/Tests/FloePackagesTests/"

cat > "$PKG/Package.swift" <<'SWIFT'
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FeedbackRuntimeHarness",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "vendor/swift-crypto"),
        .package(path: "vendor/swift-system"),
        .package(path: "vendor/ZIPFoundation"),
        .package(path: "vendor/WasmKit"),
    ],
    targets: [
        .target(
            name: "FloeCore",
            dependencies: [.product(name: "Crypto", package: "swift-crypto")],
            path: "Sources/FloeCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "FloeModels",
            dependencies: ["FloeCore", .product(name: "Crypto", package: "swift-crypto")],
            path: "Sources/FloeModels",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "FloeTools",
            dependencies: ["FloeCore", "FloeModels", .product(name: "Crypto", package: "swift-crypto")],
            path: "Sources/FloeTools",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "FloeSecurity",
            dependencies: ["FloeCore", "FloeModels", .product(name: "Crypto", package: "swift-crypto")],
            path: "Sources/FloeSecurity",
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "FloeEnvironments",
            dependencies: ["FloeCore", "FloeTools"],
            path: "Sources/FloeEnvironments",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "FloeExecution",
            dependencies: [
                "FloeCore", "FloeTools", "FloeSecurity",
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
                .product(name: "WasmKit", package: "WasmKit"),
                .product(name: "WasmKitWASI", package: "WasmKit"),
                .product(name: "SystemPackage", package: "swift-system"),
            ],
            path: "Sources/FloeExecution",
            sources: [
                "HTTPRequestService.swift",
                "LanguagePackageSources.swift",
                "LocalPythonService.swift",
                "ManagedPythonInstallService.swift",
                "ManagedPythonPackageInspector.swift",
                "NodePackageManagerPolicy.swift",
                "ScriptExecutionService.swift",
                "SessionExpiryScheduler.swift",
                "Shell/LocalShellBackend.swift",
                "Shell/LocalShellService.swift",
                "Shell/ShellCommandPolicy.swift",
                "Shell/ShellInputValidation.swift",
                "Shell/ShellOperationJournal.swift",
                "Shell/ShellOutputSanitizer.swift",
                "Shell/ShellSessionCenter.swift",
                "Tools/LocalShellTool.swift",
                "Tools/ShellSessionTools.swift",
                "Packages/WasmEnvironmentContract.swift",
                "Packages/WasmPackageLimits.swift",
                "Packages/WasmRuntime.swift",
                "Packages/WasmKitCommandRuntime.swift",
                "Packages/SignedWasmCapabilityStore.swift",
            ],
            resources: [
                .copy("Resources/RemoteAgent"),
                .process("Resources/CapabilityCatalog.json"),
                .process("Resources/managed_package_remove.py"),
                .process("Resources/managed_package_install.py"),
                .process("Resources/deb_extract.py"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FloeExecutionTests",
            dependencies: [
                "FloeExecution", "FloeCore", "FloeTools",
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Tests/FloeExecutionTests",
            sources: ["feedback_RuntimeShellGateTests.swift"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FloePackagesTests",
            dependencies: ["FloeEnvironments"],
            path: "Tests/FloePackagesTests",
            sources: ["feedback_PythonEnvironmentPathTests.swift"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
SWIFT

echo "== swift test (focused feedback targets)"
if [ ${#FILTER_ARGS[@]} -gt 0 ]; then
  "$SWIFT" test --package-path "$PKG" --scratch-path "$SCRATCH/build" "${FILTER_ARGS[@]}"
else
  "$SWIFT" test --package-path "$PKG" --scratch-path "$SCRATCH/build"
fi
