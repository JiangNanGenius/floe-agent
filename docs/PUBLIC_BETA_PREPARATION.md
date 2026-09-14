# 下一版公开 TestFlight Beta：材料准备

状态：材料草稿已准备，尚未提交外部 Beta 审核、开启公开链接或邀请外部测试者。目标是 build 172 之后的下一版；版本号、构建号和最终功能范围待该版本冻结后填写。本轮 172 的内部 TestFlight 分发独立进行。

## 可直接使用的材料

| 材料 | 文件／用途 |
| --- | --- |
| 中英文 Beta 介绍与测试重点 | [metadata.json](public-beta/metadata.json)，内容可复制至 App Store Connect；不是自动提交脚本输入 |
| 英文审核说明 | [review-notes.en-US.md](public-beta/review-notes.en-US.md)，包含导航、模型访问、运行时和权限说明 |
| 演示与附件清单 | [review-assets.md](public-beta/review-assets.md)，已有原始截图、下一版需要重新确认的素材 |
| 隐私与访问准备 | [privacy-and-access.md](public-beta/privacy-and-access.md)，逐项确认接收方、用途、删除和演示访问 |

## 提交前需要补全的实际信息

- 最终版本／构建／SHA、上传 SDK、Apple 处理状态与外部测试资格。不能选择标记为 Internal Only 的构建。
- 从现有 App Store Connect 设置读取并核对审核联系人、反馈邮箱、隐私与支持地址；未核实字段在 JSON 中保留 `null`，不要编造或公开个人电话、审核凭据。
- 用户不提供任何云端 AI Key 或额度。优先验证现有端侧模型的真实运行路径，并提供 BYOK 配置说明与真实操作视频作为补充。不能假定审核员会自行购买 API 服务；如 Apple 要求进一步访问，解释客户端架构并确认其认可的审核方式。此路线尚未获 Apple 确认，不保证通过。
- 确认下一版是否增加账号、付费、订阅或新数据收集。届时相应更新说明、权限用途文本、隐私声明和适用问卷；不能沿用当前草稿中的未知值。
- 确认外部组及首批人数。历史上使用过的组名只能作为查找线索；先读取当前组，避免重复创建或误改内部 Floe QA。

## 外部测试发布顺序

1. 固定下一版源码，完成当轮约定的验证。172 为个人测试跳过的检查不自动适用于下一版公开 Beta。
2. 上传允许外部测试的构建，核对实际 bundle ID、版本和处理状态。
3. 补齐 Beta 介绍、反馈邮箱、What to Test、审核联系人和经验证的本地演示／实际审核访问安排；提交 TestFlight App Review。
4. 审核通过后，按用户确定的外部组、人数及设备／系统范围配置公开链接。产品以 iPad 优先，但不要未经用户决定排除 iPhone 或兼容系统用户。
5. 确认外部组中的构建可测试、链接可接受新测试者，再发布链接。内部组可见和上传成功均不等于公开 Beta 可用。

Apple 允许为公开链接设置设备／系统条件和人数上限；首次外部构建需要 TestFlight 审核。实际提交及发布仍按用户下一版指令执行。依据：[邀请外部测试者](https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers)、[提供测试信息](https://developer.apple.com/help/app-store-connect/test-a-beta-version/provide-test-information)。核对日期：2026-09-15（悉尼）。

## 文案范围

公开介绍以持续 AI 任务、手记、PDF 批注、文档组织和创意工作区为主。不要把全部软件包／模型候选清单写成已经可用，也不要承诺完整桌面 Linux、专业多轨视频编辑或 Microsoft Office 级格式保真。高级执行功能在审核备注中如实说明，不通过隐藏入口或审核专用行为掩盖。

本地运行时及包下载需对照 Apple 2.5.2 核对；第三方 AI 数据发送及授权需对照 5.1 核对。材料清楚描述事实，不预先宣称符合某一例外或保证通过。依据：[App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)。
