# Floe Agent 1.7.51（292）

## 简体中文

- 修复连续语音的麦克风启动、识别重启和播放状态处理。
- 改善增强语音的重复使用，首次前台加载后保留识别模型，停止录音后释放麦克风。
- 增加语速与语调调节，改善暂停、停止和打断后的播放衔接。
- 在线语音支持从列表选择音色，已保存密钥可在身份验证后查看。
- 优化表格朗读，保留列名、行内容与数字之间的对应关系。
- 修复火山引擎搜索结果解析，以及配置已同步后仍等待钥匙串的状态显示。

## English

- Fixed microphone startup, recognition renewal and playback state handling in voice conversations.
- Improved repeated use of enhanced speech: recognition models stay loaded after their first foreground use, while stopping recording releases the microphone.
- Added speed and pitch controls and improved playback after pausing, stopping and interruptions.
- Online speech services offer a voice list and authenticated viewing of saved keys.
- Improved table reading to preserve relationships between headings, rows and numbers.
- Fixed Volcengine search result decoding and stale waiting-for-keychain status after configuration sync.
