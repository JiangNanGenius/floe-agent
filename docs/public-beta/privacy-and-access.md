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

## Recommended reviewer AI access

For the current bring-your-own-key app, prepare a separate review credential with provider-supported spending/rate limits and access to the models needed by the walkthrough. This is a proposal; no credential or billing limit has been created. Include provider name, base URL, model ID, supported vision/tool capabilities and exact configuration steps in the private review instructions. Check that the service is reachable from the reviewer's location and does not require a personal phone/OTP or payment step. Keep it usable throughout review, then revoke or rotate it after the review and any follow-up are complete.

The reviewer uses the ordinary provider settings and the same app behavior as other users. Do not add an undisclosed review-only feature switch. Put the credential in the private App Review information, never Beta App Description, What to Test, invitation email, public documentation or an embedded app default.

Public beta testers continue to supply their own credentials. A shared free trial would be a separate product decision requiring server-held upstream credentials, per-user quotas and usage controls; never distribute the reviewer key as a public trial key.
