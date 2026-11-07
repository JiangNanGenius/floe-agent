# Android Alpha46 交付记录

2026-11-07，[Android 0.1.0-alpha.46](https://github.com/JiangNanGenius/floe-agent/releases/tag/android/v0.1.0-alpha.46) 已公开，code65。App与原始签名组件固定源码为 `af9e95845a09df2f939047601e21563d3a476ea3`；主APK为163976223字节，SHA-256：`c28818af64fd2fc15b9618928e8dda0c8c9b1e3f53aab350ba9eeb4b0242ea43`。这是允许存在已知问题的中间版本，整轮N01–N08仍继续。

## 本包变化与构建

- CAD查看器24份固定资源移入按需签名组件，保留摘要校验、只读预览和视口截图；不增加建模或本地模型。旧CAD目录缓存单独保留，不冒充已安装组件。
- Office／CAD共用实际下载、取消、系统确认、安装回执、前台恢复及缓存统计；组件安装与App升级互斥。Play使用其动态交付通路，Full使用同包签名组件。完整包升级后可选组件需按新版本安装，用户文档保留。
- 最终Full生产构建、Play相关编译和两项新增组件边界检查通过，约3分11秒。未变的10项目录事务证据复用，不扩大为新后端全部行为已验收。
- 原生3096份生产输入未改，复用native13；实际58行封装记录、签名、ARM64/JNI及16KiB核对通过。原生符号保留；本包未启用R8，不虚构混淆映射。

原始源码绑定拒绝、首次Full编译错误和CAD导出拒绝都保留。CAD导出曾遇到AGP生成的532字节空R资源桩；独立提交 `9a6da1f976e93a3337645f2aaebe0775687a1821` 只收紧定义并允许这一精确摘要、无字段／业务入口且manifest声明无代码的资源桩，其余DEX／原生内容仍拒绝。没有修改、重签或重建已保存APK；对应源码归档分别记录App来源与打包核验策略来源。

## 三星实际结果

- 公开Alpha45通过App发现46，显式选择完整包，实际下载进度、摘要校验、系统安装及重开成功。系统分别确认主程序和运行环境，运行环境完成正常Play保护扫描后安装；没有通过ADB安装46。两包均为65，安装字节匹配公开APK及其内嵌运行环境，原UID保留，原项目、任务及测试文件仍可打开。
- 新CAD首次使用实际下载公开组件。先取消系统安装确认，模块保持未安装并出现重试；显式重试后系统安装成功，实际安装split摘要与公开组件一致。取消提示过于笼统，仍记待修；本次没有把系统确认取消当作下载取消验收。
- 组件安装导致App进程结束，重开回到首页，没有自动返回原文档，此项仍未通过。手动重开原STL，实际显示4面模型；关闭预览后，在Wi-Fi关闭且默认网络为none时再次打开，模型仍显示。网络随后恢复，不扩大为全部格式、卸载或跨版本可选组件衔接均已通过。
- API37复用平板只检查同一APK启动、设置双列、组件入口和二级返回，实例已关闭。三星设置／常亮恢复，停留空白首页后息屏；没有启用新权限、配置App解锁凭据、恢复旧模型任务或发起新云端调用。

## 公开下载与升级证据

45→46补丁51466008字节，已真实重建至同一目标APK摘要；此项为本地重建证据，本轮三星走完整包。七附件保持一份主APK、Office／CAD可选组件、增量、更新清单、校验及对应源码归档。全部匿名下载字节、标签→源码和真实客户端更新发现接口已读回，iOS Latest仍为 `v1.7.74`。冻结的发行说明保留发布时状态，本记录追加其后的实机结果。

## 清理与剩余事项

本批实测回收3485839360字节，约3.49GB：移除19处构建生成物，退役6处Alpha44公开安装产物，归并3处相同不可变副本，移除8个发布／安装暂存目录。旧包逐份核对公开摘要并保留恢复地址，生产回执先导出；当前46、回退45、源码、原生符号及近期有具体用途的缓存保留，未动用户文件、凭据、SDK／AVD或iOS修改。连同上一批8.1GB，本轮累计实测约11.6GB，不重复计入更早历史清理。

前一批误退役的Alpha45候选03原ANR APK仍无精确字节，保留的源码／现场／摘要／符号及更正记录不作为原包恢复证明，不能宣称所有历史失败包仍在。

继续修复：组件安装后文档返回、取消提示与组件生命周期余项；手机多步操作、条件计划、跨项目隔离、专业编辑保存及全局UI密度。无新增付费测试或旧任务重试。已提交iOS基线仍为 `e4d334904`，本批未新增已提交Swift功能差异，不重启全库对账。

English: Alpha46 adds the signed on-demand read-only CAD component and shared Office/CAD installation lifecycle. Relevant Full/Play compilation, two new boundary tests and native/package checks pass. Samsung actually upgraded from public45 using the in-App full download; both packages, installed bytes, UIDs and existing project access were checked. The new CAD split was cancelled at system confirmation, explicitly retried and installed; a synthetic STL rendered and reopened with no default network. Returning automatically to the document after installation and cancellation copy remain open. All seven public assets and update discovery were read back, preserving iOS Latest. Cleanup measured about3.49GB this batch; current46 and rollback45 remain. This is an intermediate delivery, not whole-goal acceptance.
