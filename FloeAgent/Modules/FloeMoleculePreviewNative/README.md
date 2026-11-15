# Native molecule preview predevelopment

An independent iOS 26+/macOS 15+ prototype for turning a **molecular graph in a 2D MOL file or SMILES into one 3D preview conformer**. It links RDKit C++ directly; the calculation does not start Python, Linux, a shell, a remote service or a model. No production Floe entrypoint, environment routing, App version or distribution is changed.

```swift
let preview = try await MoleculePreviewNative.generate(
    input: currentMOL, format: .mol
)
// preview.cjson -> existing ChemistryMoleculeView
// preview.molblock -> stereo-preserving derived structure
```

The actual path is parse/validate → explicit hydrogens → ETKDGv3, one conformer → bounded optional MMFF94 optimization → original-atom mapping and coordinates. Specified tetrahedral and double-bond stereochemistry is checked against the generated coordinates. The result also retains engine/method/seed, optimization status and measured calculation time. A preview is not a claim of the global energy minimum, accurate quantum chemistry or protein folding.

The default is MMFF94, 100 optimization-iteration budget and a 3-second cooperative time budget. `converged`, `iterationLimit`, `parametersUnavailable` and `skipped` are distinct. Missing MMFF parameters can retain a valid **unoptimized** preview with an explicit status; the engine never silently switches force fields. UFF and no optimization are explicit options. Optimization iteration usage reports the maximum budget submitted in chunks, not an exact count of internal solver iterations.

Input is capped at 256 KiB, the JSON request at 512 KiB, the graph at 128 input atoms and the explicit-H structure at 384 atoms. Graph-size preflight runs before parsing. This round accepts one connected molecule and rejects incomplete/query atoms and unsupported formats. Cancellation is cooperative between embedding attempts and five-iteration optimizer chunks; RDKit's internal timeout and post-stage checks also apply. These are bounded preview operations, not a hard real-time deadline or a generic executor.

`MoleculePreviewNative.generate` runs the C++ call off the caller's actor and awaits the real worker when cancelling. `MoleculePreviewCancellation` is retained until that call stops. Integration must retain project/object ownership and fence late results by input revision/digest. Generated previews are derived artifacts: do not replace the authoritative KET drawing, original MOL, editor undo stack or scientific calculation input automatically.

## Build and verification

Pins and notices are in `UPSTREAM.json`, `DEPENDENCIES.json` and `Licenses/`. The producer downloads the exact RDKit source archive and applies a small CMake port to build Apple static libraries and include this bridge; upstream numerical sources are unchanged. Only the dependency closure needed by the bridge is compiled. Build scripts use Python on the development Mac; Python is not a runtime dependency of the resulting library.

```sh
/opt/homebrew/bin/python3.12 -B Scripts/build_native.py
/opt/homebrew/bin/python3.12 -B Scripts/build_native.py --check
```

Run from this module for paths above, or use the full script path from the repository root. Default scratch is `~/Library/Caches/CodexBuild/FloeMoleculePreviewNative/main/Xcode27.2`. This round initially used the task-owned repository scratch on the external volume because the internal volume actually ran out of space; later Apple builds used internal scratch after space was recovered. The producer requires 2 GiB available on the actual scratch volume. `--check` is read-only: it checks current bridge/Swift/producer/notice files, every packaged byte, wrapper platform information and the **real arm64 Mach-O platform and deployment target in the archive**. Packaging unchanged native archives does not rewrite their original compiled receipts.

The test-only numerical oracle is `Tests/verify_native.py`; it invokes the real native executable and independently parses its output using a separately selected development RDKit interpreter. It is never shipped or called by the App. `swift test` verifies the real Swift/C boundary. The independent `Qualification` App reuses Floe's 2D editor and RealityKit molecular view; it owns only its own fixture originals and derived cache. `run_simulator.py` must run under the repository's canonical `select_test_simulator.py --canonical --with-lock` wrapper. It preserves failures, exports owned data/screenshots and shuts down a simulator it booted.

Qualification results and handoff are recorded in the dated repository research note. Native library compilation, native numerical tests, the independent App's device link, Simulator interaction and physical-device acceptance are separate evidence levels.

## Next integration boundary

For ordinary preview, expose a direct **3D preview** action. Reuse coordinates already present; otherwise generate locally and show the derived result directly. Cache by project/object identity, exact authoritative input digest, engine/options and revision, with a bounded retention policy. Editing invalidates the old preview. Keep advanced energy/dynamics/quantum jobs on their existing environment path. This prototype does not change their semantics or register a new language-execution tool.
