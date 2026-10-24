# Termux terminal-emulator vendoring provenance (feature/terminal)

- Upstream repository: https://github.com/termux/termux-app
- Pinned revision: tag `v0.118.3`, commit `5b657c6adf4304e5198951ce815fe0205dcac29c`
- Pinned path: `terminal-emulator/src/main/java/com/termux/terminal/`
- Primary upstream lineage: the module is derived from
  https://github.com/jackpal/Android-Terminal-Emulator (Apache License 2.0,
  its `LICENSE` file archived as `licenses/UPSTREAM-jackpal-ATE-LICENSE.txt`).

## License determination (per-file checked, not assumed)

- `termux/termux-app` root `LICENSE.md` (archived byte-copy as
  `licenses/UPSTREAM-termux-app-LICENSE.md`) states the repository is
  GPLv3-only **with an explicit exception**: “Terminal Emulator for Android
  code is used which is released under Apache License 2.0. Check
  `terminal-view` and `terminal-emulator` libraries.” The vendored files all
  come from the excepted `terminal-emulator` library.
- The jackpal upstream `LICENSE` is Apache 2.0 (verified from the upstream
  repository root at fetch time).
- Apache-2.0 full text archived as `licenses/APACHE-2.0.txt` (fetched from
  https://www.apache.org/licenses/LICENSE-2.0.txt).
- No file in the vendored subset carries a conflicting per-file license
  header (verified by inspection: files begin at `package com.termux...`).
- The excluded files (`TerminalSession.java`, `JNI.java`,
  `src/main/jni/termux.c`, the remainder of `terminal-view` beyond the selected `TerminalRenderer.java`) are NOT shipped;
  see the patch note below for why `TerminalSessionClient.java` is shipped
  patched instead.

## Vendored files (byte-identical to upstream)

SHA-256 (verified identical between the fetched upstream bytes and the
copied files on 2026-10-24; re-checkable against
`https://raw.githubusercontent.com/termux/termux-app/5b657c6adf4304e5198951ce815fe0205dcac29c/terminal-emulator/src/main/java/com/termux/terminal/<file>`):

| File | SHA-256 |
| --- | --- |
| ByteQueue.java | a331e76e385e77db85c6434b3c4c787ae4aefaab81afc9b76ea42138e7903d9c |
| KeyHandler.java | 543043c05d38450a4a805422b02ac77085bfa727e0cdb088353b7996c0b1856f |
| Logger.java | 7ab53c7ee035e9658a60525c93613e6b8126db36abc46f8cdbc5fdf49032a04f |
| TerminalBuffer.java | cffbc9f96d861627e2e2680c116da8d69b3927f9c0ffa450f270d5f6fe175f1d |
| TerminalColorScheme.java | a303825f79925387b2a70087b640fdb097c723cfb8e341b7d82c958d73eb4563 |
| TerminalColors.java | 27cc579af682cab7e6a30bdd166630d596e6215d33ab6b50c58dd55d3fb6867a |
| TerminalEmulator.java | 6c0ab4df53f73dc38ff0db0f112b467595642746fe8e03f681c87eef5e1e8fe8 |
| TerminalOutput.java | f844b820e8a344e97bdbf421251daf9312dbf3f69a367b084bd920ed8a4898bc |
| TerminalRow.java | 280c12d7f6e750413f8a2748e2827d4f5dbe5932cabd079b3ef4e2e441f01830 |
| TextStyle.java | 234faa9646aca6b04329998106d9b29aac757abdc7e0400f2a3ed90c95a07297 |
| WcWidth.java | 68fc84a28813b13e4a1dfec8d9acbd9d7bd2a6cea62fe2f38319d1eca6cca776 |

## Vendored renderer file (terminal-view)

| File | SHA-256 (with 8-line provenance header) | Upstream SHA-256 |
| --- | --- | --- |
| src/main/java/com/termux/view/TerminalRenderer.java | 46775ee75fd67f0dcf48df94d6cdc387ed008b7c37a7309fbb3a784a2fe99b0c | 3511efd82b87db856404191d584fc2e9526e4da303edbd6a5efff111571f3b74 |

PATCH-2: an 8-line comment header (in the file itself) is the only
difference; the body hash after removing the header equals the upstream
file exactly (verified 2026-10-24 by `tail -n +9 | shasum -a 256`).
The renderer is reused VERBATIM as the narrow Android renderer over the
vendored emulator (attributed runs, cursor shapes, CJK widths, font-mismatch
scaling are upstream behavior); the Compose wrapper in
com.floe.android.feature.terminal adds only grid/scroll/IME/selection
plumbing. The rest of terminal-view (TerminalView, GestureAndScaleRecognizer,
textselection handles) is NOT vendored (competing View/IME lifecycle).

## Compile/behavior proof (D3 external-PTY)

`javac -source 17 -target 17 -classpath android-37.0/android.jar` compiled
the 12 shipped `com.termux.*` files cleanly on 2026-10-24, and a
non-shipped JVM smoke driver fed the emulator through an external byte pipe
(TerminalOutput abstract class) only: ANSI+bold parsed, CJK double-width
advanced the cursor by 8 columns, DSR `ESC[6n` answered back OUT through the
external pipe, resize applied — with NO Termux process class (TerminalSession,
JNI, termux.c) present. Transcript + driver:
`Local/Private/android-g04-20261024/r1/terminal-lsp/probes/external-pty-smoke/`.

## Patched file

| File | Upstream SHA-256 | Patch |
| --- | --- | --- |
| TerminalSessionClient.java | 853c3816ea1fc827895cea8191628482e1845e888a33d6c7da7e7ddac63af1b9 | PATCH-1: remove the seven `TerminalSession`-typed callback methods (onTextChanged, onTitleChanged, onSessionFinished, onCopyTextToClipboard, onPasteTextFromClipboard, onBell, onColorsChanged) because Floe does not vendor `TerminalSession` (the Termux process/exec owner with JNI + shell lifecycle, excluded per D3). `TerminalEmulator` and `Logger` reference ONLY the retained members (verified by grep at vendoring time: `getTerminalCursorStyle`, `onTerminalCursorStateChange`, `logError/logWarn/logInfo/logDebug/logVerbose/logStackTraceWithMessage`). All retained members are byte-equal. The patch note is in the file header. |

## Not vendored (deliberate exclusions)

- `TerminalSession.java`, `JNI.java`, `src/main/jni/termux.c` — Termux
  process/session/PTY ownership. Floe drives the reused emulator over the
  ORIGINAL external PTY path (Linux engine `shell.*` sessions via
  `ShellSessionCenter`, native-owned in Swift `G04TerminalDomain`), which is
  the exact external-PTY integration point the module was designed for
  (`TerminalEmulator(TerminalOutput, columns, rows, ..., client)` takes an
  abstract `TerminalOutput`, not a `TerminalSession`).
- The entire `terminal-view` module (android.view-based InputConnection and
  handle controllers) — replaced by a narrow Compose renderer in
  `com.floe.android.feature.terminal` because the Floe Android UI is Compose;
  adopting TerminalView would embed a competing view/IME lifecycle.

## Obligation notes (Apache-2.0)

- The license text is retained (`licenses/APACHE-2.0.txt`).
- This file constitutes the “notice” identifying changed files and the
  nature of the change (Section 4(b)) plus the unmodified-file manifest
  (Section 4(a)).
- Derivative work ownership: the Floe additions under
  `com.floe.android.feature.terminal` are MPL-2.0 like the rest of Floe;
  the `com.termux.terminal` package remains Apache-2.0.
