# Public beta privacy and review-access worksheet

This is a preparation worksheet, not a published privacy policy or a completed App Privacy declaration. Final statements must match the next submitted binary and live services.

| Flow | Known implementation / remaining confirmation |
| --- | --- |
| Local Notes, document indexes and Canvas data | App-managed local storage; confirm next-build backup, sync, deletion and retention behavior |
| Cloud model prompts and attachments | Sent to the configured provider when the requested feature uses it; list actual recipients and verify user disclosure/permission before sending |
| Provider/SSH credentials | Approved credential storage; confirm optional synchronization settings and exclusions from logs/exports |
| Whisper | Optional model download; local inference path. Apple fallback may use Apple's services, so do not claim speech is universally offline |
| Browser, HTTP, downloads and package registries | Requests reach the destinations selected by the task/service; disclose provider, registry and resource endpoints actually used |
| User feedback | `FeedbackUploadService` sends the submitted problem and optional diagnostics/images after Submit; verify all other crash/diagnostic upload paths separately |
| Remote hosts and Apple capabilities | Optional user-configured connections/permissions; explain whether requested content leaves the device and how access is revoked |

Confirm the operating entity, public feedback address, privacy-policy URL, service locations/recipients, retention periods, deletion requests and any new analytics or paid features with the owner. The homepage returned HTTP 200 on 2026-09-15 Sydney; this does not verify a separate privacy or support page. Those URLs remain unset in the metadata draft.

## Review access: no developer-funded cloud credits

The owner does not authorize supplying any funded AI key or cloud credits, including text and image generation. The app remains a BYOK client for cloud providers. Do not create another DeepSeek key and present it as a spending cap: its published billing documentation describes account-balance deductions, and no per-key hard cap has been verified. See [DeepSeek billing](https://api-docs.deepseek.com/quick_start/pricing).

Prepare a genuine on-device inference walkthrough using the existing local-model feature, after testing the actual submitted build on supported hardware. Record model identity, download size, memory needs, first response and supported text/tool/vision capabilities. A local text response does not establish vision, cloud connection or complete Agent functionality. This path is proposed and not yet qualified for the next build.

The reviewer can directly exercise Notes, PDFs, documents and Canvas. Supply accurate cloud-provider setup instructions and a recording of actual cloud use as supplemental evidence. Do not assume a reviewer will buy credits or supply personal credentials. Apple may request further access to included functionality; then explain the BYOK architecture and seek an accepted arrangement. A video or an unavailable connection is not guaranteed to satisfy review. Do not hide features or fabricate AI responses. A demo mode, if proposed, must be disclosed and meet Apple's requirements rather than being assumed sufficient.

Public testers supply their own cloud credentials. No shared free trial or developer-funded account is promised. Any future paid review access or public trial requires a separate owner decision. Keep all credentials out of public descriptions, What to Test, repository files and app defaults.

Chatbox publicly offers both BYOK and its own hosted subscription. Its private App Review credentials or correspondence have not been established from public sources; its App Store presence is not evidence that Apple always accepts a zero-access submission. Sources: [Chatbox](https://chatboxai.app/en), [Apple review guidance](https://developer.apple.com/app-store/review/guidelines/#before-you-submit).
