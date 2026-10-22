# 1.7.45（286）交付记录

2026-10-22：S5～S7 已完成代码、集中验证与交付。用户明确确认真机验收，后续设备问题按新反馈处理；此为用户验收记录，不改写历史模拟器或组件证据的范围。

- 不可变 `v1.7.45` → `5d3a24d0b250e2e4a810949b962bc3aacdb8b936`；本地 Xcode 27A266a / iphoneos27 / arm64 Release 归档及打包通过，全部五个 App／扩展均为 1.7.45（286），14 份匹配符号已保留。
- 未改变的运行时路径复用本轮已有验证，另核对 NFC／健康元数据及所有五份签名声明。285 的 Apple 校验失败、不可变标签和最小复现资料保留；未将 285 记为上传或可安装。
- [签名上传与处理](https://github.com/JiangNanGenius/floe-agent/actions/runs/39705214507)完成；[独立只读核对](https://github.com/JiangNanGenius/floe-agent/actions/runs/39706981822)确认 286 `VALID`、未过期、Floe QA `IN_BETA_TESTING`，内部可安装。
- Safari 向既有 `publictest1` 提交一次；页面回读为“正在等待审核”，构建详情关联 Floe QA 与 publictest1。286 中英文测试内容已核对；新版审核备注保存后刷新仍保留。外部可安装仍待 Apple 批准，275 正式 App Store 提交保持不变。
- [稳定 latest Release](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.7.45)及[同次 awaited Feather](https://github.com/JiangNanGenius/floe-agent/actions/runs/39707008210)完成。下载实际安装包后通过正式发布验证器：真实 arm64 iOS 设备可执行文件、不可变标签源码、远端摘要、校验文件及 latest 指针全部匹配。IPA 为 809,516,422 字节，SHA-256 `331cbe2f6f951ac6a966361d4681587735f866085cf4099f524d18afe34ed1db`；在线 Feather 的版本、构建、源码、URL、大小及摘要逐项一致。
- PR #15／#16 已合并 main，本轮两个已合并分支本地及远端均删除；Feather 更新已快进同步。私有传输草稿删除后 release 与 tag 均回查 404。

## 清理与保留

已移除 286 的一次性 DerivedData、归档展开副本、传输暂存；先前测得内置盘可用空间增加 3,604,983,808 字节，外置卷增加 2,867,200 字节。失败 285 的重复大包／展开副本移除后，外置卷实测增加 3,757,264,896 字节，原失败日志与复现胶囊保留。

最终已验证全部符号压缩包和原始设备包后，再移除 286 展开 App／符号副本及已消费的传输 ZIP，外置卷实测增加 2,953,904,128 字节。保留当前原始设备包、公开无签名 IPA／校验、全部匹配符号、必要 284 回滚、失败与成功证据；依赖缓存供下一组已提出的修复增量使用。模拟器全部关闭，无活动编译进程。

## 后续用户反馈

286 交付完成后新增两项：Excel 打印网格线及自定义比例、设置下方自动更新预览；Skill 来源标签与审计 Skill 来源追查。另开下一组实现及验证，不改变已发布标签或安装包。
