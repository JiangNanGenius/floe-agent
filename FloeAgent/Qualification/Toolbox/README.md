# Toolbox native qualification

This focused iOS host renders the production Toolbox catalog and the first and second batches of instrument workbenches. It compiles the production `LocationServicesCenter.swift` and the exact `FloeCore/FloeError.swift` contract in a small framework, without resolving the entire App dependency graph. This is component and service evidence, not a full Floe App build, distribution or physical measurement qualification.

The host has its own bundle ID and storage. It never installs over Floe. The main App's Notes adapter is outside this host; saving a position to Notes requires separate App qualification. A `--location-fixture` launch is clearly labeled synthetic and is only for visual checks. It never reports a fixture as a system fix.

Generate with `xcodegen generate --spec FloeAgent/Qualification/Toolbox/project.yml`. Use Xcode 27.2 and explicit internal-SSD DerivedData through the existing native-build wrapper. Start with six compiler jobs. `TOOLBOX_QUALIFICATION_FLAGS=TOOLBOX_LOCATION_ONLY` compiles only the host's location route during isolated iteration; the complete host builds without either `TOOLBOX_LOCATION_ONLY` or `TOOLBOX_FIRST_BATCH_ONLY`.

Launch arguments:

- `--tool location|level|motion|compass|ruler|measure|calculator|photoMeasure|barometer|sound|magnifier|scanner|timer` opens that workbench.
- `--compact` renders at 390 points inside the same reused iPad. This checks compact layout and is not an iPhone-device claim.
- `--location-fixture` displays a labeled synthetic coordinate on the map, never a user's precise location.
- `--photo-fixture` and `--scanner-fixture` supply labeled synthetic pixels to the real import, measurement, OCR/QR and export-callback paths. They do not start a camera.

Local runs must resolve the canonical existing iPad with `FloeAgent/scripts/select_test_simulator.py --canonical` and serialize the actual device session through `--with-lock`. Supply `-parallel-testing-enabled NO -maximum-concurrent-test-simulator-destinations 1` for tests. Never create, clone, erase or reset a device. Preserve its App/data and restore appearance/content-size settings after checks. Shut down a device started by this task after releasing it.

The unit target covers foreground-owner sharing, late callbacks, background stop, permission revocation, reduced precision, invalid/stale location samples and durable saved-place storage. Module-specific geometry, calibration and calculation tests are included as those implementation lanes complete. Sensor, GPS and real-camera accuracy remain hardware checks.

The dedicated `Timekeeping/project.yml` host separately compiles the actual AlarmKit manager, service, tools, timer card and production alarm widget. Its small chat-scope value contract does not replace full-App inline receipt resolution. `--inline-card-fixture` uses the real tool, SQLite ledger and card with a clearly labeled synthetic native boundary; it creates no system alarm. The ordinary timer tests use real AlarmKit readbacks, including an authoritative timeline; missing or unverified native state fails the system-timer acceptance.

The complete instrument host passed 136 component checks and three second-batch UI cases on 2026-11-11. These include actual bilingual OCR/QR import and TXT callback content, not a Notes/File write. The sound page's compact large-text explanation received one material layout repair; its incremental object build, confirmatory UI check and visual review passed separately. Hardware accuracy and full-App acceptance remain distinct.

The dedicated timekeeping host compiled the real AlarmKit manager, service, tools, card and production widget with Xcode 27.2. Its 84 component checks passed across the original run and a focused fixture-identity correction. The synthetic-boundary card UI passed ticking, pause/resume, external refresh and compact large-text checks; the corrected full-title layout also passed visual review.

After restoring only this host's Alarms permission through its actual Settings page, three real manual-timer UI cases passed on the canonical iPad Simulator. They verify native running/paused/resumed timelines, progress across relaunch, silent multiple timers, stopwatch laps, compact large text and deletion cleanup. Periodic clock reads replaced the continuous animation schedule; the affected UI checks no longer reproduced the earlier animation-idle timeouts. Scoped source, matching App/widget and UI runner artifacts were retained. Physical ringing, full-App answer-body integration and durable model continuation remain separate acceptance outcomes.
