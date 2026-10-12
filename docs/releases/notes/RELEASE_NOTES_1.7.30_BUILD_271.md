# Floe 1.7.30 (271) — Provider and Bluetooth hotfix

## 简体中文

- 服务商名称会自动整理粘贴产生的换行、制表符及无意义隐藏字符，保留中文、组合字符和 emoji；超长名称会显示实际长度，不再统一提示删除隐藏字符。
- 蓝牙仅在明确扫描或连接时初始化，避免启动期间触发授权。拒绝或受限授权返回可读错误；无效 GATT UUID 在进入系统蓝牙 API 前被拒绝。
- 保留既有配置和凭据。此轮为紧急修复，仅验证受影响路径；蓝牙真机授权与外设连接仍需设备验证，尚无用户现场崩溃栈证明唯一根因。

## English

- Provider names normalize pasted line breaks, tabs and incidental invisible formatting while preserving Chinese, combining characters and emoji. Oversized names report their actual UTF-8 size.
- Bluetooth initializes only for an explicit scan or connection. Denied/restricted authorization returns a readable error, and malformed GATT UUIDs are rejected before entering CoreBluetooth.
- Existing configurations and credentials are preserved. This emergency release qualifies the affected paths; physical-device authorization and accessory behavior still require device verification. No field crash trace is available to establish the sole cause of the reported crash.
