# Floe Bridge 1.1.2（5）交付记录

日期：2026-11-05。不可变来源：`502b9e383df5ac18dde626a9c9a543be0f59ae62`，标签 `floe-bridge-v1.1.2`。

修复菜单栏设置窗口没有出现的问题。设置、快捷键和重新打开应用共用同一个原生窗口，保留通用、存储、权限页面；关闭后可再次打开。

## 实际验收

- Swift 6 本地编译成功；原生界面确认三个设置页面可见，关闭并重新打开设置成功。
- 使用实际 `MacBridgeClient` 完成本机认证配对、指纹确认、文件上传、真实 PTY 命令、输出读取和文件列举。
- 终端实际返回 Darwin、PTY 及文件传输标记，作业退出码为 0。
- 临时验收配对已撤销，对应合成任务与文件已清理。保留用户原有配对、钥匙串和工作文件。
- 没有新增录屏或辅助功能授权；上述验收不代表屏幕控制功能经过完整验证。

## 公开分发

- Developer ID 签名、强化运行时、公证及装订完成；本地 Gatekeeper 检查通过。
- App 公证首次装订遇到网络错误，保留原始失败后，对同一已接受的签名 App 完成本地装订，没有重新提交或更换来源。
- [GitHub 下载](https://github.com/JiangNanGenius/floe-agent/releases/tag/floe-bridge-v1.1.2)已公开；未改变主 App 的 latest 指针。
- 公开 DMG 实际下载后的大小和摘要一致；来源、标签和版本一致。
- 自动更新源保留旧版本，新增 1.1.2；对最终 DMG 的 Ed25519 签名独立验证通过。
- [官网 Bridge 页面](https://www.floe-agent.com/bridge)经现有内容同步后显示 1.1.2，没有另行部署或重启网站。

```text
Floe-Bridge-1.1.2.dmg
bytes: 4646823
SHA-256: 84f897eb1b10c0371e75c02bff0b0e1220ebe876fcaa261e9a496b6599b5f277
```

本机测试应用及生成的重复 App 已卸载或移除，Bridge 不再运行。当前公开 DMG、校验文件、来源及必要验收证据保留；安装应用与用户数据分别处理，没有删除原有用户工作文件。

## English

Bridge 1.1.2 (5) was compiled locally, signed, notarized, stapled and publicly published. Native settings reopen, authenticated local pairing, a real PTY, file transfer and output retrieval passed. The public archive, source binding and signed update feed were independently checked. Temporary pairing and test applications were removed, while existing user data and pairing were retained. Screen-control permissions were not added or fully qualified in this acceptance.
