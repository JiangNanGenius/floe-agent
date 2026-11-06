# Floe Chemistry predevelopment

Independent iPad-first chemistry project, native editor and calculation service. This package does not change Floe's App entrypoints, versions, distribution or permission system.

## Components

- `FloeChemistryCore`: multi-object projects, exact input snapshots, atom/charge-conserving reaction balancing, spectrum analysis, KET drawing graph, revision storage and conflict recovery.
- `FloeChemistryEngine`: Avogadro native backend, configured environment adapter, service-owned calculations, cancellation, explicit result application, task-bound tool sessions.
- `FloeChemistryUI`: SwiftUI workbench/document/inspector, UIKit chemistry canvas with Apple Pencil interactions, native Core Graphics structure drawing, native RealityKit 3D view, import/export and history.
- `../FloeChemistrySketch`: offline Indigo conversion and layout behind `ChemistryStructureProcessor`. Its WKWebView is offscreen and is never part of the native editor's input/rendering surface. The earlier `ChemistrySketchView` remains a research reference.

The native drawing owns the lossless KET document. It preserves unknown fields and rejects edits requiring unsupported group-reference remapping. It supports atom/bond edits, charge/isotope properties, wedge/hashed/either bonds, ring templates, selection/movement, arrows, text, clipboard insertion, undo and redo. This is an initial native editor, with complex group editing and specialized biological notation still in development.

Apple Pencil contact uses UIKit touch events. Coalesced events update selection previews; predicted events are visual only. Ended touches commit the actual position; cancellation commits nothing. Two-finger pan and pinch are independent of drawing. Hover, double tap and squeeze use public UIKit APIs and respect system preferences. Simulator touch evidence does not qualify physical Pencil behavior.

## Data and execution

Provide an explicit `ChemistryProjectStore(root:)` and an authorization callback when constructing `ChemistryService`. A production host must inject Floe's existing project/task permissions; the standalone qualification host only authorizes its own private sample store.

Raw drawing data saves before conversion. Chemical validation failure retains the drawing. A revision conflict preserves a recovery copy; History can restore it as another object. Structure results record the exact input revision, digest, method, options, engine and environment. Applying a stale result fails instead of replacing newer edits. Document blocks reference shared objects.

Original input and rich drawings are retained. CJSON is derived data. Native SMILES parsing rejects stereo it cannot preserve. Diagram formula/mass uses offline Indigo, including implicit hydrogen; the native preview's atom count describes explicitly drawn atoms. Force-field calculations require a prepared 3D structure with explicit hydrogens; a 2D drawing is not silently treated as a prepared force-field model.

Configured backends accept a host-owned closure. `ConfiguredChemistryBackend.worker` exchanges bounded JSON envelopes with an already resolved Floe job/environment adapter. This package never installs packages or launches an arbitrary interpreter from the iPad host. Tool discovery lists the methods actually supplied by configured backends. Task scope is captured by `ChemistryToolSession`, not granted by model arguments or imported files.

## Additional workers

`Backends/chemistry_worker.py` reads one JSON request from stdin and writes one result envelope to stdout. It supplies RDKit descriptors, ETKDG/MMFF/UFF embedding, conformers, similarity, substructure search and reaction rules. `science_worker.py` supplies Gemmi CIF/structure/diffraction analysis and actual CPU OpenMM trajectories. The explicit `openmm.lennardJones` method is a nonbonded particle model; `openmm.system` uses the supplied OpenMM System XML. Neither is presented as automatic protein force-field preparation.

`quantum_worker.py` executes an explicitly configured xTB CLI for GFN0/1/2 single-point calculations and geometry optimization. The trusted environment provides `CHEMISTRY_XTB_EXECUTABLE` and an existing owned `CHEMISTRY_JOB_DIRECTORY`; request data cannot select commands or executable paths. Failed/cancelled jobs retain their artifacts. Energies are in hartree; native UFF and OpenMM energies are in kJ/mol. The xTB runtime is not bundled into the iOS App.

