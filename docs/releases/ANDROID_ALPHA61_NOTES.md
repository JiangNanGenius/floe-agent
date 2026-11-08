# Android 0.1.0-alpha.61 / code87

This intermediate preview continues N01–N08; whole-App acceptance remains in progress.

- Downloads can use the same release asset through GitHub's validated official API when its browser download route has a gateway or connection failure. Cancellation and definitive refusals do not trigger retry loops. APKs, patches, metadata and optional Office/CAD components share the bounded route; size, hash, version, signer and system-installer checks remain mandatory.
- Office/CAD payloads also respect the selected GitHub/GHFast/GH-Proxy source. Release metadata and checksums stay on GitHub; choosing a mirror never silently switches the payload back to GitHub.
- The Android VNC socket transport now separates serial reads from serial full writes, so a blocked receive cannot starve a write or race the retained input buffer.

37 focused updater tests,4 real BSD socket host tests,Full/Play Kotlin compilation and Android ARM64 object/link production passed. Exact APK, Samsung behavior and publication receipts are recorded separately.

Known limits: the earlier Samsung graphical-session disconnect has no proven causal fix yet; model graphical interaction, background phone-control completion, automatic unlock/relock, intermittent transcript export and remaining visual work continue. Existing successes cover specific cases, not every editor or device. This version does not retroactively change older installed clients; their existing manual mirror/full-package options remain available.

---

本版是N01–N08的中间预览，整轮验收继续。

- GitHub浏览下载地址遇到网关或连接故障时，改用经验证的官方API获取同一发布资产。取消和明确拒绝不触发循环重试。安装包、补丁、元数据及Office/CAD组件共用有界通路，继续校验大小、摘要、版本、签名并交给系统安装。
- Office/CAD下载沿用用户选择的GitHub／GHFast／GH-Proxy；版本与校验信息保留官方源，所选镜像不会静默换回GitHub。
- VNC底层读写分别串行执行，阻塞读取不再阻挡写入，也不并发改写保留的接收字节。

37项更新检查、4项真实BSD socket宿主检查、Full／Play Kotlin与Android ARM64对象／链接生产通过；精确APK、三星行为和公开发行回执另记。

已知限制：此前三星图形会话断连尚无经证明的根因修复；模型图形交互、后台手机控制收尾、自动解锁／重新锁屏、间歇性任务导出和全局视觉精修继续。已有通过结果只覆盖具体用例，不代表全部编辑器和设备。本版不能追溯修改已安装的旧客户端，旧版仍可使用原有镜像／完整包入口。
