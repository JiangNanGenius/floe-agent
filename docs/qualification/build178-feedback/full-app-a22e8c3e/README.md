# Build 179 candidate: native iPad IDE evidence

Source `a22e8c3e24976a1342a80c3439aa15b9a696a5bc`, [CI 35212766190](https://github.com/JiangNanGenius/floe-agent/actions/runs/35212766190), SDK 27 full-App iPad mini (A17 Pro) simulator.

All three IDE UI cases passed: DWG edit/save/cold reopen, engineering drawing inline/fullscreen, and native workbench text save/disk readback/cold reopen. The overall run failed afterward because the runner lacked the specifically requested iPhone 17 Pro simulator; no iPhone result was produced. This does not establish physical Pencil acceptance, native Office editing or TestFlight delivery.

Original, unedited captures use synthetic fixtures. The IDE-INSERT control is a UI-test fixture control, not a normal production command. Images retain orientation metadata.

- [DWG saved](ipad-dwg-saved.png)
- [DWG reopened](ipad-dwg-reopened.png)
- [IDE reopened](ipad-ide-reopened.png)
- [Test summary](ipad-summary.json), [source and capture hashes](manifest.json)

主代理检查了原始 DWG 保存及 IDE 重开截图。保留整轮失败，不能将 iPad 通过写成双端通过。
