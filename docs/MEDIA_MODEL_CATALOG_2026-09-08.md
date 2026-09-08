# 图像与视频模型核对 — 2026-09-08

本轮按官方 API 正文核对模型标识和参数，预设版本升级为 3。旧预设继续保留，用户自行配置的模型 ID 不会被覆盖。

| 服务 | 本轮目录 | 已对齐的参数 |
| --- | --- | --- |
| 火山图像 | Seedream 5.0 Pro / `doubao-seedream-5-0-pro-260628` | 1K、1.5K、2K；最多 10 张参考图；单次一张成图，不发送旧版组图参数 |
| 火山图像 | Seedream 5.0 Lite / `doubao-seedream-5-0-lite-260128` | 2K、3K、4K；保留现有最多 10 张参考图的应用限制 |
| 火山视频 | Seedance 2.5 / `doubao-seedance-2-5-260628` | 4–30 秒；480p、720p、1080p；首帧模式使用 adaptive 比例；不显示固定 seed 能力 |
| 阿里图像 | Qwen Image 3.0 Pro、Wan Image 2.7 Pro | 目录已有；保留官方模型 ID |
| 阿里视频 | Wan 3.0 / `wan3.0-video` | 2–30 秒；480P、720P、1080P；发送 resolution / ratio；首帧素材使用 input.media |

官方来源：

- [火山图片生成 API](https://docs.volcengine.com/docs/82379/1541523?lang=zh)
- [火山图片生成教程](https://docs.volcengine.com/docs/82379/1824121?lang=zh)
- [火山创建视频生成任务](https://docs.volcengine.com/docs/82379/1520757?lang=zh)
- [阿里图像模型](https://help.aliyun.com/zh/model-studio/image-model)
- [阿里 Wan 3.0 视频 API](https://help.aliyun.com/zh/model-studio/wan3-video-generation-api-reference)

火山文档为动态页面，核对的是浏览器加载后的官方正文（页面更新时间 2026-09-08），不是搜索摘要或第三方转发渠道。测试覆盖请求结构和边界，未发起计费生成请求；账户开通、地区权限及最终成片仍需实际账户验证。视频参考模式仍受现有应用入口约束，本轮不声称已经提供官方所有多模态编辑能力。
