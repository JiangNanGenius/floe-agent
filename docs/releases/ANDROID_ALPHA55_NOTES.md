# Android Alpha55 — selectable download sources

GitHub builds can choose GitHub, GHFast or GH-Proxy in App Update settings and during a download. The selection is remembered. Switching closes the previous connection and waits for its writer to finish before continuing through the new source. A staged prefix is reused only when the ranged response, total size and validator still match; otherwise the App explains that downloading restarted. Delta patches and the explicit full-package fallback use the selected source.

Mirrors only transfer public APK/patch bytes. Release discovery, manifests and checksums retain their original source, and package/version/signature/hash validation remains required. Mirror availability and speed vary. Play has no self-update or mirror route.

Update actions stay below the scrolling notes, the update entry precedes diagnostic-report history, and shorter receipts avoid the large blank sheet and duplicate Done action. Known issues remain expanded before installation. Confirmation copy explains that the App and Linux runtime can each require system confirmation or scanning.

中文：GitHub版在应用更新设置及下载中可选择GitHub、GHFast或GH-Proxy，并记住选择。换源先关闭旧连接、等待原写入结束，再开启新连接。只有真实分段响应、总长度及校验标识匹配才复用进度，否则提示从头下载；增量补丁及失败后的完整包沿用所选来源。

镜像只传输公开APK／补丁字节。更新发现、清单及摘要保留原来源，包名／版本／签名／摘要校验不变。镜像速度及可用性随网络变化；Play不包含自更新或镜像入口。

下载／安装按钮固定在滚动说明下方，设置中的更新入口移至反馈历史之前，短结果弹窗收紧并去掉重复完成按钮。安装前已知问题默认展开；文案说明主程序与Linux运行组件可能分别需要系统确认及扫描。

## Qualification / 验证

45 focused updater regressions and actual Full/Play Kotlin compilation passed. The final presentation-only wrapping/busy-state adjustment is compiled in the actual release build. New APK, Samsung mirror switching, full transfer and installation results remain pending and are recorded separately in delivery evidence. Unchanged native and other feature evidence is reused.

45项更新器相关回归与实际Full／Play Kotlin编译通过；其后仅调整按钮换行及忙碌态，随实际发行构建编译。新APK、三星换源／完整下载及安装结果另记，不能把主机分段抽样或JVM通过当作实机验收。未改原生与其他模块复用匹配证据。

## Known issues / 已知问题

- N01–N08 is still being iterated. Complex page density, extended standby, reboot continuity and additional phone-automation cases remain under refinement or unverified.
- Third-party mirrors may become slow or unavailable. Users can return to GitHub or select another source; no automatic unlimited source cycling occurs.
- Office/CAD preview components may need to reinstall on demand after a base App update. User projects/documents are retained.

- N01–N08仍在持续迭代；复杂页面密度、长期待机、重启接续及其他手机操作场景仍需精修或验证。
- 第三方镜像可能变慢或不可用，可主动切回GitHub或其他来源；不会无限自动轮换源。
- 基础App更新后Office／CAD预览组件可能需要按需重新安装，用户项目及文档保留。
