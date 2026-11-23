# Floe Agent 1.8.76（397）

配对设备可以按会话共享工作区文件。两端都修改过的文件会保留冲突副本。运行中发出的引导在生效后显示为用户消息，长会话也能按原消息 ID 补回。 [双语发布说明](../notes/RELEASE_NOTES_1.8.76_BUILD_397.md)

## 构建与验证

冻结标签 `v1.8.76` 指向 `36339e50da14247e30b73d7b9da7c4286844f92f`。Xcode 27.2（27B52）的 iPhoneOS 27.2 arm64 Release 编译、发布预检和设备包校验均通过。签名包与本地构建的 App UUID 一致，19 份调试符号与包内二进制对应。签名 IPA 的 SHA-256 为 `ec499a10422b597453b4de757840d6a67fb5e8b22af5df234094c33f2bec8ba9`。 [签名与上传](https://github.com/JiangNanGenius/floe-agent/actions/runs/45162443749)

12 项 Swift 定向测试通过。真实 Iroh 本机连接覆盖了多段文件双向传输、冲突保留、重试和撤回授权。引导消息用 SQLite 分页样例和编译后的时间线验证，原请求已翻出当前页时，引导仍出现在两段回复之间。整包 iPad 界面和 iPad 真机跨端文件同步待验收。

## 跨端联调

Mac 实际 App 通过 12 项工作区用例，包括私有和项目目录双向同步、保留未保存的编辑、项目改绑后重新授权、冲突副本复用及撤回。对应宿主源码为 `84ac46a93`，已合入主分支。

三星 Full 候选 `afaec3f5a` 与 Swift 测试端通过中继双向同步，验证了原生编辑器读回、两端版本保留、重复同步及撤回文件授权。三星 43 项定向测试通过。与候选一致的 Android 同步源码 `c61c072fb` 已合入主分支。纯局域网仍有 Iroh 握手超时。

## TestFlight

- **内部 Floe QA**。Apple 独立回读确认构建 `VALID`、未过期，内部状态为 `IN_BETA_TESTING`，可安装。
- **公开 `publictest1`**。2026-11-23 22:39（悉尼时间）提交同一构建。Apple 独立回读为 `WAITING_FOR_BETA_REVIEW`，中英文测试说明已核对，审核通过后自动开放。 [公开测试入口](https://testflight.apple.com/join/nz6qeT2J)
