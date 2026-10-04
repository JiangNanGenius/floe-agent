# Floe Agent 1.7.6 (Build 247) — qualification failed

Immutable tag `v1.7.6` fixes source `b07f561bd143ab64b2997b29704e5617f7d9feb3`. The [normal release run](https://github.com/JiangNanGenius/floe-agent/actions/runs/37179707425) failed before signing and upload. Apple received no Build 247 upload from this run; no App GitHub Release or Feather delivery was published.

The independent NativeNotes qualification succeeded. Both SDKs built their App test hosts, and the accepted upload-SDK device build was preserved as `accepted-sdk-device-recovery-1.7.6-build247` (Actions artifact ID `11295670127`, 735,052,942 bytes in GitHub storage). Neither result bypasses the failed full-App Notes import gate.

- SDK 27 iPad: the engineering DXF and DWG cards initially reported real `engineeringPreview` covers. After a Word rename, an open/close cycle and App relaunch, the DXF card stayed at cover source `none` through the test's 90-second settle window. The original xcresult and cover-source attachments are in `sdk27-notes-ui-1.7.6-build247` (artifact ID `11295503260`).
- Accepted upload SDK iPhone: `simctl bootstatus` did not finish within the 180-second preparation bound, so no iPhone Notes test executed. The original boot log and summary are in `accepted-sdk-notes-ui-1.7.6-build247` (artifact ID `11296105536`). This is a simulator startup failure, not an App assertion.

The tag and both failures remain unchanged. Follow-up source changes require a new immutable build and a fresh independent qualification run.
