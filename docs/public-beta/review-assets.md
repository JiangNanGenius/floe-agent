# Review assets and demonstrations

These assets are prepared as references, not evidence that the next build has passed review.

## Available original captures

- [iPad brush controls](../evidence/floe-1.7/release-172/screenshots/ipad-notes-native-brushes.png).
- [iPad document tabs](../evidence/floe-1.7/release-172/screenshots/ipad-notes-document-tabs.png).
- [iPad tool arc](../evidence/floe-1.7/release-172/screenshots/ipad-notes-pencil-quick-menu-open.png).
- [iPhone brush controls](../evidence/floe-1.7/release-172/screenshots/iphone-notes-native-brushes.png).
- [Capture source, timestamps and hashes](../evidence/floe-1.7/release-172/screenshots/manifest.json).

These are unedited build 172 SDK 27 full-App simulator images using synthetic fixtures. They must not be labeled as the next submitted build or physical Pencil Pro evidence. Retake changed screens after the next build is frozen. UI test success is separate from physical-device acceptance.

## Complete walkthrough

The [12-page bilingual walkthrough](floe-public-beta-review-guide.pdf) covers navigation, Notes, Pencil, Office/PDF, Agent, limited local AI/BYOK, Canvas/maps/media, speech/environments/network, evidence and feedback. [Editable text](review-walkthrough.md), [artifact checks](review-guide-validation.json). It distinguishes delivered build 172 from the build 176 candidate and remains a review-preparation draft. Candidate checks and failures are explicitly labelled. The editable JSON is rendered with `FloeAgent/scripts/render_public_beta_review_guide.py`; review every rendered page after changes.

## Prepared sample

The [bilingual PDF and expected results](sample-files/README.md) are ready: two pages, searchable English/Chinese text, a chart image and annotation space. PDF rendering and text extraction have been checked; app-level execution on the next build remains pending.

## Attach before review

1. Run the prepared sample on the exact submitted build and retain the result.
2. A short screen recording: fresh launch → Notes import → full-screen annotation → save/reopen → model configuration with secret fields obscured → one AI response and visible tool action. Record the actual submitted build; avoid edited footage that hides failure states.
3. A brief PDF/Markdown reviewer walkthrough matching `review-notes.en-US.md`. Supply the real sample files, not just screenshots of them.
4. Verified on-device AI walkthrough and BYOK configuration instructions. Verify from a clean installation and disclose downloads, supported hardware and capability limits. No developer-funded cloud key is authorized; resolve any additional reviewer access request explicitly.

Invitation screenshots in TestFlight may be drawn from the app's latest approved store version. These development screenshots are supporting documentation and are not automatically its invitation artwork. See [Apple's test-information guidance](https://developer.apple.com/help/app-store-connect/test-a-beta-version/provide-test-information).

## Repair candidate recordings

[Original candidate screenshots and source hashes](../evidence/floe-1.7/build172-repair/notes-83cbc383/README.md) show the document assistant without an internal opening message. An approximately 79-second iPad screen-recording cut with selectable Chinese subtitles is retained privately. It demonstrates actual import, assistant opening, brush controls, tabs and search from source `83cbc383`; it contains no generated AI answers and is not the final candidate review video. No paid provider call was used.

The real Ark DeepSeek App recording on source `431e281d` created Markdown but failed before reading it back. It remains private failure evidence. A bounded stream diagnostic reproduced the empty-ID overwrite; [old/new replay evidence](../evidence/floe-1.7/build172-repair/ark-tool-identity-replay.json) supports the build 175 repair. A successful final-source App recording is still required.

A successful [Build 175 real Agent video and evidence](agent-demo-build175/README.md) now records actual Ark DeepSeek file creation and readback. This is explicitly earlier-source ordinary Agent evidence; the later Notes UI and final release qualification remain separate. The temporary credential was deleted after recording.