Install the pinned requirements in the user's resolved execution environment, then probe `{"operation":"capabilities","format":"","data":"","options":{}}`. The response includes protocol version, actual engine versions, usable methods and retryable diagnostics. OpenMM creates a tiny real CPU/Reference context; xTB runs a bounded version probe and requires an explicit owned job directory. A development Mac's successful worker tests do not establish App remote-job integration, cloud availability or a real model call.

## External calculation lifecycle

`ChemistryWorkerDeployment.files()` provides the three trusted scripts, pinned requirements and a SHA-256 manifest from the module resource bundle. It verifies the bytes before handing them to the host. Deploy these through Floe's existing environment/jobs lifecycle; no developer interpreter path or package installation runs on the iPad host. `python3 Backends/verify_resources.py --check` is read-only; update the manifest explicitly with `--refresh` after changing worker sources.

After an actual capability probe, the host calls `registerExternalWorker`. `prepareExternal` persists the immutable input and a `ChemistryExecutionOwner` from the genuine task/run. It returns exact worker stdin without dispatching a job. The host submits or hands off the ordinary authorized job, verifies its genuine owner/environment/target/exact payload, then calls `adoptExternal`. `finishExternal` accepts only complete bounded protocol-v1 output matching project, run, attempt, input revision/digest and request checksum. `terminateExternal` records verified failure/cancellation; the host must stop the actual job before recording cancellation. Late results cannot replace terminal state. Reopening reads the saved request and reconciles the same job; it never resubmits it. Restoring history atomically marks historical active calculations interrupted. Applying a result checks its originating completed run in the same commit as the object update.

Protocol v1 hashes the exact UTF-8 `requestJSON` string. The response echoes `identity` and `requestDigest`, along with `protocol: "floe.chemistry.worker"`, `version: 1`, and the actual success/result or failure/error. This avoids cross-language JSON normalization ambiguity. Unbound requests remain supported for capability probes and independent worker qualification, but cannot complete a prepared external run.

Use `importObject(... deferPreparation: true)` for CIF/mmCIF, stereo SMILES or reaction sources awaiting an appropriate worker. The importer exposes “Keep original, process later”; the workbench marks the original as awaiting processing and does not claim calculated properties or preview geometry. Applying a completed structure prefers full MOL data when available and retains the original source. An input snapshot change is rejected even if a revision number is reused.

The App can inject `ChemistryEditorState.calculationHandler` and `cancellationHandler` to use its real jobs adapter; the standalone default remains native execution. Refresh capabilities after probing so the shared inspector sees newly available methods. These callbacks and lifecycle APIs are host seams and do not grant permissions.

## Qualification

Use Xcode 27.2 explicitly. Swift module tests use an isolated internal-SSD scratch directory:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --package-path FloeAgent/Modules/FloeChemistryKit \
  --scratch-path "$HOME/Library/Caches/CodexBuild/FloeChemistry/main/Xcode27.2/swift-core" --jobs 6
```

Generate only the standalone project with `xcodegen generate --spec FloeAgent/Modules/FloeChemistryKit/Qualification/project.yml`. Run UI tests through the repository's canonical iPad lock:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer python3 FloeAgent/scripts/select_test_simulator.py \
  --canonical --with-lock python3 FloeAgent/Modules/FloeChemistryKit/Qualification/run_ipad_tests.py \
  --result-name UNIQUE_EVIDENCE_NAME
```

The runner refuses an occupied device, never creates/clones/resets one, preserves result bundles, and shuts down the task-started device. Use `--only-test native-drawing` for focused drawing iteration. The qualification host and simulator are separate from the actual Floe App and physical-device acceptance.

See the [approved scope](../../../docs/FLOE_CHEMISTRY_PREDEVELOPMENT_QA_PLAN.zh-CN.md). Full App entrypoints, real model calls, remote jobs, local 3D embedding, complex chemical groups and prediction models remain integration/development work.
