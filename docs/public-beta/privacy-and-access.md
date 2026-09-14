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

Review access needs a dedicated, working configuration rather than a developer's primary key. Store secrets only in the appropriate private review fields or an owner-approved secure channel. Record non-secret setup steps, a contact for access failures, and a plan to revoke/rotate access after review. Do not create a billing commitment or publish a test credential merely to complete this worksheet.

Apple requires accurate metadata, working review access and appropriate privacy disclosures. Review the submitted behavior against [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/), especially runtime/package behavior and third-party AI data flows. No exception or approval is presumed.
