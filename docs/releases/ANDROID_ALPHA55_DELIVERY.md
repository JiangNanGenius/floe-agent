# Android Alpha55 交付记录

2026-11-08，[Android 0.1.0-alpha.55](https://github.com/JiangNanGenius/floe-agent/releases/tag/android/v0.1.0-alpha.55) 已公开，code81，固定App源码 `ce167b77448b39e7722dd216ded6841d4f518426`。Full APK为164148871字节，SHA-256：`c5a3376e5df1c687fd2934f376e82cb8d399c0aa1c96c4d04ab375e0b906d9db`。本批闭合更新换源，不代表整轮N01–N08完成。

- **可选下载源：** GitHub默认，可选择GHFast／GH-Proxy；设置及下载页共用入口并记住选择。只代理本仓APK／增量字节，更新发现、清单及摘要仍走原来源；包名、版本、签名、大小和摘要校验不变。Play无自更新／镜像入口。
- **真实切换：** 三星SM-G9810／Android13显式选择完整包，在GHFast下载到68MiB后切到GH-Proxy，随后显示75MiB，无从头下载提示，最终进入安装。旧请求关闭、写入等待、真实206／偏移／总长／ETag不匹配时重下、错误镜像摘要拒绝等由实际生产下载器的定向测试覆盖；未将设备UI进度冒充原始HTTP状态抓取。
- **验收前驱边界：** 旧公开54没有换源代码。为验证首次新增能力，三星先工程安装同一`ce167b774`源码、显式code80／name54构建参数的私有前驱，再由App下载并安装公开55；私有前驱不等于公开Alpha54，旧公开包和标签未改。公开55目标未通过ADB安装。
- **安装与数据：** 主App、运行组件分别系统确认，运行组件经系统扫描显示安全后继续安装。两包实际code81，字节与公开主APK及其内嵌运行组件完全一致，原UID保留。重启后GH-Proxy选择仍在；旧定时任务对话、工具回执可读，工作区文件在全屏编辑器重开并读到原标记，没有新增模型调用。临时常亮恢复，无障碍／无线调试关闭，未配置自动解锁，测试计划保留暂停。可选Office／CAD未在本批重新安装。
- **界面：** 更新入口位于反馈历史之前；下载源及操作固定于滚动说明之外，按钮可换行，已知问题安装前默认展开。短成功弹窗仅保留一个完成按钮，系统确认文案解释主App与运行组件可能分别弹窗。复杂页面密度、长双语说明及其余全局UI仍待后续统一精修。
- **代码及发行检查：** 45项相关回归、实际Full／Play编译通过，最终仅呈现调整随实际发行组装编译。58项原生封装及签名、版本、ARM64/JNI和16KiB检查通过；未改native17复用匹配对象／链接证据。七附件远端摘要、匿名完整下载、标签源码及实际生产更新解析器读回通过，iOS Latest独立。54→55增量17198438字节，主机真实重建精确目标；两条镜像的完整补丁字节另行匹配。三星本批是完整包验收，未声称实机增量安装。
- **测试限制：** 下载在取消前已完成，界面工具因找不到可用取消按钮而未执行动作；本轮没有实机暂停／恢复通过记录。真实换源覆盖了连接关闭及后续下载，暂停／恢复保留生产路径JVM证据，不为凑次数重复下载。没有新平板、Root或供应商矩阵回归。
- **清理：** 按Gradle实际任务身份清除1422份被替代结果缓存，实测回收内置3688337408字节；公开构建19处和私有前驱18处完成副本分别回收2713944064及2597126144字节。七处完成源码打包暂存回收外置119652352字节，六组同字节当前／回退包改为硬链接，路径保留，再回收579604480字节；硬链接不算独立备份。精确公开55、回退54、私有前驱、原失败、生产回执／符号、SDK／AVD、用户数据及明确下一用途缓存保留。系统整体空闲同时受其他进程和swap变化影响，未把自有清理量冒充整机净增量。

下一批沿原编号继续全局UI、原有手机／专业软件及后台余项；新增独立iOS重型编辑器仍按外部Android应用／项目Linux分工处理。iOS增量沿用上一批固定`941cae725…`记录，本次小批不重开全库审计。

English: Alpha55/code81 is published from immutable source `ce167b77448b39e7722dd216ded6841d4f518426`. GitHub builds remember GitHub/GHFast/GH-Proxy selection; only public APK/patch transport changes, retaining original metadata and all identity/integrity checks. Samsung switched an active full download at68MiB, continued at75MiB and installed exact public81 main/runtime bytes through system confirmations and the safe scan. First-introduction testing used a private same-source code80 metadata predecessor, not original public54 and not an ADB install of target81. Selection, UIDs, old task/tool receipts and an actually reopened file survived.45 focused regressions, Full/Play compilation and58 native-package checks passed; unchanged production evidence is reused. All seven public assets and production feed discovery were read back. The54-to55 delta reconstructs the target and both mirrors serve its exact patch; this is separate from full-OTA device acceptance. Pause was not exercised because downloading finished first. Temporary device settings were restored; completed duplicates/stages were cleaned. N01–N08 remains active.
