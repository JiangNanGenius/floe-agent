# Floe Agent 1.8.33（354）内部 TestFlight 交付

2026 年 11 月 15 日，Apple 返回构建有效（`VALID`）、未过期，内部状态为 `IN_BETA_TESTING`。Floe QA 是唯一的测试组，Apple 上的中英文测试说明与冻结版本一致。354 的外部测试组和 Beta 审核提交均为空。[签名与上传记录](https://github.com/JiangNanGenius/floe-agent/actions/runs/43696411205)

353 的公开 Beta 和正式版仍关联原构建和原提交。交付 354 后，公开 Beta 状态为 `WAITING_FOR_REVIEW`，正式版状态为 `WAITING_FOR_REVIEW`，发布选项为 `AFTER_APPROVAL`。

## Linux 加速

终端可将加速工具离线安装到选定的 Debian ARM64 项目。v8 镜像中的项目在关闭、重开后仍能调用工具，另一个项目保持独立。在 Apple M5 Pro 的 Venus 设备上，256 × 256 矩阵计算与 CPU 参考逐项一致，GPU 完成一次提交，CPU 回退为零。OpenGL 在项目虚拟屏幕上正确读回 16 × 16 像素。装入 Debian EGL 运行库后，无窗口 EGL 也在同一 GPU 上通过像素读回。[本版更新说明](../notes/RELEASE_NOTES_1.8.33_BUILD_354.md)

OpenCL 入口能枚举驱动并检验实际计算。Mesa llvmpipe CPU 设备完成了缓冲区读写和 64 项内核验证。Debian Rusticl 25.0.7-2+deb13u1 在 Zink/Venus 上可枚举 M5 Pro，但计算会终止图形宿主。该组合现在会返回具体诊断，随后客机仍可执行命令并正常退出。基础 v8 镜像缺少 OpenCL 驱动，Apple GPU 上的 OpenCL 内核执行仍未通过。

V4L2 按实际队列格式区分编码和解码。ARM64 Linux 设备接口测试覆盖了高编号节点、单向编解码器、摄像头和当前传输路径不支持的节点。此次未在真实视频编解码设备上运行硬件编解码。

## 创作工具和设备构建

预研发整合阶段通过了 140 个 iPad 模拟器用例和 57 个图片工作台测试。随包画笔、橡皮遵守落笔时的选区与羽化边界。复查了冻结源码编译的 34 个 ARM64 游戏模块对象，未发现已检查的原生 JIT 接口导入，签名 App 也没有 JIT 授权。Apple Pencil 手感及 TestFlight 安装后的真机表现留待内测反馈。

Xcode 27.2（27B52）从 `v1.8.33` 的源码 `9818b54453a8b786d4c23753bb08f7b40ca58c7f` 构建 iPhoneOS Release。主 App 和四个扩展均为 1.8.33（354），19 份 dSYM 与各自设备二进制的 UUID 匹配。签名 IPA 的主程序 UUID 与本地构建相同，内置 Linux 安装包、安装脚本和命令入口逐字节匹配该标签。签名 IPA 的 SHA-256 为 `f3b17129b09250d18d093401d6733f1d84200102ea5d5a8c424ef15f12e85685`。
