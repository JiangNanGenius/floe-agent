# Floe Agent 1.8.62（383）

冻结标签为 `v1.8.62`，源提交为 `034ecf3f643ae8bae60c44c00ad8c8bf7bad0fc2`。本机 Xcode 27.2 构建设备版 Release，同一份通过校验的设备产物用于两条分发链路。

- **内部 TestFlight**　独立查询确认 Apple 构建为 `VALID`，Floe QA 的状态为 `IN_BETA_TESTING`，可以安装。 [签名与内部发布回执](https://github.com/JiangNanGenius/floe-agent/actions/runs/44887066008)
- **GitHub 无签名包**　GitHub 将 `v1.8.62` 标为最新版。安装包大小为 721,777,498 字节，SHA-256 为 `a7ea52f2fb912a52cb744ca1ccbbc9976df12185bebfcc1674d37788f318b890`。独立请求下载地址返回 HTTP 200。 [GitHub Release](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.8.62)
- **Feather**　在线源首项为 1.8.62（383），下载地址、大小、SHA-256 和源提交与 GitHub Release 一致。 [发布与在线源回执](https://github.com/JiangNanGenius/floe-agent/actions/runs/44887072456)

保存期间重开 CAD、恢复已校验的上一保存版本和提交失败回滚均通过定向测试。iPad 模拟器确认 CAD 草图跟踪点随缩放移动，且从「工具 → 加工」可全屏进入切削设置。实际打开含刀路的 Bambu 3MF，从全屏切换层后返回预览，保留所选层。建筑工程在同一工程内切换二维与三维，保存重开后仍能查看原墙体并另存为。实体加工、实体打印和用户原 CAD 文件的恢复结果需以设备和原文件的实际情况为准。

直接拖画墙线、拖动端点、平移、手势锚点缩放和稳定的「另存为」入口在 383 冻结后完成。改动见 `3683d2d590217a8abcaa97cf670150831d042cdb`，户型和同一建筑工程的保存重开回归在 iPad 模拟器通过。
