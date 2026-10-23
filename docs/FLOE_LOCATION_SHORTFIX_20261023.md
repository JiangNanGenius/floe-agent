# Floe iOS location short fix — 2026-10-23

Baseline: `1515a0a2`; candidate 1.7.49 (290). Build 289 and its immutable tag
remain unchanged. This is a small location-focused repair, not a full-App audit.

## Current work

No implementation, qualification or distribution work remains for this round.
Completed outcomes have been removed from the active table. Publictest1 has one
submission waiting for Apple Beta Review; approval is an external state, not a
claim of completed external installability. No follow-up timer was created.

## Behavior

- First rendered foreground launch requests When In Use location permission
  only when authorization is not determined. No Always or temporary full-accuracy
  request. Denied/restricted permission does not block non-location tasks.
- Any honored enhanced-background, PiP or screen-feedback option enables the
  location support policy. There is no separate location switch. Active local
  work shares one service-owned background location session across windows.
- User-requested weather and nearby-place tasks can obtain a current location
  through the existing `apple.location.current` tool while their prepared
  background session is valid, then use the existing weather/search tools and
  return results in the same task. This does not grant new tool permissions or
  change Temporary Chat's existing tool ceiling.
- Background assistance uses coarse updates. No coordinate history, coordinate
  logging or unsolicited model location injection. Explicit position requests
  return actual accuracy and timestamps, including approximate authorization.
- Future schedules, user/approval waits and provider-owned remote media jobs
  do not retain location by themselves. Last-work completion, revoked permission
  and disabling all assistance release the background session. Foreground
  transitions are aggregated across windows.
- Current-location authorization must complete before requesting a fix. Every
  request fences cancellation, timeout and delegate completion by identity,
  with exactly one result and separate ownership from background assistance.

## Validation boundary

Use controllable location adapters for permission, cancellation, background
ownership and tool result checks, followed by full Swift 6 App/test compilation
and the existing canonical iPad Simulator. No user physical-device operation,
new Simulator, reset, clone or erase. Simulator evidence does not demonstrate
physical GPS behavior, battery use, real background duration or review approval.

The reference is OpenMinis `BackgroundKeepAliveManager` at
`b4c0661d5631ebab4d1a2e6f3fd4c805d4030a6c`; implement the lifecycle independently
using Apple APIs rather than copying its source. Scope remains location only;
no additional voice/import/personalization findings were established by the
previous bounded audit.

## Delivery

Local qualification first, then exact-source packaging and existing internal
Floe QA / external publictest1 distribution. Unsigned publication uses the
normal immutable-tag attestation workflow with awaited Feather and independent
read-back. Production App Store state remains unchanged. Remove completed
milestones, merge/push main, retire only the merged task branch and task-owned
regenerable outputs after preserving artifacts, symbols and original failures.

## Qualified code milestone

At `b2b26eba`, Xcode 27.1 (`27A9275`, Simulator SDK 27.1) full App/test-target
Swift 6 object compilation passed. The scoped 80 functions in five suites all
passed, with zero failures, skips or missing declared functions, on the existing
canonical iPad Simulator. The first run at `464b02c6` remains recorded as
78 passed / 1 failed: an unchanged port-forward test fixture counted cumulative
apply calls as active forwards. The fixture now models removal and idempotent
application while keeping call history; all original exact assertions remain.
Production port forwarding was unchanged. Continuous location also preserves
Core Location's nonterminal locationUnknown stream while terminal errors stop it.

Actual Simulator UI at `464b02c6` showed the first-launch Chinese location prompt,
While Using the App authorization, the idle Location state in Background execution,
no extra location switch, and a relaunch without another prompt. The original
Home input and attachment remained present. UI code is unchanged at `b2b26eba`;
its delta is the continuous-update error classification and focused test changes.
These are Simulator/adapted-input checks, not physical GPS/background-duration
or online-provider weather acceptance.

The task-started canonical Simulator is shut down; no device was created,
cloned, erased or reset. Device Hub was closed with the canonical Simulator
selected; no physical-phone display/audio action occurred. After evidence export
and an open-reference check, the finished Simulator cache was removed:
6,821,691,392 allocated bytes; observed free-space increase 6,804,406,272 bytes.
Installed Simulator apps/data and the original failure evidence remain intact.

## Archive and integration milestone

Immutable `v1.7.49` binds `fb0b7626`. Xcode 27.1 device archive and package
checks passed; original App, normalized recovery ZIP and 14 DWARFs are retained.
The signed TestFlight upload was accepted in run 39928706037, with no App rebuild;
Apple processing and group availability remain pending. See the
[delivery record](releases/testflight/BUILD_290_DELIVERY.md) for independent gates.
Source merged and pushed to main through `fb1616b6`; the merged task branch was
retired. Finished Release DerivedData, uncompressed archive/App duplicates and
transfer staging were cleaned after SHA-256/full ZIP CRC checks.

## Completed delivery

Build 290 is independently verified VALID, unexpired and IN_BETA_TESTING in
existing Floe QA. Publictest1 has exactly one pending_review submission and
WAITING_FOR_BETA_REVIEW. Stable unsigned v1.7.49, the actual downloaded arm64
iPhoneOS IPA and live Feather URL/hash/source/size all pass independent checks.
Both consumers completed before deleting the private transport draft; a GET
returned404 and the public tag remained unchanged. Main is pushed, the merged
task branch is retired, all finished task build/staging duplicates are cleaned,
and the final Simulator/phone-display process inventory is empty.
See [the completed delivery record](releases/testflight/BUILD_290_DELIVERY.md).
