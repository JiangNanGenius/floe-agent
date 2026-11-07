# Biology iPad qualification host

This app operates the independent `FloeBiologyKit` package with its own Application Support directory and bundle ID `com.floe.qualification.biology`. It does not alter Floe's main App navigation, version, signing, credentials or release state. It connects the real native service/store; no model or Linux execution account is configured.

Generate the project from this directory's `project.yml`:

```sh
xcodegen generate --spec FloeAgent/Qualification/Biology/project.yml
```

Use Xcode 27.2 and the repository's existing native-build window. Build scheme `BiologyQualificationUI`, project `FloeAgent/Qualification/Biology/FloeBiologyQualification.xcodeproj`, for `generic/platform=iOS Simulator`, with six jobs and explicit internal-SSD DerivedData. `build-for-testing` compiles both the actual host and its UI tests. The main App's `project.yml` is not modified.

Run `test-without-building` only on the canonical reused iPad selected by `FloeAgent/scripts/select_test_simulator.py --canonical --with-lock`. Acquire the shared native window before the simulator lock, preserve existing apps/data, disable parallel testing and use only one destination. Do not create, clone, erase or target a physical iPhone. Shut down a simulator started by this run after exporting evidence.

`UITests.swift` exercises five actual calculations and expected results, note persistence across app termination/reopen, native sequence editing/undo/redo, protein rotation/fit in landscape, native ribbon/Newick/density views, actual tool edits reflected in the live viewport, Chinese dark/high-contrast views and the Files export surface. Files-provider save completion, physical Pencil and full-App/model/Linux integration are not implied by these checks.

`testNotesSaveAcknowledgedBeforeReopen` independently verifies the save acknowledgement before process termination and waits for the stored text after relaunch. Reuse unchanged domain evidence when fixing this boundary; do not repeat the whole scientific matrix for a note-editor correction. Capture the foreground screen with `XCUIScreen.main.screenshot()`; App-region captures in this Simulator/Xcode pair produced a rotated crop and are retained as diagnostic evidence.

Use **Open a complete example project** to create an independent project containing all five domains plus synthetic Newick and MRC data. All synthetic samples are labeled; ubiquitin uses actual RCSB data. Dataset switching is available in the native **Research materials** menu in portrait and the left sidebar at wider widths. Analysis parameters, data editing, run status, result/data switching and export are available from the toolbar. Each test creates uniquely named data and never resets the existing store.

Qualification-only launch options `--biology-qa-dark` and `--biology-qa-contrast` change this window's appearance. They do not modify global Simulator settings.

`Automation tools` opens an explicitly diagnostic console with the real scoped tool descriptors, exact JSON parameters and actual responses. The host constructs a task-owned `BiologyToolSession`; this exercises real services without pretending to be a model conversation. Clear/Finish editing controls make parameters editable with the iPad keyboard. `testToolEditsUpdateLiveView` verifies exact submitted JSON, the committed revision and the changed native sequence; it does not accept a success label alone. `Recently Deleted` restores the real retained project revisions.

The host owns a `BiologyWorkspaceFiles` store. Large originals can be imported as references and streamed to a native Files export picker without turning the file into one in-memory document. The large TIFF view needs a real configured scientific environment; the standalone host honestly keeps it unconfigured. A saved AI `micro.tile` result can be reopened directly in that native view.

Round-two results and limitations are recorded in [component closure evidence](../../../docs/FLOE_BIOLOGY_COMPONENT_CLOSURE_20261107.zh-CN.md). Previous failures remain in the private evidence; a rerun does not erase them.

`testVisualWorkbenchPortraitAndLandscape` collects the library, sequence, atom/backbone/ribbon, microscopy, labeled heatmap, reaction network/result, Newick and density surfaces in one bounded pass. It rotates the real native 3D view on the canonical iPad, fits in landscape, and calculates an actual network result. Run it with the existing Chinese dark/export and tool-edit cases when qualifying this UI batch. Numerical ribbon continuity is checked separately in Core; rendering normals/light do not change measured coordinates or voxel values.

`testFramedControlsUseTheirFullHitArea` taps blank space inside the record, gene, cell and method fields, verifies the 44-point selection targets, checks the actual GENE_C / Cell_B2 value (11), scrolls the native analysis inspector to its remaining rows, and runs a real structure calculation with the pinned Run button. The historical off-screen Form-row failure remains in the evidence. Selection fields, secondary actions and text editors share native framed components; system toolbar, segmented and list controls retain their native affordances.

`testAuxiliaryPanelsRemainUsable` walks sequence/annotation/network editing, notes, history, rename, the unconfigured assistant and real tool console without discarding existing data. Select the actual sequence before entering its editor; the complete sample project initially selects its final imported dataset. Native menu sections in this Simulator expose their visible action labels while dropping the custom action IDs, so edit routes are tested through their English labels. The visual walkthrough also verifies that the landscape inspector preserves the scientific viewport and that Run cannot cover its method field. Preserve assertion failures and any test-runner termination separately from passing checks.

The [UI qualification record](../../../docs/FLOE_BIOLOGY_UI_POLISH_20261107.zh-CN.md) keeps the antialiasing, framed-control and screenshot evidence separate from full-App acceptance.

The space-utilization increment adds measured-coordinate camera-framing tests for atoms, the real ribbon and a density mesh at portrait and landscape aspects. The visual walkthrough records viewport and parameter rectangles, requires the landscape viewport to retain over 68% of the window width and 65% of its height, keeps the common parameter group below 190 points, and verifies all four selection targets remain hittable and at least 44 points high. The framed-controls case still performs actual selection changes and a structure calculation; numerical and full-App qualification remain separate.
