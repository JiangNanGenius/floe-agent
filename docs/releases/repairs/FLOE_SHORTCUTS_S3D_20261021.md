# S3-D 同次运行文件结果：实现与本地验证（2026-10-21）

状态：源码和相关本地 App 验证已完成；283 尚未归档、上传或交付，S3-D 目标仍保留。Excel 荧光笔抬笔后白底另见[未解决项](FLOE_EXCEL_HIGHLIGHTER_20261021.md)，不由本记录宣称修复。This records implementation and scoped local verification, not an installable release or physical-device acceptance.

## 已实现的契约 / Implemented contract

真实工具输出在提交边界发布为运行拥有的稳定文件快照，记录运行、会话、环境、实际工具调用、文件名、大小、类型与 SHA-256。运行时从可信上下文绑定身份，持久事件保存记录；读取时重新核验。后续工作区文件改写或删除不改变已发布快照。A durable output belongs to one exact run and is reverified before retrieval.

已接入 Office 创建及编辑输出、文档转换、下载、图像生成、媒体导出和 CAD 的明确文件提交路径；`workspace.publishOutput` 可发布一个明确指定且已授权的工作区文件。工具诊断截图、差异和普通附件不因路径或命名被当作用户产物；不扫描目录、不解析助手正文猜测文件。Existing tool producers publish explicit committed files; diagnostic artifacts remain separate.

快捷指令仅新增 **获取运行文件 / Get Run Files**：接收已有运行的精确身份，返回 `[IntentFile]`，可交给系统的快速查看或存储文件。默认只取完整结果；明确开启“包含部分结果”才允许读取进行中、失败或取消运行的已核验产物。缺失、篡改、外来归属、存储损坏、不可用依赖和读取中取消分别返回错误，不能用空列表冒充成功。确无产物的成功运行才返回空列表。旧 Run 的 String 和 C 的查询／等待／取消／文本契约保留。

删除会话先终止并等待拥有的写入，再持久化精确运行清理请求、删除会话和自有快照；失败保留清理请求供重启重试。仍存在的会话、其他运行和用户原文件不会被重试清理误删。Deletion and restart recovery use exact owned identities rather than a storage sweep.

## 实际本地证据 / Local evidence

- Xcode 27A266a，arm64 iOS Simulator 27，完整 App／测试宿主 `build-for-testing` 已通过，6 个编译并行任务；不是仅语法检查。最新测试源码 `1ac76082fa3bbe5e970e1c2a6eee23f6ea41f2e6`；main 合并 `9736a1b6` 的 FloeAgent 树与该资格源码相同。后续指南为文档变更。
- 固定现有 iPad、关闭并行测试；没有新建、克隆、擦除或重置模拟器，运行结束后已关闭。
- 集中 App 契约组共 49 个不同用例：首次 46 通过、3 失败，修正夹具后分别补验 1 项与 2 项通过，均 0 跳过。该组同时覆盖 D 和 Office 契约，不将 49 全部标成 D 用例，也不宣称首次整组无失败。
- D 的真实完整链从原生 Word 生产者，经工具目录、运行时和 SQLite，到实际 `GetFloeRunFilesIntent.perform()` 返回文件；比较真实文件字节与摘要。两项受影响夹具补验源码 `0f3ba40a`：使用生产环境绑定，临时会话使用实际内存存储，未伪造运行归属或绕过只读限制。
- 实际持久化读取、重新构造存储后取回、外来身份拒绝、缺失／变化／取消错误、部分结果策略及真实 Intent 类型返回均在 App 宿主检查；删除生命周期 5 项通过，覆盖真实 SQLite 删除顺序、部分失败、保留重试和符号链接拒绝。
- 原编译和夹具失败、命令、源码指纹、xcresult 与真实生成文件保留。失败只补验对应路径，没有重跑 C 或缩放历史矩阵。

这些证明 App 宿主中的实际链路；不替代用户在快捷指令 App 中组合任意下一步的验收。设备归档后仍需核对导出的 Intent 元数据及安装包；付费联网服务、真实 Pencil 和所有系统自动化组合也不由这些检查证明。

## 尚待交付 / Delivery remaining

1. 处理仍开放的本轮 Excel 问题，固定最终不可变源码。
2. 本地设备归档，立即保存原始包与匹配符号，验证全部版本、平台和来源。
3. 按授权签名上传；分别回读 Apple VALID、未过期和现有 Floe QA 可安装状态。
4. 按规范流程交付稳定无签名 IPA／摘要及同次 awaited Feather，读取实际公开资产和订阅结果。
5. 清理无引用的任务缓存和重复产物，保留当前交付、必要回滚与原始证据，随后接续 S4。

main 已推送回读，已合并且无占用的本轮分支已删除。未创建 283 发布标签，不以源代码合并当作安装包交付。No production App Store publication, website deployment, or repeated 281/282 review action is part of this record.
