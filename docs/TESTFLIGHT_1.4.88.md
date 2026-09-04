# Floe 1.4.88 (119) internal verification / 内部验收

See [bilingual release notes / 双语更新记录](RELEASE_NOTES_1.4.88.md).

## Test on a physical iPad / 实体 iPad 验收

1. Enable background PiP, start an ordinary chat, leave Floe using Home/app switching, and confirm a real system PiP window. Foreground return retracts it; task completion closes it. Repeat from Canvas. Force-quitting is not backgrounding.
2. Request the SSH-first VNC repair route, then connect → observe → click → observe. Check screenshot coordinates against the actual click. Unchanged failures must not loop or detour into memory housekeeping.
3. Connect four supported reference images to a generation node. Verify four independent input edges, one output edge per result, persistence after reopening, model-cap rejection, tidy placement, and connector drag isolation.
4. Edit HTML, Python, Swift, JSON and Markdown using create, append, replace and patch. Check conflict protection and binary rejection.
5. Run device DNS/TCP and local HTTP diagnostics; verify explicit-host ping/traceroute and blocked metadata/credential URLs.
6. Set a general auxiliary LLM and verify memory/title/skill routes. Confirm image, video, vision and approval settings remain unchanged.
7. Exercise a long stream through background/foreground transitions. Export diagnostics after any unexpected exit; include MetricKit/IPS/Jetsam evidence when available, without credentials.

1. 开启后台 PiP，普通对话开始后使用 Home/切换应用，确认真实系统悬浮窗；回到前台收回，任务结束关闭。画布重复测试；强制结束进程不等于切后台。
2. 明确要求先 SSH 修复 VNC，再连接、观察、点击、再次观察，核验截图坐标。同一失败不能循环重试或转去整理记忆。
3. 四张参考图各有独立输入边，每个结果各有输出边；重开仍保留，超模型上限拒绝，排列整齐，拖端口不拖动框。
4. 对 HTML/Python/Swift/JSON/Markdown 新建、追加、替换、补丁，并测试冲突保护和二进制拒绝。
5. 验证本机 DNS/TCP/内网 HTTP、指定主机 ping/traceroute，以及元数据和凭据 URL 拒绝。
6. 指定通用辅助 LLM，检查记忆、标题和技能的实际路由；生图、生视频、视觉与审批保持独立。
7. 长输出多次前后台切换；异常退出后导出诊断，尽量附 MetricKit/IPS/Jetsam 证据，不附凭据。

No external beta before acceptance. / 通过前不开外部公测。
