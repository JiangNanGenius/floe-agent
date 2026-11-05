# Floe 1.7.79 (320) — delivery, 2026-11-06

Frozen source: `89c8ad5a2971ca8d5630a0d94dcc7191fd38a313`, immutable tag
`v1.7.79`. Xcode 27.1 (`27A9275`), iPhoneOS SDK 27.1. Delivery evidence is
appended after the source freeze; the tag and saved App bytes are unchanged.

## Delivered behavior

- Browser controls adapt to actual panel width: a narrow address row has room
  above navigation/tab controls; wide views retain the tab strip. Actions use
  native menus and controls, preserving task-owned tabs and WebViews.
- Local and remote terminal display, clipboard and key actions are grouped.
  Port management uses the status row. Session and PTY owners are retained.
- Task files remain in the existing inspector menu; the redundant standalone
  folder button is removed.

Actual Swift 6 App and UI-runner object builds passed. Eleven focused tests
passed on the reused iPad Simulator, with no failed or skipped cases. Earlier
stale-runner and native-menu locator failures remain in the evidence. Three
pre-existing runtime warnings are retained, not reported as fixed.

The actual M4 iPad was updated through TestFlight and independently read back
as 1.7.79 (320). Cold terminal startup continued across immediate full-screen
presentation; five delayed output lines arrived without additional keystrokes.
The browser loaded a real public page in narrow and full-screen layouts.
Captures are retained locally. This does not constitute a new guest
port-forward acceptance or a physical-iPad performance comparison.

## Distribution

The exact saved local App was signed and uploaded without another App build.
Apple reports `VALID`, unexpired, and available to the existing Floe QA group
as `IN_BETA_TESTING`. English and Simplified Chinese test notes were read back.

The existing `publictest1` flow was attempted once for 320 after saving its
prepared review notes. Apple refused submission because the daily two-build
Beta Review limit had been reached. **320 is not reported as submitted,
waiting for external review, or publicly installable.** The artifact is retained
for later submission without rebuilding. Build 315's formal App Store review
and automatic-release choice remain unchanged. No App GitHub/Feather publication
is included in this TestFlight-only round.

## Runtime and limits

All 91 pinned runtime source/header files match the qualified 319 runtime;
320 claims no additional VM speed gain. The separate actual M4 results are in
[the CPU-state isolation record](../../ARM64_CPU_STATE_ISOLATION_20261106.md).

A supplementary Simulator CAD create/reopen check remained at its native Create
alert and failed; it is not marked passed. Manual creation and reopening through
the unchanged path succeeded on the physical 319 App. This is distinct from
the eleven passing 320 checks.

Physical terminal use also exposed an existing Ctrl-C routing defect: the
common session center could signal the whole session rather than forward PTY
input. The subsequent correction is **outside the frozen 320 source**. It has
an actual Swift 6 object build and four passing session/input/ownership checks;
physical verification needs a later App artifact. Initial malformed remote
keyboard injection is retained separately from the successful script run.

Consumed 319/320 duplicate archives, expanded App/symbol copies and transport
staging were removed only after byte-level recovery verification. The two
cleanups measured approximately 4.26 GB of additional free space in total;
APFS shared extents and concurrent writes affect this measurement. Both exact
recovery packages, all fourteen symbol bundles per build, original failures
and visual evidence remain. Consumed private transport drafts were independently
read back as deleted; immutable source tags remain.
