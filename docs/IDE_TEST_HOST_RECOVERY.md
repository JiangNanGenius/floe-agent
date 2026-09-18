# IDE test host recovery

Dispatch-only recovery of the dual-device IDE UI qualification from an already
compiled test host. The entry never rebuilds the App, never reacts to `push` or
pull requests and never distributes anything. It exists because the ~9-minute
App `build-for-testing` phase is expensive, while the compiled host is uploaded
before UI execution and remains reusable until its seven-day retention ends.

Workflow: [`.github/workflows/ide-host-recovery.yml`](../.github/workflows/ide-host-recovery.yml).
Verifier: [`FloeAgent/scripts/verify_compiled_test_host.py`](../FloeAgent/scripts/verify_compiled_test_host.py).
Fixtures: [`FloeAgent/scripts/tests/test_compiled_test_host_recovery.py`](../FloeAgent/scripts/tests/test_compiled_test_host_recovery.py).

## Trust model

`ci.yml` retains the whole compiled `Build/Products` tree (xctestrun, App,
`FloeAgentUITests-Runner.app`) as `compiled-test-host-<source-sha>` only after a
successful `build-for-testing`. The recovery entry accepts that artifact only
after proving, per device leg, that:

1. the run belongs to `JiangNanGenius/floe-agent` and the trusted
   `.github/workflows/ci.yml`;
2. the run event is `push` or `workflow_dispatch`; `pull_request`,
   `pull_request_target`, `workflow_run` and `issue_comment` are rejected;
3. the run `head_sha` equals the requested full 40-hex `source_sha`, and the
   requested run id and attempt match;
4. exactly one non-expired artifact named `compiled-test-host-<source_sha>`
   exists and its `workflow_run.id` is the requested run;
5. the `Upload recoverable compiled test host` step is `success`. The run's own
   conclusion and the UI step are deliberately **not** required: recovery exists
   for hosts whose UI phase never finished, failed, or is still running;
6. **before anything is downloaded or extracted**, the executing runner's real
   `xcodebuild -version` output equals the requested `xcode_version`/`xcode_build`
   and `xcrun --sdk iphonesimulator --show-sdk-version` reports major 27. The
   archive's `TOOLCHAIN.txt` is only ever compared against a toolchain that the
   runner actually exposes, so a mismatched `xcode-27` runner is refused;
7. the archive's `SOURCE-SHA.txt`, `SOURCE-RUN.txt`, `SOURCE-ATTEMPT.txt` and
   `TOOLCHAIN.txt` match the request;
8. `Products.tar.gz` matches both its embedded `Products.tar.gz.sha256` and the
   pinned digest input (the pin may be cleared for other hosts);
9. the tar archive contains no absolute path, no `..` component, no NUL, drive
   or backslash name and no member that resolves outside the destination, and
   it contains **only regular files and directories**. Every symlink, hardlink,
   device, FIFO and other special member is rejected, and two members that
   normalize to the same path (for example `Products` and `Products/`) are
   refused, so an ordered symlink chain or a duplicate-name race cannot reach
   the filesystem. The real host is a plain file/directory tree; framework-style
   link members are deliberately not supported;
10. exactly one `*.xctestrun` and the `FloeAgentUITests-Runner.app` runner exist
    under the extracted `Products` directory.

Only then is the xctestrun path handed to `xcodebuild`. The runner toolchain
check and all archive validation happen before any extraction, and a non-empty
extraction directory is refused so a retry can never mix hosts.

## Dispatch inputs

| Input | Meaning |
| --- | --- |
| `source_sha` | Full 40-hex CI commit that built the host (required) |
| `source_run` | Trusted CI run id that uploaded the host (required) |
| `source_attempt` | Run attempt that uploaded the host (default `1`) |
| `xcode_version` | Exact Xcode version in `TOOLCHAIN.txt` (default `27.0`) |
| `xcode_build` | Exact Xcode build in `TOOLCHAIN.txt` (default `27A5252f`) |
| `products_sha256` | Independent digest pin; empty clears the pin |

## What runs

A cheap `validate-controller` job first runs the fixture suite on Ubuntu. The
`recover-ide-ui` job then runs on the `xcode-27` runner with
`fail-fast: false` and a matrix of `iPad mini (A17 Pro)` (`ipad`) and
`iPhone 17 Pro` (`iphone`), so one failing device never cancels the other.

Each leg checks out two trees:

* `original-source` at `inputs.source_sha`, which supplies the original
  `select_test_simulator.py`, `run_test_with_diagnostics.py`,
  `verify_ide_ui_xcresult.py` and `WorkspaceIDEUITests` the host was built
  against;
* `recovery-controller` at the executing workflow commit, which supplies
  `verify_compiled_test_host.py`. The verifier is never taken from the older
  source, where it does not exist.

