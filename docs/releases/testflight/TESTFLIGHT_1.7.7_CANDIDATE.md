# Floe Agent 1.7.7 (Build 248) — qualification failed

Immutable tag `v1.7.7` fixes source `f98a2447b67463ebc599145db39aa3112ad926e3`. The [normal release run](https://github.com/JiangNanGenius/floe-agent/actions/runs/37185788860) failed the development-SDK full Swift regression before App UI qualification; the release gate therefore prevents signing and TestFlight upload. NativeNotes development qualification passed.

The failing test was `LinuxGuestMetricsSamplerTests.samplingStopsWithLastConsumer`: it asserted that the first guest command had run immediately after observing a registered consumer, although sampling starts on a separate asynchronous task. The runner had not yet recorded an invocation. The original failure log is retained in the workflow run. Build 249 changes the test to wait for the first actual invocation within a finite deadline and keeps the assertion that the sampling loop stops when its last consumer leaves. The focused local test executed and passed (1 test, 0 failures).

The accepted-SDK job was still completing when this candidate record was written. Any retained device artifact is a recovery input, not a signed upload or installable TestFlight build. Its final outcome is verified separately in the workflow run.
