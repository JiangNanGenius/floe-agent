# Floe Android1.0.13／122交付记录

日期：2026-11-15（Sydney）。[公开中间预发布](https://github.com/JiangNanGenius/floe-agent/releases/tag/android/v1.0.13)。仅独立分发Full，Google Play线不再构建或发版；iOS发行保持独立。

## 固定源码与产物

- 不可变标签：`android/v1.0.13`，实际App源码`ecefc6495d8e29cc52718344b976fdcd890df5e8`。后续文档与iOS提交不移动此标签或替换其安装包。
- 修复前台直接查看与后台设备通路的已接受查看操作归因，关联严格绑定任务／运行／原生代际／当前宿主、最多5秒。真实触摸、停止、接管、锁屏及撤权继续生效。设备会话创建不再伪造人工输入。
- 本机JDK21.0.12.1、Gradle9.6.0、SDK37实际执行FullRelease主程序与Office/CAD组件生产；Gradle记录`BUILD SUCCESSFUL in 4m 4s`。六个改变边界JVM suite共63项通过，0失败／错误。
- Core／Authority的2744项规范源、七组输入与Native60相同，复用其实际ARM64生产结果；其原生产源码为`ff314e8924dac0c473891fc0941766a6611a866b`，没有宣称在本App提交重新编译。当前APK的58项原生绑定、16KiB和主包／runtime／Office／CAD四包API28–29签名与版本均通过。

## 三星验收及其边界

旧三星Android13实际保留数据安装121→122，主包与runtime UID保持；已保存模型与新建基线项目可见。此证据不扩大为历史数据恢复或App内OTA安装通过。

- **成功组件用例C：** 同项目新任务，一次发送、发送后零业务辅助，49个连续事件、5组工具配对全部成功。先用任务Linux执行明确的`sleep20`／35秒超时作为输入时间夹具，再首次观察、枚举查看器、打开真实327字节PNG并第二次观察。首次观察77毫秒，查看交接288毫秒，交接后观察179毫秒，真实前台为Samsung Gallery并返回47节点；没有再次弹出占屏确认。该限定组件用例不等于原199字自然目标已经通过。
- **真实输入受控用例B：** 近期真实App输入触发确认，后台通知可返回原问题；人工取消提问再Native Stop，唯一观察收到拒绝，没有晚到设备动作。无障碍仍启用时，相关通知和覆盖窗口均为0；没有自动批准、假造人工回答或继续原任务。
- **原失败用例A保留：** Linux生成、校验、发布和Gallery打开有实际回执；一次文件路径选择失败，以及四次错误使用旧观察的`device.act`被拒绝。模型没有真正请求交接后的第二次观察，不能把此例计为原生路由通过。
- C自然结束后，无障碍仍启用时浮球和控制／执行通知已消失。停止时清除浮球的主体代码未改，沿用1.0.11已经完成的可见浮球接管收尾实机证据，不伪报本轮重复执行了相同场景。

原121／Full15未捕获具体触发输入，不能以候选修复或取消后的拒绝结果倒推其全部来源。此前原始导出、参数、录像与诊断边界继续保留。完整跨App视频、成品自查及日历保存重开由独立的新Full16原自然目标继续验收，不恢复旧失败运行。

## 公开下载与更新发现

五个附件合计295928406字节，全部从匿名公开下载地址完整流式读回，字节数／SHA256、GitHub服务端摘要与远端标签源码绑定一致。本次全部使用标准公开附件地址，没有使用可用性回退。读回时iOS Latest为`v1.8.25`，Android以`--latest=false`发布。

复用实际Full122、Full121和Alpha65生产更新器字节码，一次编译小型读取驱动，12个已安装版本样本验证：Alpha65／1.0.11／1.0.12发现完整1.0.13，1.0.13自身不重复提示；已知问题和校验文件解析一致。没有增量包或增量清单，保留完整包回退及镜像选择。此读取与字节证据不冒充三星在线下载安装验收。

| 附件 | 字节 | SHA256 |
| --- | ---: | --- |
| Floe-Android-1.0.13-full-arm64-v8a.apk | 166662415 | `a9ff6fed74304bc0c43176d62426cef7362273bd8876781491008f26c4ab2c0f` |
| Floe-CAD-Preview-1.0.13-full-arm64-v8a.component | 10649569 | `806167c65eaaaddb731665708fbb5656a594730a54ece76dd87770ae129cfb79` |
| Floe-Office-Preview-1.0.13-full-arm64-v8a.component | 115007352 | `4f5ff688a2e0fc991e5b9da1cd93120801ebd2294a25531e38e80aa741dd2fd6` |
| SHA256SUMS | 452 | `926ea0f81bd485b1c5a70aa5e624fc2ff6134e96eb45a8e10db3b9b14ddcfaa8` |
| floe-android-corresponding-source-1.0.13.tar.gz | 3608618 | `9eca965a92f54bcea1f33b3078d73e5d4d540375852a22fe168fb668121e530d` |

附件仅一个主APK、两项按需预览组件、对应源码与SHA256SUMS。67项实际法律文件与封装源码匹配，源码归档各清单成员已校验；没有新增执行别名、依赖、权限或数据库迁移。

## 收尾与剩余项

临时无障碍、自动控制、目标应用、浮球偏好、自动解锁及写入设置已恢复，原共享文件夹与只读选择保留；三份本轮手机导出副本经与宿主原件逐字节核对后移除。三星已正式交给录像线程，实际唤醒7／1800000作为明确借用移交，由接收者结束恢复真实基线0／30000；主线程交接后不再操作设备。

完成的原生合并／JNI打包副本、源码封装staging和匹配已保存字节的APK缓存副本已清理；保留当前122、必要回退121／119、原始符号／源、失败及实机证据、后续仍有用途的Kotlin／依赖缓存。

内置屏幕提问语言一致性、语义事件的短时歧义、特别大的全局环境目录、通用Linux常驻服务及完整容器回收继续列为未闭合项。C01–C08全项和完整自然目标不因此标记完成。新发现独立iOS功能仍按后续范围记录。

English: Full122 is public from immutableecefc6495, with63 targeted JVM cases, reused unchanged native60 ARM64 inputs,58 bindings/16KiB and four API28–29 signer checks. Samsung C proved Gallery VIEW→structured observe with an explicit timing fixture; B covered a real-input question return/cancel/Stop, while A's original model failures remain unaccepted. All five public assets and12 production-parser version samples passed. Component, ADB installation, OTA installation and natural-goal recording evidence remain distinct. Full16 continues independently; managed services and container reclamation remain open.
