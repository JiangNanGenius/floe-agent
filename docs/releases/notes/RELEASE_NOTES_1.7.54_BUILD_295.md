# Floe Agent 1.7.54（295）

## 简体中文

- 修复连续语音等待合成时跳过语音回复的问题；播放失败时保留明确的重试状态。
- 改善长段落与列表的朗读分段，按完整句子处理，分别适配增强语音模型和在线服务。
- 退出语音后保留原来的聊天或任务模式，改善聊天模式中的工具发现。
- 搜索默认返回适量结果，控制长摘要大小；专业数据搜索统一归入搜索工具。
- 图片供应商新增 Kimi Code 入口，可选择账户实际可用的图像模型。
- 生成的二维码在聊天中直接显示图片，支持打开、保存和分享。
- 插件提供统一检查更新、全部更新及逐项更新，保留已有授权设置。
- 更新管理移除固定版本操作，仅在有可用旧版时显示恢复操作。

## English

- Fixed voice conversations skipping spoken replies while speech was still being generated, with actionable playback failure states.
- Improved read-aloud segmentation for long paragraphs and lists, preserving complete sentences and using separate strategies for enhanced voice models and online services.
- Preserved the original chat or task mode after leaving voice, and improved scoped tool discovery in Chat mode.
- Applied a useful default search result count and bounded long summaries; professional data searches now appear under search tools.
- Added a Kimi Code image-provider entry for image models available to the configured account.
- Generated QR codes now appear as images in chat, with open, save and share actions.
- Added unified plugin update checking, Update All and individual updates while preserving existing permissions.
- Removed version pinning controls; restore actions appear only when a usable previous version exists.
