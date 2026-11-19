# Floe Agent 1.8.52 (373)

App Store Connect 已确认构建有效、未过期，内部测试状态为 `IN_BETA_TESTING`。唯一关联组为 Floe QA，外部 Beta 审核提交数为零。源码标签为 `v1.8.52`，提交为 `04eff6314ecb94726a47438d6b60ed3dd81b5ab7`。[签名与上传回执](https://github.com/JiangNanGenius/floe-agent/actions/runs/44517865083)

修复了试玩准备期间文件内容一致、仅时间戳变化时误报“错误 16”的情况。iPad mini 模拟器通过系统文件选择器导入一个 1,445 个文件、约 204 MB 的 RPG Maker MV 游戏目录。使用同一样本作单次前后对照，导入耗时从 19.1 秒降至 13.7 秒，首次点击试玩到打开播放器从 23.3 秒降至 14.3 秒。安装候选版本并冷启动后，从已有工程再次试玩耗时 12.3 秒，已看到游戏标题画面。用户上传的日志未标明触发错误的文件，原游戏仍待真机确认。

新版用户协议采用分段排版和固定底部操作区。已核对发布包内的中英文正文，并在 iPad 模拟器验证首次同意、拒绝后重新打开，以及升级后沿用已有同意记录。

Apple confirmed build 373 is installable in the internal Floe QA group. The simulator opened an imported RPG Maker MV game and retained prior agreement acceptance. The reported game still awaits physical-device confirmation.
