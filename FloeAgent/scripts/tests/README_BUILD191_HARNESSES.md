# Build191 feedback harnesses (runtime review + integrated reviewers)

These harnesses verify the Build191 feedback repairs without the root SwiftPM
package, an App build, a simulator or a device. They compile and run the
current working-tree sources with `swiftc`/`clang++` from a cached local build
or a focused offline SwiftPM package. They are host checks, not iOS
acceptance: device behavior stays with the user's manual pass.

## Runtime harnesses

| Harness | Verifies | Dependencies |
| --- | --- | --- |
| `run_feedback_runtime_swift_tests.sh` | The two persistent feedback test files (`Tests/FloeExecutionTests/feedback_RuntimeShellGateTests.swift`, `Tests/FloePackagesTests/feedback_PythonEnvironmentPathTests.swift`): gate busy vs timeout, byte counters, session close, download token forwarding, node manager selection, writable PYTHONPATH ordering. | Xcode-beta `swift test`; offline package assembled from this checkout (swift-crypto, swift-system, ZIPFoundation checkouts + vendored WasmKit). |
| `run_feedback_shell_bridge_host.sh` | The real `FloeShellBridge.mm` compiled for macOS against a scripted stub engine: run gate Busy vs TimedOut, cancellation, detached-worker recovery, readiness drain, descriptor claim/close/end ownership. | Xcode clang++; no iOS SDK needed. |
| `test_feedback_python_runner.py` | The real `FloeCPythonBridge.m` runner string executed in desktop CPython: cross-environment module eviction, writable-root precedence before/after first install, `importlib.metadata` versions across runs. | `python3` (3.9+; 3.9 needs the underscore dist-info spelling, documented inline). |
| `run_feedback_http_cancel_probe.sh` | The real `HTTPRequestService.download` observing an in-flight cancellation token against a stalling localhost server. | `swiftc` + cached `FloeCore`/`FloeTools` module/libs from a prior local build. |

## Integrated independent-review harnesses

| Harness | Verifies | Dependencies |
| --- | --- | --- |
| `ide_review/run_git_review_harness.sh` (`git_main.swift`, 71 checks) | Real libgit2 behavior of `FloeGit`: fast-forward retargeting, conflict paths, staged-aware discard, safety refusals. | `swiftc` + cached `libgit2.o`/module map/SwiftGitX checkout from a prior local build. |
| `ide_review/review_invariants.py` (21 checks) | Reviewed IDE/Office fixes stay in place (fast-forward target, release latch, embedded surface ownership, tab teardown). | `python3`. |
| `test_release_review_workflows.py` (32 checks) | Release workflow ordering/portability/publishing policy against `.github/workflows` + the real preflight script, including the no-`plutil` Linux path. | `python3` + PyYAML. |
| `test_verify_direct_unsigned_artifact.py` | The real `scripts/verify_direct_unsigned_artifact.py`: symbols-artifact policy, accepted-upload evidence, provenance, zip extraction safety. | `python3`. |
| `run_readonly_permission_fixture.py` | The shipped editor permission scripts extracted from `FloeOfficeNative.mm`: readonly grants are never elevated, edit-password stays readonly. | `python3` + `node`. |
| `validate_rich_pptx.py` | Independent python-pptx/openpyxl read-back of a generated deck (optional qualification tool). | `python3` + python-pptx + openpyxl. |

`Tests/FloeDocumentsTests/RichDeckChecksTests.swift` is the ported Swift Testing
rich-deck suite. **Do not run it until the FloeDocuments chart-workbook marker
patch (`ppt/embeddings/floe-chart-data-<n>.xlsx`) lands**; the private fail
evidence at `Local/Private/build191-feedback/ppt/tests/results.log` is retained.

## Environment notes

* `run_feedback_runtime_swift_tests.sh` needs Xcode-beta (its macOS Testing
  framework) and stays offline; `HARNESS_CLEAN=1` rebuilds from scratch.
* `run_feedback_http_cancel_probe.sh` and `ide_review/run_git_review_harness.sh`
  use cached artifacts from a previous local build. If the cache came from
  Xcode rather than Command Line Tools, set `DEVELOPER_DIR` accordingly and
  match the module cache to the same compiler; mixing 6.4.0.34.1 and
  6.4.0.30.4 modules is rejected by design.
* None of these harnesses is part of the root `swift test` matrix and none of
  them performs an App build.
