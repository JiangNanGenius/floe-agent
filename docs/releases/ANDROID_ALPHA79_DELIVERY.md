# Android Alpha79 / code105

已公开，并完成三星真实78→79镜像增量联合安装及原数据核对。35项聚焦和Full生产／公开读回通过；后续实测已确认自动解锁与页面读取，连续启动计算器误弹使用中确认，整条操作及任务结束重锁未通过。下方保留各阶段证据。

Published and installed on Samsung through the actual78→79 mirror/delta route, with original data retained.35 focused cases, Full production and public read-back passed. A subsequent case actually unlocked and observed the screen, then incorrectly requested human control confirmation before launching Calculator. The complete action/relock flow has not passed. Evidence below retains each stage separately.

## 历史：源码准备 / Source-preparation snapshot

本版从已推送检查点`d4cb096c6b3cefac4d0b6b3f8d624ba255c0783e`接续，准备自行分发的Full ARM64安装包。接入解锁后界面就绪等待与取消／接管隔离；定时历史和提问通知打开准确运行记录，超出最近160条时读取真实快照及成果，校验任务归属并处理UUID大小写；语音、网页搜索和模型设置继续压缩占位，保留手机／平板导航。

This Full ARM64 candidate follows the pushed checkpoint above. It adds post-unlock observation readiness/cancellation fences, exact recorded-run navigation from schedule history and question notifications, authoritative reads beyond the160-row window with owner/UUID checks, and compact voice/search/model settings with existing phone/tablet navigation.

35项唯一聚焦检查（页面就绪11、准确运行15、入口策略6、默认回调3）与实际Full消费端编译已通过；原脚本夹具失败保留，未削弱生产协议或断言。不重跑未改矩阵。用户已停止Google Play线，本版不构建或验收Play。

35 unique focused cases and actual Full consumer compilation passed. Original malformed-fixture failures remain retained; production protocol and assertion checks remain intact. Unchanged matrices are reused. Google Play is discontinued and is excluded from this candidate's build/qualification.

## 历史：准备时待办 / Next steps at source preparation

准备时尚未生成本版APK或发布。后续保存同源Full安装包、原生生产记录／符号和摘要，验证78→79增量及完整包回退，读回公开附件与客户端更新发现，保持iOS Latest，再使用三星验证真实升级、解锁后读取与准确运行记录跳转。中间版不代表N01–N08整轮完成。

At source preparation no APK or publication existed. The subsequent steps retained exact-source packages/native records/symbols, qualify the78→79 delta and full fallback, verify public assets and update discovery while preserving iOS Latest, then use Samsung for actual update, post-unlock observation and exact-run navigation. The intermediate build does not close N01–N08.

78的独立三星用例已真实自动解锁，首次界面读取失败，计算器及任务结束重锁未通过；原45条记录及恢复证据保持。本版源码修复尚不能替代新的设备结果。专业图形保存、首次下载计量、整体UI精修及部分定时／恢复组合继续；索尼Android9已有环境就绪的正向外测反馈，照片未给App版本，不归因本版。

A fresh78 Samsung case actually unlocked, then failed its first UI observation; Calculator execution and task-owned relocking did not pass. Its45 original records/restoration evidence remain retained. This source fix needs a new device case. Professional graphical saves, fresh-download metering, whole-App refinement and some scheduling/recovery combinations remain open. Positive Sony Android9 readiness feedback did not identify an App version and is not attributed to this build.

## 公开发行与三星升级 / Publication and Samsung upgrade

[Alpha79/code105](https://github.com/JiangNanGenius/floe-agent/releases/tag/android/v0.1.0-alpha.79)已从不可变源码`3eb408bfb43a786b1df3bf79aeea9308e945fc6a`公开。Full APK为164,753,415字节，SHA-256：`efe2a9d05bee9fe1631b9ae69756699565f1c914ea80f5f0b726d5d80690b39f`。35项唯一聚焦检查、实际Full构建、58项原生／封装绑定、API28／29签名及78→79重建通过，复用未改运行层56项证据；未构建Play。七个附件的匿名下载字节、当前与保留Alpha65生产解析器发现均读回通过，iOS Latest保持当时的`v1.8.6`。

Alpha79/code105 is public from the immutable source above. Its164,753,415-byte Full APK has the recorded SHA-256.35 unique focused cases, actual Full production,58 native/package bindings, API28/29 signatures and78→79 reconstruction passed, reusing56 unchanged runtime cases without a Play build. All seven anonymous asset downloads and current/retained Alpha65 production-parser discovery passed; iOS Latest remained`v1.8.6` at read-back.

三星已使用保存的GH-Proxy镜像，在原78客户端内下载27,496,561字节增量并重建校验，经主应用／运行环境系统确认及正常安全扫描完成联合安装。主包与运行组件均为105，实际安装摘要及原UID一致，原5任务和2项目保持；没有ADB覆盖安装、降级、卸载或清除数据。新的模型解锁／页面读取用例准备中，尚未计为行为通过。

Samsung used its saved GH-Proxy mirror and the actual78 client to download/rebuild/verify the27,496,561-byte delta, then completed both system confirmations and the normal security scan. Both packages are105, match published bytes and retain their UIDs, five tasks and two projects. No ADB installation, downgrade, uninstall or data clearing was used. The new model unlock/observation case is being prepared; no behavioral pass is inferred.

本轮已导出8份生产回执，并退役26处用完的打包／原生重复输出及源码／增量暂存，删除窗口外置盘可用空间增加2,605,219,840字节。旧stage不能盲目重放；当前79、必要78回滚、原始故障、实际生产符号和下一原生批次使用的热缓存保留。技能资源与剩余设置精修仅有两个独立源码包，不阻塞本不可变版本，也不代表N01–N08完成。

Eight producer receipts were retained before retiring26 completed duplicate/package/source/delta outputs; external free space rose by2,605,219,840 bytes in that deletion window. Retired staging paths must not be replayed. Current79, required78 rollback, original failures, actual production symbols and warm next-batch caches remain. Two independent source packages cover skill resources and remaining settings; they do not change this immutable release or close N01–N08.

## 后续三星行为 / Subsequent Samsung behavior

新独立用例实际自动解锁，`phone.observe`在2653ms内成功返回受保护Floe页面的导航状态；随后启动已授权计算器时，误触发“用户正在使用手机”的确认。被动观察期间没有人工输入，未进入计算器；普通屏幕超时锁定不计为任务结束重锁。原始41条记录已保存。收尾撤权后才出现的能力撤销回执不作为最初故障；未重试旧任务。临时解锁凭据、权限、控制范围、自建任务及设备导出均已清理，原5条任务保持，三星已恢复休眠。修复进入下一份候选，本版源码和安装字节保持不变。

The fresh case actually unlocked and `phone.observe` returned the protected Floe page's navigation state in2653ms. The next authorized Calculator launch incorrectly requested confirmation that the user was using the phone. There was no human input during passive observation and Calculator was never reached; ordinary idle locking is not task-end relock proof. The41 original records remain saved. Capability revocation appeared only after test cleanup and is not the original fault. The old task was not retried. Temporary credentials, permissions, app scope, test conversations and the device export were removed; the original five task rows remain and Samsung is asleep. The next candidate carries the repair without changing this release's source or bytes.
