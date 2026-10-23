# Floe iOS location short fix — 2026-10-23

Baseline: `1515a0a2`; candidate 1.7.49 (290). Build 289 and its immutable tag
remain unchanged. This is a small location-focused repair, not a full-App audit.

## Current work

| Outcome | State |
| --- | --- |
| Shared authorization, safe current-location requests and background lifecycle | Code ready; Swift 6 and behavior verification pending |
| Settings, metadata and bilingual copy | Integrated; generated metadata and localization checks passed |
| Focused tests, Swift 6 build and Simulator UI | Pending source freeze |
| Internal/external beta, unsigned package and Feather | Pending qualification |

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
