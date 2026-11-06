# Floe Chemistry native core

Pinned Avogadro Core/IO/Calc/QuantumIO behind a bounded C JSON ABI and a Swift 6 facade. `UPSTREAM.json` records the exact source commit and archive hash. The vendored upstream files and license notices are retained.

`Vendor/FloeChemistryBridge.xcframework` contains real arm64 static frameworks for iOS 26, iOS Simulator and macOS 15. Each framework executable is the original static archive; its Headers and Modules stay under `FloeChemistryBridge.framework` instead of a shared flat `include` output directory. It excludes Qt, desktop OpenGL, Python and optional network/services dependencies. The Swift API is `ChemistryNative.execute(_:cancellation:)`; each native call returns a result or an explicit error envelope. A shared mutex protects the upstream format registry, with an atomic cancellation token for bounded optimizer chunks.

Implemented operations include parsing, analysis, format export, atom/bond editing, UFF energy/geometry optimization, distance/angle/dihedral measurement, crystal supercells and trajectory frame selection. XYZ, MOL/SDF, PDB, CJSON, SMILES and VASP use the upstream formats; QCSchema, Cube, Molden and ORCA use direct QuantumIO adapters. Format support is not a promise that every field survives conversion: callers retain their authoritative input and rich drawing data.

UFF reports kJ/mol, actual iteration count and convergence/stop reason. It does not fall back to a different force field. The native SMILES parser rejects upstream warnings about discarded stereo; a preserving backend must handle those inputs. Atom/index/order, coordinate, nesting, input and calculation limits are enforced. These are bounded native operations, not a generic language executor.

## Build and integrity

The saved artifact was built with Xcode 27.2 (27B52), Apple SDK 27.2, CMake/Ninja and Eigen 5.0.1. Eigen is a build-time header dependency. Its installed license notices are copied under `Licenses/Eigen`; Avogadro's bundled notices remain under `Vendor/avogadrolibs` (including JSON, pugixml, struct and optimization dependencies).

From the repository root:

```sh
python3 FloeAgent/Modules/FloeChemistryNative/Scripts/build_native.py
python3 FloeAgent/Modules/FloeChemistryNative/Scripts/build_native.py --check
```

The build uses six compiler jobs and distinct internal-SSD caches per platform. Each platform library is exported before optional packaging. `BUILD_SAVED.json` retains the compiled source and archive provenance. `PACKAGING_SAVED.json` separately binds the current framework wrapper layout, module map, producer script and exact archive hashes to that compiled receipt. The static-framework migration leaves the original compiled receipt and all three archive byte sequences unchanged. `--check` verifies the real current file set, platform metadata, headers, module exports and unchanged compiled archives; it is read-only and fails instead of updating either receipt. Preserve original failures and artifacts when rebuilding.

To migrate already saved libraries without compiling C++ or running libtool:

```sh
python3 FloeAgent/Modules/FloeChemistryNative/Scripts/build_native.py --repackage-existing
```

The normal build command also emits this namespaced framework layout. A genuine rebuild saves its previous compiled receipt alongside the previous artifact before recording newly compiled inputs; a packaging-only run never rewrites compiled-input pins. `Package.swift` and the Swift/C ABI module names remain unchanged.

The local Apple build and simulator calculation tests qualify this component. They do not establish the full Floe App, remote calculation environments, a physical iPad or an installable App release. Production integration must collect this module's notices into Floe's existing license inventory.
