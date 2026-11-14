# Floe Android 1.0.7／115 交付记录

[GitHub 预发布](https://github.com/JiangNanGenius/floe-agent/releases/tag/android/v1.0.7) 已公开。注解标签 `android/v1.0.7` 固定实际生产源 `908133880f0b3d722d98e2451567657a077d4e9f`，包含 N11 修复检查点 `b7e8805374bb33d4229cca11e27241644c4a057c`；没有移动旧标签或冒称已移植 iOS345。

## 精确产物与检查

- Full APK：`Floe-Android-1.0.7-full-arm64-v8a.apk`，166,456,567 字节，SHA-256 `bbfdf80c9772272de07af26cf09af1909bfe02a2eb24b3e5066474a64a7534e7`。
- ARM64、minSdk28、targetSdk37；仅自行分发 Full。四类包实际元数据均为115。
- native53 的真实 Swift6 ARM64 对象／两库链接约418秒，2,742项规范输入绑定该来源；实际Full与两个可选组件约129秒完成。58项原生绑定、16KiB对齐及主包／运行组件／Office／CAD的API28／29签名检查通过。静态16KiB检查不冒充三星4KiB设备的16KiB运行验收。
- 29个宿主方法按原24项通过和五项数据库夹具定向复测闭合；原异步锁编译失败与外键失败保留，断言、外键和生产边界没有放宽。一个仅Linux／Android条件方法未在macOS执行，真实Android对象／链接另行通过。

本版修复生图返回图片地址后的结果下载，保留有界下载、取消、重定向及阶段诊断。同一可信所有者／运行／媒体类型结果不明时，持久事务阻止换提示、模型、供应商或调用标识的替代提交。旧114任务不自动重试，提供商接收与计费仍不确定。浏览器保留真实加载失败，成功新导航后恢复，不以标题或空DOM猜测失败。

## 三星与公开交付

三星SM-G9810／Android13正常签名双包114→115覆盖安装保留原UID和数据，安装字节与产物一致。新Ark Plan／ark-code-latest任务只有一次真实生图请求；JPEG已落盘84,830字节，Linux实际摘要与交付记录相符，并在App原生预览实际打开。不可解析网址返回ERR_NAME_NOT_RESOLVED，随后Example Domain恢复，清单5／5并正常endTurn。

该小测点过授权，只作功能验收，不能记为零辅助录像。最初Linux缺file命令由模型自行换用摘要和JPEG头校验。navigate可能早于加载完成返回，最终结果由随后observe／截图验证，该限制已在公开说明中保留。1.0.5五项实机证据继续保留，没有冒充在115全部重跑；覆盖安装也不等于新OTA验收。

附件仅五份：一个完整APK、Office／CAD按需组件、对应源码和SHA256SUMS，没有单独运行组件或增量旁路。对应源码清单、许可和组件绑定逐项校验。五附件合计295,722,513字节，匿名完整下载、远端摘要及不可变标签来源一致。115／114／113／108／65实际生产更新器从65／81／1.0.0／1.0.5／1.0.6发现完整1.0.7，当前1.0.7无更新；一次微型驱动编译后删除临时class。iOSLatest读回时为v1.8.22，其独立推进权保留，不将其固定或回退。

发布后退役本轮源码打包暂存、重复大附件与运行组件提取副本。准确公开资产、当前／回滚、来源、符号和原始失败保留；并发归档时的卷空闲变化不算本任务独占回收量。

## 录像与后续

精确115已交录像线程独占三星，原始自然目标只发送一次；自动允许、真实控制及录制在Send前准备。主线不在录制中操作设备。完整海报／视频播放保存、两条日历保存再打开仍单独验收，不以本次小测或公开下载替代。

固定iOS342→345共97条FloeAgent路径，见[增量记录](../FLOE_ANDROID_IOS_DELTA_AUDIT.zh-CN.md)。延续原编号及轻量Android边界，不增加iOSVM、本地模型、双端实时同步或独立重型编辑器。

English: Android1.0.7/code115 is public from immutable908133880 with actualnative53/Full bindings and29 accounted host methods. A fresh Samsung functional task generated one image, verified and opened its file, and recovered from a real browser error. Operator approvals are disclosed; autonomous recording remains separate. All five public assets and five current/retained production update readers passed. The preserving-data ADB install is not newOTA acceptance. Disposable preparation copies were retired while exact assets, rollback, symbols and original failures remain. Fresh115 recording continues independently.
