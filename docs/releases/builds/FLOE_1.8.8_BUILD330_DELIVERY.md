# Floe 1.8.8 (330) — 交付 / Delivery · 2026-11-11 Sydney

冻结源码 / Frozen source：`b5bf026b16e734a6a1923c2416a687ee274fce41`。不可变标签 / Immutable tag：`v1.8.8`；标签对象 / Tag object：`6d661c7af6f946b8dc82bb1e6eee8704b4281289`。后续主线修改不属于此包。 / Later mainline changes are outside this artifact.

## 范围与验证 / Scope and qualification

这是不含新增 Linux 视频硬件解码的中间整合内测版本；功能范围按[冻结双语说明](../notes/RELEASE_NOTES_1.8.8_BUILD_330.md)记录。现有视频编辑与播放保留，不能据此声明完整 GPU／硬解链或所有物理设备效果已通过。 / This intermediate integration beta excludes new Linux hardware video decoding. Its frozen bilingual notes define the feature scope; existing video editing and playback remain. Full GPU/hardware-decoding and physical-device acceptance are not claimed.

本轮实际 App与测试包已编译、链接。App17首轮19项为12通过、7失败；App18只复验受影响9项，8通过、1失败；剩余MIDI保存/重开问题修复后，App19单项通过、无跳过。未变范围复用已通过结果，原失败保留；后续hotfix不能继承为已验收。 / Actual App and test bundles compiled and linked. App17 recorded 12 passes and 7 failures; the affected App18 subset recorded 8 passes and 1 failure. The remaining MIDI save/reopen case passed in App19 with no skips. Unchanged results were reused, original failures retained; these results do not qualify later hotfixes.

## 渠道实际读回 / Observed distribution

| 渠道 / Channel | 核实结果 / Verified result | 证据 / Evidence |
| --- | --- | --- |
| 内部 TestFlight / Internal TestFlight | Apple `VALID`、未过期；既有Floe QA组 `IN_BETA_TESTING`，内部可安装。 / Available to the existing internal group. | [签名、校验及上传 / Signing and upload](https://github.com/JiangNanGenius/floe-agent/actions/runs/42968698492)成功；[独立 Apple GET / Independent GET](https://github.com/JiangNanGenius/floe-agent/actions/runs/42971538592)再次确认。 |
| GitHub | 正常未签名包 producer与严格公开读回通过，stable/latest交付。 / Normal unsigned publication and strict readback passed, stable/latest. | [同源发布流程 / Publication workflow](https://github.com/JiangNanGenius/floe-agent/actions/runs/42971881361)；[不可变 Release](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.8.8)。 |
| Feather | 同次 awaited下游成功；实时feed的版本、源码、地址、大小及摘要与实际包一致。 / Awaited downstream workflow passed; the live feed matched version, source, URL, size and digest. | [Feather源 / Feed](https://raw.githubusercontent.com/JiangNanGenius/floe-agent/main/feather.json)，与同次发布独立读回一致。 |
| 公开 TestFlight / Public TestFlight | 330未提交，未声称公开可安装。 / Build330 was not submitted; public installability is not claimed. | 内部组和GitHub公开下载不代表公开TestFlight已开放。 / Internal availability and public unsigned downloads are separate. |

Apple独立读回保存于2026-11-11 06:19 UTC，GitHub／Feather核实保存于06:28 UTC；均为悉尼同日的历史快照。实际签名IPA另行回读了相同App UUID、Wi-Fi权限、production推送与未过期profile，未以流程启动代替完成证明。 / Apple and public-channel readbacks were saved at 06:19 and 06:28 UTC, respectively, on the same Sydney date. The signed IPA was separately checked for the matching App UUID, Wi-Fi entitlement, production push capability and unexpired profile.

公开未签名包 / Public unsigned package：[Floe-Agent-1.8.8-build330-unsigned.ipa](https://github.com/JiangNanGenius/floe-agent/releases/download/v1.8.8/Floe-Agent-1.8.8-build330-unsigned.ipa)，**914,328,340 bytes**。SHA-256：

```text
f9122d415fc37ee480fa11300a6e88ddaf04f98e6a03ec885407c07e904a32e3
```

该包需用户自己的签名方式；签名TestFlight包与公开未签名包各自保留，不混用摘要或来源。 / The public package requires the user's signing. Signed TestFlight and public unsigned artifacts retain separate digests and provenance.

## 新反馈与后续范围 / Follow-up scope

330用户实测仍报告传感器、计时器、化学文件删除Unauthorized及生物回收站残留。这些问题正在后续源码和定向App路径中修复，不能写成330已解决。先完成相关hotfix并尽快交付中间内测，不等待GPU／新增Linux视频硬件解码。 / Build330 user feedback still reports sensor, timer, Chemistry file-deletion and Biology Trash-cleanup issues. Follow-up source and affected App checks address them; this record does not claim Build330 fixed them. The next intermediate internal beta proceeds without waiting for GPU or new Linux hardware video decoding.

下一版暂选 **1.8.9（331）**，尚未冻结、上传或交付；后续支持硬解的完整版本再推进公开TestFlight。正式App Store Build315及既有安排保持不变。版本决定见[唯一版本依据](../../RELEASE_VERSION_AUTHORITY.zh-CN.md)。 / Proposed **1.8.9 (331)** is not frozen, uploaded or delivered. Public TestFlight waits for the later complete hardware-decoding build. Build315's formal App Store arrangements remain unchanged.
