# Floe Agent 1.8.51 (372)

App Store Connect 已确认构建可在内部 Floe QA 安装。构建未过期，处理状态为 `VALID`，内部测试状态为 `IN_BETA_TESTING`。Floe QA 是唯一关联组，外部 Beta 审核提交数为零。源码标签为 `v1.8.51`，提交为 `a31131d6f2e96add4335f87c962a026db003c1c0`。[签名与上传回执](https://github.com/JiangNanGenius/floe-agent/actions/runs/44486904731)

已在设备 Release 可执行文件中核对中文协议原文，在模拟器分别检查首次启动和旧同意记录。原有同意记录在升级后继续有效。

iPad 模拟器通过游戏工作台导入和试玩了 RPG Maker MV 游戏，验证了手选 `www`、从标题进入地图，以及升级并重启后打开已有工程。还检查了 Godot 网页导出、GDevelop、Twine、Phaser、WASM-4、Ren’Py 等游戏的实际画面。XP、VX 和 VX Ace 源工程在 Linux 试玩环境准备阶段出现容器保存错误。Unity、Cocos Creator 和 RPG Maker MZ 源工程需要相应导出工具；本轮未完成这三种源工程的试玩。

Apple confirmed the unexpired build is installable in the internal Floe QA group. The release binary contains the updated agreement, and the simulator retained consent across upgrades. Physical-device acceptance remains with internal QA.
