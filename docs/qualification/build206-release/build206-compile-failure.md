# Build 206 compile failure

[Run 35495951994](https://github.com/JiangNanGenius/floe-agent/actions/runs/35495951994) compiled immutable source `02f1c5f79569f84bd95a67b04d892c3d38676ea3` using Xcode 26.6 (17F113), iPhoneOS 26.5 SDK, arm64 Release. It exited 65 before IPA creation/signing/upload. The repaired Office host dependency passed bootstrap.

The retained `rebuild-diagnostics-run35495951994` artifact (ID 10601391139) includes the original xcodebuild log and xcresult. App compilation exposed new-view errors: IDE callback access control, PDF throwing validation, an alert/confirmation-dialog API mismatch, and mind-map path/state/callback/pan argument mismatches. The follow-up corrects these call sites without removing functionality. The next build must use a new immutable source/tag/build number.

Local validation of the follow-up is restricted to syntax and diff checks; successful accepted-SDK App compilation and physical interaction remain separate gates.
