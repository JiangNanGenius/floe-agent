# Floe Chemistry native core

Pinned Avogadro Core/IO/Calc/QuantumIO behind a bounded C JSON ABI and a Swift 6 facade. `UPSTREAM.json` records the exact source commit and archive hash. The vendored upstream files and license notices are retained.

`Vendor/FloeChemistryBridge.xcframework` contains real arm64 static libraries for iOS 26, iOS Simulator and macOS 15. It excludes Qt, desktop OpenGL, Python and optional network/services dependencies. The Swift API is `ChemistryNative.execute(_:cancellation:)`; each native call returns a result or an explicit error envelope. A shared mutex protects the upstream format registry, with an atomic cancellation token for bounded optimizer chunks.

Implemented operations include parsing, analysis, format export, atom/bond editing, UFF energy/geometry optimization, distance/angle/dihedral measurement, crystal supercells and trajectory frame selection. XYZ, MOL/SDF, PDB, CJSON, SMILES and VASP use the upstream formats; QCSchema, Cube, Molden and ORCA use direct QuantumIO adapters. Format support is not a promise that every field survives conversion: callers retain their authoritative input and rich drawing data.

UFF reports kJ/mol, actual iteration count and convergence/stop reason. It does not fall back to a different force field. The native SMILES parser rejects upstream warnings about discarded stereo; a preserving backend must handle those inputs. Atom/index/order, coordinate, nesting, input and calculation limits are enforced. These are bounded native operations, not a generic language executor.

## Build and integrity

The saved artifact was built with Xcode 27.2 (27B52), Apple SDK 27.2, CMake/Ninja and Eigen 5.0.1. Eigen is a build-time header dependency. Its installed license notices are copied under `Licenses/Eigen`; Avogadro's bundled notices remain under `Vendor/avogadrolibs` (including JSON, pugixml, struct and optimization dependencies).

From the repository root:

```sh
python3 FloeAgent/Modules/FloeChemistryNative/Scripts/build_native.py
python3 FloeAgent/Modules/FloeChemistryNative/Scripts/build_native.py --check
```

The build uses six compiler jobs and distinct internal-SSD caches per platform. Each platform library is exported before optional packaging. `BUILD_SAVED.json` binds the final XCFramework to the wrapper source and binary hashes. `--check` is read-only; a mismatch fails instead of updating the receipt. Preserve the original failures and artifacts when rebuilding.

The local Apple build and simulator calculation tests qualify this component. They do not establish the full Floe App, remote calculation environments, a physical iPad or an installable App release. Production integration must collect this module's notices into Floe's existing license inventory.
