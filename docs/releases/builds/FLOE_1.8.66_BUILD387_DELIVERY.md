# Floe Agent 1.8.66（387）

冻结标签为 `v1.8.66`，源提交为 `3dabc3b9d814db91fdca3997c5284c2860915e4a`。本机使用 Xcode 27.2 构建设备版 Release，核对 App 和四个扩展的版本与签名，保留 19 份匹配的调试符号。

- **内部 TestFlight**　Apple 独立回读为 `VALID`，Floe QA 为 `IN_BETA_TESTING`，可安装。 [内部分发](https://github.com/JiangNanGenius/floe-agent/actions/runs/44918222103)
- **GitHub 无签名包**　GitHub 将 `v1.8.66` 标为最新版。安装包为 721,779,017 字节，SHA-256 为 `d86c1880b2d80d7f81b2dd09ea2670e6b14e7575a42bd68095b6961b975b8d7b`。 [GitHub Release](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.8.66)
- **Feather**　线上首项为 1.8.66（387），文件大小、下载地址、摘要和源提交与 GitHub 一致。 [发布与在线源核验](https://github.com/JiangNanGenius/floe-agent/actions/runs/44920619544)

## 运行验证

- 虚拟 CPU 使用编译期 ARM 指令加速 CRC32、CRC32C 和 SHA-256，保留原软件回退，JIT 保持关闭。80,000 组 CRC 和 40,000 组 SHA-256 向量逐字节一致。真实四 vCPU 客机的 96 MiB SHA-256 由 3.128 秒降至 2.995 秒，ZIP CRC32 由 3.477 秒降至 3.437 秒。设备对象已核对指令。 [性能记录](../../ARM64_RUNTIME_PERFORMANCE.md)
- 在真实 ARM64 Debian 客机验证了磁盘队列积压时 CPU 继续推进，以及多个 vCPU 完成时合并唤醒。1、2、4 个 vCPU 均通过文件和计算结果校验。四线程 zlib 在 1 个 vCPU 用时 14.65 秒，在 4 个 vCPU 用时 8.49 秒。文件混合负载的耗时随运行顺序波动。 [性能记录](../../ARM64_RUNTIME_PERFORMANCE.md)
- Apple M5 Pro 上的客机确认 Vulkan 返回 Apple GPU 型号和集成 GPU 类型。实际纹理回读、4,096 个像素的渲染校验和 BLAS GPU 提交均通过。virtio-gpu 负责客机连接，Apple Metal 执行硬件渲染。无头 Linux 的显示接口仍未读到 EDID，独立协议检查确认宿主返回了完整 EDID 回包。真机 iPad 的图形与编码性能待测。 [Linux 镜像及源码](https://github.com/JiangNanGenius/floe-agent/releases/tag/floe-linux-arm64-metal-20261122.1)
- 本机 M5 Pro 使用同一套 VideoToolbox 后端实测了 22 项格式与方向。H.264、HEVC、ProRes 422 和 ProRes 4444 各自通过硬编和硬解，AV1 与 VP9 通过硬解，MJPEG 走原生软件。旧配套客机的端到端硬件编码回执记录了三个硬件输出、零软件输出。格式、像素位深及 iPad 吞吐以当前设备和客机实际回执为准。
- 使用已安装的上一版 Linux 镜像在固定 iPad 模拟器通过终端验收，核对了连续 2,000 行输出、Ctrl‑C 和终端缩放。本版沿用同一镜像绑定，新增校验指令路径另在真实客机验证。独立的 App 离线 pip 用例停在持久化初始化，子智能体用例停在父任务所有权检查。
- 从编译后的 App 回读了云端和本地模型的 GPU 提示，工具定义及能力发现检查通过。另一个组合测试有五条旧 Linux 启动和重启提示断言失配，原测试结果保留。原生硬件渲染、计算和视频编码分别需要实际证据。
- 同一客机的离线 NumPy 2.2.6 安装耗时约 33 秒并通过导入和计算。单独分段采样测到 14 MB wheel 从工作区复制 1.04 秒、pip 启动 9.67 秒、tmpfs 解包 12.52 秒。该样本不覆盖网络下载或用户设备的完整安装。
