# Runtime acceptance checkpoint — 2026-09-17

The primary reviewer re-read the original App-regression log from run `35202845926`, source `955e346a`, and the representative runtime test bodies. The relevant execution, package, environment and Workspace product paths are unchanged through `e0c846f9` (`git diff` empty). This is iOS Simulator execution, **not physical-device acceptance**. The overall CI run failed unrelated IDE UI; its runtime test passes remain valid scoped evidence. [Observed test lines](observed-passes.json) retain source line numbers.

| Capability | Observed result | Limit / remaining acceptance |
| --- | --- | --- |
| Python | Real bundled CPython; package installation/import/removal and project independence; bundled wheel imports and HTTPS passed | Public native wheels are not unrestricted; bundled verified native dependencies only |
| Node, npm, pnpm | Real embedded Node; both managers installed and executed a JavaScript package | Native addons and arbitrary install scripts are rejected; this is not desktop Node compatibility for every package |
| Shell | Pipeline, loops, stdin, missing command, timeout/cancel/repeat, environment restoration and curl/Python/Node HTTPS tests passed | Embedded dash with supported commands, not a complete Linux kernel or all Linux executables |
| Node/Python preview services | Both started a real loopback HTTP server, served content, survived foreground runs, and stopped their own owner | Explicit service restart and environment-deletion shutdown lack direct acceptance coverage |
| Lua | Real WASI interpreter tests passed separately; signed catalog/bytes verified | Full-App `apt install floe/lua` to shell command acceptance remains open |
| Rust/Swift/C/C++/PHP and other hosted languages | Remote staging/policy harness passed | Actual SSH compilation/execution unverified; local compilation not shipped; GitHub Actions IDE target now being implemented |
| apt | Package transaction/dependency/integrity tests and separate signed WASM routing exist | No default Debian repository; normal Debian packages need a configured compatible source |

These results do not imply every package or language is supported. Native `.node` modules, arbitrary native wheels, and ordinary Linux binaries are not currently general local capabilities. Cloud compiler output must be labelled as remote build output, not an iOS executable.
