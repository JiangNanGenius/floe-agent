# Review assets and demonstrations

These assets are prepared as references, not evidence that the next build has passed review.

## Available original captures

- [iPad brush controls](../evidence/floe-1.7/release-172/screenshots/ipad-notes-native-brushes.png).
- [iPad document tabs](../evidence/floe-1.7/release-172/screenshots/ipad-notes-document-tabs.png).
- [iPad tool arc](../evidence/floe-1.7/release-172/screenshots/ipad-notes-pencil-quick-menu-open.png).
- [iPhone brush controls](../evidence/floe-1.7/release-172/screenshots/iphone-notes-native-brushes.png).
- [Capture source, timestamps and hashes](../evidence/floe-1.7/release-172/screenshots/manifest.json).

These are unedited build 172 SDK 27 full-App simulator images using synthetic fixtures. They must not be labeled as the next submitted build or physical Pencil Pro evidence. Retake changed screens after the next build is frozen. UI test success is separate from physical-device acceptance.

## Prepared sample

The [bilingual PDF and expected results](sample-files/README.md) are ready: two pages, searchable English/Chinese text, a chart image and annotation space. PDF rendering and text extraction have been checked; app-level execution on the next build remains pending.

## Attach before review

1. Run the prepared sample on the exact submitted build and retain the result.
2. A short screen recording: fresh launch → Notes import → full-screen annotation → save/reopen → model configuration with secret fields obscured → one AI response and visible tool action. Record the actual submitted build; avoid edited footage that hides failure states.
3. A brief PDF/Markdown reviewer walkthrough matching `review-notes.en-US.md`. Supply the real sample files, not just screenshots of them.
4. Working private AI review-access instructions. Verify access from a clean installation and disclose any optional downloads, network requirements or necessary hardware.

Invitation screenshots in TestFlight may be drawn from the app's latest approved store version. These development screenshots are supporting documentation and are not automatically its invitation artwork. See [Apple's test-information guidance](https://developer.apple.com/help/app-store-connect/test-a-beta-version/provide-test-information).
