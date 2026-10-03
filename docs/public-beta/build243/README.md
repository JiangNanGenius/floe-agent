# Build 243 external TestFlight review

Build `243` belongs to immutable tag `v1.7.2`, source `c5a1ffbce09f617a90d1970378a010022962e457`, bundle `org.floeagent.ios`, Apple build ID `d294a8ae-9dd4-494f-b050-292e8ccea01c`. The [internal delivery record](../../releases/testflight/TESTFLIGHT_1.7.2_BETA.md) contains independent CI, package, upload and Apple readback evidence.

The prepared external submission reuses the existing `publictest1` external group and public link. [What to Test](whats-new.json) and [Beta App Description](beta-description.json) are bilingual. [Review notes](review-notes.en-US.md) describe an account-free core walkthrough; optional cloud AI requires a tester-owned provider key. Physical iPad behavior remains unverified by the release automation.

App Store Connect submitted Build 243 to Beta App Review on 2026-10-03 using the existing `publictest1` group. Independent [readback](https://github.com/JiangNanGenius/floe-agent/actions/runs/37134960962) confirms one `pending_review` submission, `WAITING_FOR_BETA_REVIEW`, and the group association. The public link <https://testflight.apple.com/join/nz6qeT2J> remains enabled; Build 243 is not yet externally installable until Apple approves it. The API [submit attempt](https://github.com/JiangNanGenius/floe-agent/actions/runs/37134669547) received HTTP 403 when writing review notes, so the actual submission used the App Store Connect UI. Full status and evidence are in the [delivery record](../../releases/testflight/TESTFLIGHT_1.7.2_BETA.md).

Final GET-only [verification](https://github.com/JiangNanGenius/floe-agent/actions/runs/37135266738) confirms the stored review notes match the prepared file byte-for-byte and no metadata update remains pending.
