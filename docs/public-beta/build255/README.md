# Build 255 external TestFlight review

Build `255` belongs to immutable tag `v1.7.14`, App source `850701db34411ab87ac9788eeaaf7ea3baeea2b4`, bundle `org.floeagent.ios`, Apple build ID `6c5cb03d-6a23-47c9-bf02-d7978d0498b8`. The [delivery record](../../releases/testflight/TESTFLIGHT_1.7.14_BETA.md) separates release CI, package, upload and Apple availability.

The submission reuses the existing `publictest1` group and public link. [What to Test](whats-new.json) and [Beta App Description](beta-description.json) are bilingual. [Review notes](review-notes.en-US.md) describe an account-free core walkthrough and optional AI/Linux guest features. Physical iPad guest and voice behavior still requires user acceptance.

App Store Connect submitted Build 255 to Beta App Review on 2026-10-04. Independent GET-only [readback](https://github.com/JiangNanGenius/floe-agent/actions/runs/37228308146) confirms `VALID`, group attachment, final review notes matching the prepared file, one `pending_review` submission and `WAITING_FOR_BETA_REVIEW`. The public link <https://testflight.apple.com/join/nz6qeT2J> remains enabled; Build 255 becomes externally installable only after Apple approval. The API [submission attempt](https://github.com/JiangNanGenius/floe-agent/actions/runs/37227816516) received HTTP 403 on the review-note update, so the actual submission used the App Store Connect UI.
