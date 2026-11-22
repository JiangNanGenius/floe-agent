# Floe Agent 1.8.70（391）

冻结源为 `041f4d9c3fc6625986cae7985e331cf0a47d8e1b`，标记为 `v1.8.70`。采用 Xcode 27.2（27B52）完成本地 iPhoneOS Release 构建。App 和四个扩展版本一致，19 份调试符号与二进制匹配。

- **内部 TestFlight**　Apple 确认构建有效、未过期，Floe QA 已可安装。 [签名与上传](https://github.com/JiangNanGenius/floe-agent/actions/runs/44998232037)
- **GitHub 与 Feather**　GitHub 已将 `v1.8.70` 标为最新版。无签名 IPA 为 721,827,389 字节，SHA-256 为 `79fbc83db21bde82c8c64427b2ff3e02d2414978f76828567902e57685dec97a`。在线 Feather 的构建号、下载地址和包摘要已核对。 [GitHub Release](https://github.com/JiangNanGenius/floe-agent/releases/tag/v1.8.70) · [发布和更新源核验](https://github.com/JiangNanGenius/floe-agent/actions/runs/44999566276)

## 稳定性回归

- 同一 Debian 客机镜像完成一轮基线和三轮候选，共 84 项结果一致。候选覆盖单核、四核、重启后复跑、内存重叠和对只读页的写入异常。 [ARM64 性能工况](../../ARM64_RUNTIME_PERFORMANCE.md)
- Ren’Py 的现有网页导出与从 RPA 重新生成的网页包各通过三次同源 WebKit 运行。TyranoScript 通过三次运行和跨重开存储回读。54 项游戏定向测试通过，另有 6 项缺少所需实包素材。
- 固定 iPad 模拟器的系统启动服务超时，整包运行仍待验证。吉里吉里和 ONS 完成独立组件实测，Floe iPad 播放入口待接入。
