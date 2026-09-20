# Floe 1.7.0 build 209 — device-test candidate

This candidate includes build 207's Office lifecycle, IDE document tabs, Git
initialization, native mind map and Shell recovery changes. It adds cross-task
history pagination and final-answer recovery, bounded local-model compression
and tool-result handling, and separate Linux/Python/Node/WASM package entries.

Linux-selected Shell, local Python and services now share the guest backend.
Python package operations use its persistent venv and configured index; Node
operations use guest npm/pnpm, preserve Linux lifecycle scripts/native addons,
and expose installed commands in the same environment. Stopped Linux environments
do not fall back to the iOS package store. Boot passes a fresh wall clock to PID1.
TinyEMU's FENCE.TSO correction is included in the App's vendored engine.

Real cloud run [35500083112](https://github.com/JiangNanGenius/floe-agent/actions/runs/35500083112)
passed HTTPS APT update/install, NumPy 2.2.4, Node v20.19.2 and Python HTTPS 200.
This was a component guest test, not iPad acceptance. The final image and its
corresponding-source bundle are being prepared separately; the downloadable
image catalog remains empty in this candidate and native execution is default.
The guest uses a pinned 4.15 kernel with Debian 13 userland; the modern 6.12 kernel
has not booted in this backend.

## Verification and delivery boundary

Focused code checks cover the original repairs, cross-task cursor/UTF-8 budgets,
local prompt budgets, guest framing and language-package routing. The language
package module slice compiled; the separate native XCTest attempt could not
resolve XCTest under Command Line Tools. A small executable ownership harness
then passed. These checks do not replace the accepted-SDK full App build.

No simulator or repeated UI qualification is included. The user performs device
acceptance, especially the reported crashes. Recovery copies are preserved, but
a genuinely failed Office engine process can still require restarting the App.

Build 208 was cancelled before upload after the package-ownership gap was found.
Build 209 uses a new immutable tag. Retained IPA, signing validation, Apple upload,
processing and Floe QA availability must be recorded separately after they occur.
This source note is not an upload or installability claim.