Each leg then verifies the runner toolchain, downloads the host, verifies it,
boots the selected iOS 27 simulator, and runs
`FloeAgentUITests/WorkspaceIDEUITests` with
`CODE_SIGNING_ALLOWED=NO test-without-building`. The runner toolchain check runs
first: it executes `xcodebuild -version` and
`xcrun --sdk iphonesimulator --show-sdk-version` on the runner and refuses a
version/build mismatch or an SDK major other than 27 before any artifact is
downloaded or extracted. The three original cases
(native workbench save/cold reopen, engineering DXF inline/full screen, DWG
edit save/cold reopen) must all pass with zero skips; the original
`verify_ide_ui_xcresult.py` enforces that. The IDE mode retains its configured Xcode test retry (at most two
iterations), plus one wrapper retry for a stall before any test started.
These retries must remain visible in the retained evidence. Per-attempt logs, xcresults, screenshots, recordings, the run
metadata and the verification report are uploaded as
`ide-host-recovery-<device>-<source_sha>` for seven days.

## Reference host

The first intended host is retained in `Local/Artifacts/build179-test-host/`
(local, Git-ignored):

* source run `35223435570`, source `2e2a34c9f9d6a06d10b804df81ee1d92ec3f1381`,
  attempt `1`, artifact `10497993199`;
* `Products.tar.gz` SHA-256
  `abfc75f5d8b30de8c34b9a3e575efa24a8671e71f4d6f5e9508f4fd671d6d250`;
* toolchain `Xcode 27.0` / `27A5252f`;
* `Products/FloeAgent_iphonesimulator27.0-arm64.xctestrun` and
  `Products/Debug-iphonesimulator/FloeAgentUITests-Runner.app`.
* the archive has 16,743 members, all regular files or directories, with no
  symlink, hardlink, device/FIFO member or duplicate normalized path, so the
  minimal file/directory-only extraction accepts the genuine host.

Read-only verification at implementation time confirmed the archive layout,
the embedded `SOURCE-*`/`TOOLCHAIN` files, the local ZIP SHA-256 and the live
run metadata (`Upload recoverable compiled test host` = success; the IDE step
also later reported success). This task did **not** execute the recovery
workflow, rerun the UI tests, or produce a new build/device artifact.

## Verification

Run the fixtures and the workflow linter locally:

```
python3 -m unittest discover -s FloeAgent/scripts/tests -p test_compiled_test_host_recovery.py
actionlint .github/workflows/ide-host-recovery.yml
```

The fixtures cover a genuine host, a foreign repository, an untrusted workflow,
an external pull-request event, short or mismatched SHAs, mismatched run and
attempt, a missing/expired/duplicate artifact, a run that never uploaded a host,
a failed upload step, digest and toolchain mismatches, `..`/absolute traversal,
symlink, hardlink, chained-symlink and duplicate-path members, FIFO members and
missing xctestrun/runner. Static fixtures also pin the dispatch-only trigger, the
absence of any rebuild or release path, the two-device `fail-fast: false` matrix,
the original helpers, the pre-download runner toolchain check and the evidence
patterns. An executable fixture runs the IDE leg shell with controlled drivers
to prove a passing test reaches the strict verifier, a verifier failure fails
the leg, and a failed test execution is never reported as acceptance. A second
executable fixture runs the real pre-download toolchain shell with controlled
`xcodebuild`/`xcrun` output to prove a mismatched version/build or a non-27 SDK
major is rejected by the executed check, not by a string comparison.

## Non-goals

This entry only recovers the IDE UI tests. It does not rebuild the App, does not
run the Notes or App-regression phases, does not touch `ci.yml` or any test
assertion, and does not publish to TestFlight, GitHub or Feather. A
`GITHUB_TOKEN`-created release still would not guarantee a Feather update; that
is out of scope here.

## Build 185 Notes-only diagnostic / 手记定向诊断

The optional `notes_diagnostic` mode reuses the release workflow’s saved SDK 27
test host and runs only the original Notes content-cover UI test on iPad. It
collects the Notes thumbnail log category, narrow Quick Look errors, the
xcresult, screenshots and recording. It does not retry failed assertions, build
the App, sign or distribute a package. The normal IDE mode remains separate.

GitHub currently registers `platform-test-diagnostics.yml` on the default branch;
`ide-host-recovery.yml` is not registered there yet. After the reviewed branch
changes are pushed, the registered controller calls the reusable diagnostic:

```sh
gh workflow run platform-test-diagnostics.yml --ref codex/build178-feedback -f notes_diagnostic=true
```

This opt-in controller pins build 185 source
`42ecc4527fdbeb171dd0aed1d0776375770f1572`, run `35292395886`, attempt 1,
artifact `10526564633`, and Xcode 27.0 build `27A266a`. The source workflow,
retention/upload step names, artifact identity, archive digest and toolchain
are checked before execution. No IDE-host digest from an older build is reused.
The artifact expires on 2026-09-25; expired or unavailable inputs fail explicitly.

手记诊断复用已经保存的完整 App 测试包，只跑失败路径并保留原始日志、截图和录屏。
旧测试包只能解释旧版本的问题，不能证明新的源码修复有效。修改源码后必须编译新版本，
不能把诊断成功当作发布通过。默认平台测试入口不受此可选模式影响。
