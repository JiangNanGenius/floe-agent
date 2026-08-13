# WorkBuddy implementation report template

Create `docs/workbuddy/IMPLEMENTATION_REPORT.md` before finishing. Replace every placeholder with evidence.

## Summary

- Branch and final commit:
- Implementation start/end:
- Daily-use journeys completed:
- Largest known gaps:

## Commits

List each commit SHA, subject and phase.

## Implemented behavior

For each phase, list user-visible behavior and key files. Distinguish production behavior, fixture/demo behavior and unavailable behavior.

## Database and compatibility

- Schema version and migrations:
- Backward compatibility evidence:
- Secret storage/redaction evidence:

## Validation evidence

Include exact commands, exit results and test counts for:

- Swift package tests
- App unit/UI tests
- iPhone simulator build/smoke
- 13-inch iPad simulator build/smoke
- Release build
- Secret scan
- Pin/license checks
- GitHub CI URL/result

## Manual acceptance matrix

| Journey | Device/simulator | Result | Evidence or limitation |
| --- | --- | --- | --- |
| Onboarding/provider setup | | | |
| Streaming chat/cancel/retry | | | |
| Approval and catastrophic gate | | | |
| SSH terminal/reconnect | | | |
| VNC connect/input/stop | | | |
| Files round trip | | | |
| Local image edit/export | | | |
| Relaunch recovery | | | |
| VoiceOver/Dynamic Type/dark mode | | | |

## Known issues and follow-ups

List severity, reproduction, impact and proposed next action. Do not hide incomplete work behind broad statements.

## Codex review entry point

Name the highest-risk files and the first three flows Codex should independently inspect. Confirm that Xcode Cloud/TestFlight was not triggered.
