# Full App IDE/CAD — SDK 27, 2026-09-17

Source `2e2a34c9f9d6a06d10b804df81ee1d92ec3f1381`, [CI run 35223435570](https://github.com/JiangNanGenius/floe-agent/actions/runs/35223435570), Xcode 27.0 / 27A5252f. The targeted IDE run succeeded. Each device passed all three original cases: DWG edit/save/cold reopen; DXF inline/full-screen preview; IDE native file save/readback/cold reopen. Both were first-attempt successes (iPad runner 525.186 s; iPhone 443.372 s); no retry was used.

These are original cloud Simulator screenshots, copied byte-for-byte. The primary reviewer inspected all six, including saved DWG text and reopened IDE file contents. `IDE-INSERT` and randomized save markers are qualification fixtures, not production controls or promotional UI. The screenshots establish the tested save flow, not native Pencil, Office, SSH or physical-device acceptance. Other suites were intentionally skipped by `ide_only`; the release workflow still qualifies both SDKs.

| Device | Saved DWG | Reopened drawing review | Reopened IDE |
| --- | --- | --- | --- |
| iPad mini (A17 Pro) | [Image](ipad-dwg-saved.png) | [Image](ipad-dwg-reopened.png) | [Image](ipad-ide-reopened.png) |
| iPhone 17 Pro | [Image](iphone-dwg-saved.png) | [Image](iphone-dwg-reopened.png) | [Image](iphone-ide-reopened.png) |

[Manifest](manifest.json) records original attachment names, hashes and source. Both strict verifier summaries are retained here; full logs, diagnostic samples and xcresults are retained in private evidence. Artifact `10500206254` is 15,059,457 bytes, SHA-256 `edb06ecb32dfb267ec413e46316e4525c7d98e837122f30cb3e94651b2862ee7`.
