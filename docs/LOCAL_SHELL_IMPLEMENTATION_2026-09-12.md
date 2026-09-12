# Local execution implementation checkpoint — 2026-09-12

The user deferred the app release while adding more features. No tag, TestFlight
upload or production release is part of this checkpoint.

## Implemented in the working tree

- Validated shell input/cwd/environment, symlink-aware directory resolution,
  bounded/redacted agent output, session ownership/expiry and close races.
- Correct C ABI and stdio inheritance; retained worker state; cancellation and
  monotonic deadlines; bounded continuously drained output pipes.
- Pinned ios_system command binaries, their verified dynamic dependencies,
  and an iOS dash source build for real POSIX scripts. ios_system's built-in
  `sh` alone is not a POSIX interpreter. Removed unavailable framework commands
  from the command dictionaries.
- Local terminal ownership and editor Run/Stop; command contexts bind to the
  originating session/run/workspace, including cwd for file commands.
- Shared managed Python installer, metadata-based distribution discovery,
  rollback-aware RECORD removal, console-script refresh, Python argv/exit codes,
  35 hash-pinned bundled wheels and staged data-only `dpkg -x` extraction.
- Interpreter-only WASI runtime with instruction/deadline/cancellation checks,
  memory/table/file-descriptor limits, shared output cap, stdin and scoped preopens.
  Ed25519 signed capability catalogs, immutable hashed modules, integrity checks
  before execution, receipts and removal. The builder signs a domain-separated
  payload and points catalogs at committed artifact revisions.
- Canonical tool-name migration with historical dotted/wire aliases. Retained
  removed image/hash/SVG/text-edit runners for compatibility while omitting them
  from discovery. Office skill source is updated; signed generated files require
  the existing trusted signing workflow.

## Evidence so far

- Focused Swift regression: 15 tests passed before the final compatibility-list
  regression was added. Rerun results should replace this count when complete.
- Python package payload tests: 7 passed; official skill builder: 4 passed.
- WASI package assembler and temporary-key signing build passed locally.
- iOS bridge compiled against the actual pinned header; the Swift shell backend
  and replacement-command source compiled in a focused host harness.
- Real dash iOS/device and arm64 simulator frameworks built successfully.
- Minimal iOS simulator app and test bundle containing the native engine, dash,
  resources and bridge built successfully. Native test execution encountered
  simulator test-service startup failures; a build is not execution evidence.

## Still required before claiming full completion

1. Native integration/runtime tests and complete app build, including terminal
   input/resize/reopen, interruption completion and resource cleanup.
2. Engine filesystem/cwd/environment isolation: upstream miniRoot is process
   global and does not constrain every file API. The approved workspace boundary
   has not been relaxed. Multiple engine sessions must not be advertised as
   isolated merely because their Swift owners are separate.
3. Official capability/skill signing on the trusted workflow, then verification
   of the resulting app resources and install/run/remove flow.
4. Device import coverage for the bundled Python preset and app-level regressions.

The older draft release notes describe intended behavior. They do not constitute
verification of any outstanding item above.
