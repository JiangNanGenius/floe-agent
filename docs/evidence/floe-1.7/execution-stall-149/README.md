# Build 149 execution stall

Source `9edbeead0038fbe7d64e36c589e7d77a26c8224b`, release run [34744967142](https://github.com/JiangNanGenius/floe-agent/actions/runs/34744967142). The release failed before upload.

The sample shows three Swift cooperative workers blocked in `WasmKitCommandRuntime.Capture.finish` → `dispatch_group_wait`; no pipe reader is running. The run also reported the stale Canvas tool-set assertion and a delayed network timeout.

The next candidate moves blocking WASM execution and DNS lookup work onto independent Dispatch queues, propagates Swift cancellation to the WASM budget, updates the explicit scoped Notes tool assertion, and retains concurrent execution/deadline tests. These samples document the failure, not a passing qualification.

The patched source passed the targeted local execution suite (150 tests, 27 suites) and security suite (83 tests, 11 suites) with Xcode 27.0; `fixed-local-tests.txt` retains results, including 12 parallel WASM commands, task cancellation, and eight concurrent lookup deadlines. The harness links production sources; complete tagged-source cloud qualification remains required.

The scoped-tool policy suite also passed all 12 tests; see `fixed-tool-policy-tests.txt`.
