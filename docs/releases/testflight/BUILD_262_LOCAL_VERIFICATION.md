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
