# FloeDeviceLink

Floe 的跨设备连接层。macOS 15+ 与 iOS 26+ 共用本目录的 Swift Package，Android 9+ 使用 `FloeAndroid/core/devicelink` 的 Kotlin 模块。两端使用同版本 Iroh 1.2.0 绑定，通过端到端 QUIC 建链。地址由宿主配对交换，Iroh 尝试打洞直连，也可使用默认的公共中继。公共中继适用于开发和个人试用，有流量限制。 [Iroh 绑定](https://github.com/n0-computer/iroh-ffi/releases/tag/v1.2.0) · [公共中继政策](https://docs.iroh.computer/iroh-services/relays/public)

## 接入

1. 生成或从宿主凭据存储恢复 `FloeDeviceLinkIdentity`。私钥字节仅用于本机保存和恢复。配对时通过受信渠道交换 Endpoint ID 和连接地址。地址 JSON 包含 `endpointID`、`directAddresses` 和可选的 `relayURL`。
2. 调用 `FloeDeviceLink.bind`，传入宿主已批准的对端 ID。Android 额外传入应用 `Context`。应用可从 `address()` 读取当前连接提示，也可在启动阶段使用 `waitForRelayAddress()` 等待中继可用。
3. 拨号端调用 `connect(to:)`，监听端运行 `acceptNext()`。双方核对 QUIC 认证的 Endpoint ID 后才交给应用。宿主可以更新已授权的设备列表并关闭已撤销设备的连接，监听地址保持稳定。
4. `request`、`receiveRequest` 和 `respond` 使用独立 QUIC 双向流交换二进制数据。ALPN 为 `floe/device-link/1`，请求和响应各用 QUIC FIN 标识结束。每个方向的有效载荷为 1 字节至 1 MiB，每条请求可响应一次。`paths()` 返回实际直连或中继路径及字节计数。

取消正在等待的请求会关闭当前连接，宿主可重连并按业务命令 ID 查询回执。关闭端点会唤醒等待连接的监听器。

`FloeDeviceSync` 提供 Apple 平台共用的设备设置和会话历史传输。宿主用本机钥匙串持久保存设备私钥，并接入普通会话的读取与事务导入。两端核对指纹完成配对，各自选择对该设备共享的会话。接收端选择会话后拉取经过完整性校验的文本历史。相同消息重复导入是空操作，内容不同的同 ID 消息保留在各自设备。直连为默认方式，也可填写自用 HTTPS 中继或显式尝试公共测试中继。

### 会话历史增量协议

配对格式、ALPN 和 JSON 的 `version: 1` 沿用。支持增量的发送端在 `offers` 回应中增加 `historyPages: true`。缺少该能力时，接收端使用原 `prepare` / `chunk` 整档方式。增量开始后的传输失败从已提交游标续接。

- `preparePage` 接受 `taskID`、可选 `after` 和 `through`。游标为最多 160 个 UTF-8 字节的不透明字符串。首个请求省略 `through`，后续页回传首个响应的扫描上界。
- 回应包含 `size`、`digest`、`through`、`hasMore` 与可选 `nextCursor`。正文是原生文本历史 JSON，复用 `chunk` 的原始字节偏移和 384 KiB 分段，单页大小沿用 32 MiB 上限。成功入库后才提交游标。末尾有数据的页也给出游标。没有新增时保留传入的游标，初始空会话可省略。
- 发送端按会话的本地提交顺序分页，任务 ID 不随配对改变。源存储恢复或游标的锚点失效时返回 `cursorExpired`。接收端可在新一轮拉取开始时重读一次，依靠原消息 ID 去重。每次准备和分段读取都会核对仍在共享的会话。接收端在同一 SQLite 事务写入该页及按对端、会话保存的游标。

## 验证

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path FloeDeviceLink --scratch-path "<内置盘构建目录>"

FLOE_DEVICE_LINK_PUBLIC_RELAY_TEST=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path FloeDeviceLink --scratch-path "<内置盘构建目录>" \
  --filter FloeDeviceLinkPublicRelayTests

# 从仓库根目录进入 Bash 后运行
source FloeAndroid/scripts/env.sh
cd FloeAndroid
./gradlew :core:devicelink:assembleDebug :core:devicelink:assembleDebugAndroidTest
```

公网测试使用临时身份和合成数据。Swift 的公共中继测试可在一台 Mac 上运行，Android 真机或模拟器测试包含直连、身份检查、载荷边界与重连。跨平台用例通过本地测试通道交换身份及地址，使用 Iroh 公共中继完成 128 KiB 往返。测试进程限制了网关端口映射，Iroh 1.2.0 绑定暂无产品级关闭开关。

Android 模块显式使用 JNA 5.17.0 的 AAR 以支持 16 KiB 页设备。官方 Kotlin JAR 也包含桌面原生库，App 接入时需按发布目标 ABI 检查实际打包内容。 [JNA 变更记录](https://github.com/java-native-access/jna/blob/5.17.0/CHANGES.md)
