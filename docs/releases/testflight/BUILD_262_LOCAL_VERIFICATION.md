# Build 262 local verification

- Version: 1.7.21 (262).
- Immutable source: `2bb37ca67a5d8ece5b3fd68e61069444eafdea58`, tag `v1.7.21`.
- Toolchain: Xcode 27.0 (`27A266a`), iPhoneOS 27.0.
- Full Release device build: passed with six compiler jobs and signing disabled. The final incremental build ran after source was frozen.
- Device recovery package saved before distribution; normalized App and dSYM UUID match: `0213D0CD-A1CB-360F-A09C-90FDE2B91C08`.
- Transport SHA-256: `cd0a5cb3e3df0506b915e4816f1dec21f606d55e44dc8751e72364bdf3bc9a5d`.
- Service and shell qualification: 27 tests passed, including Shell argument preservation, managed stop, workspace path mapping and escape rejection.
- Full-App iPad Simulator: IDE activity rail, terminal expansion/return and editor save passed; first run sheet, web-service entry and scoped back navigation passed. The initial back-navigation test selected an obscured underlying IDE button; its failure was retained, then its locator was scoped to the presented navigation bar.
- Distribution helper: five Python tests passed. Release preflight and workflow lint passed.

## Limits

This is the user-authorized faster local release route, not a full cloud CI, compatibility SDK or Linux matrix result. Simulator UI checks used a synthetic workspace without a downloaded guest image; they prove presentation and navigation, not an on-device server's network behavior. Real terminal wrapping, sustained output, web-service reachability and background behavior remain physical-device beta checks. Apple processing, internal availability and public review must be recorded separately after distribution.

## Suggested device checks / 建议真机复测

1. Open a `.sh`, `.py` or `.js` file and tap Run; confirm the window contains controls and startup failures are visible.
2. Choose Run as web service, set the script's `PORT`, start, read logs and open its preview. Close the window and verify the service remains reachable while Floe is running; use Stop to end it.
3. In the local terminal, run `pwd`, print multiple lines and use arrow-key history. Expand and return, then verify output order and line wrapping without tapping to refresh.
4. 系统挂起或终止 App 后不保证服务继续运行；重新进入时检查实际状态，不把旧预览页面当成存活证据。

## Signed delivery and independent Apple verification

- Signing/upload: [37528438507](https://github.com/JiangNanGenius/floe-agent/actions/runs/37528438507). Apple transport accepted the package; the subsequent processing poll timed out. The App was not rebuilt or uploaded again.
- Independent Apple readback: [37531932664](https://github.com/JiangNanGenius/floe-agent/actions/runs/37531932664), VALID and unexpired.
- Internal group verification: [37532263968](https://github.com/JiangNanGenius/floe-agent/actions/runs/37532263968), existing Floe QA membership and IN_BETA_TESTING confirmed at 2026-10-06 21:13 UTC.
- Final signed archive retained and CRC/hash checked: `16633b0968e4e2351a908b70a0f9b860adaf4e67b744c2ee79dba434e148c0ba`. Nested IPA SHA-256: `b8ca2023512883265ed1902af737c3be20564ed2290310a52b2844d015403b7d`. App and screen-share extension both report1.7.21/262, Xcode27A266a and iphoneos27.0.
- External publictest1 submission completed on 2026-10-07. Independent inspection 37559293000 confirmed VALID, unexpired, attachedToBuild=true and WAITING_FOR_BETA_REVIEW; no external approval is claimed. Physical terminal/service acceptance remains with the user.
- Task build caches and extraction staging removed after retaining artifacts and evidence; task Simulator shut down without deleting its data.
