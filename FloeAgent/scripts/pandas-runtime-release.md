# Native pandas 3.0.5 / 原生 pandas 3.0.5

Build-time dependency only, not a Floe app release or runtime-download channel.
仅供 App 构建时使用，不是 Floe 应用版本，也不允许在设备运行时下载原生代码。

- CPython 3.13; arm64 iPhoneOS and iPhone Simulator; minimum iOS 17.
- pandas source SHA256 and the source-only Meson header-location patch are in
  `FloeAgent/scripts/build_pandas_ios.sh` and `prepare_pandas_ios.py` at the tagged commit.
- Built against NumPy 2.5.2.post1. BSD-3-Clause and upstream notices are included
  in the wheels. Python-dateutil, six and tzdata are separately pinned by the app.
- Native iOS smoke passed in [build 34123915397](https://github.com/JiangNanGenius/floe-agent/actions/runs/34123915397):
  CSV, filtering, groupby, merge, missing values, timezone and JSON round-trip.
- 原生 iOS 运算测试已通过；Floe App 内的导入、签名、真机离线验证仍是独立发布门。
  An upstream test pass does not replace the Floe app/signing/physical-device gates.

SHA256:

| Wheel | SHA256 |
|---|---|
| iphoneos | `99ac5c6c541a0e24b0b6637e9405e9ae682ea4b188316a090d643edd6bedd92d` |
| iphonesimulator | `d0a9dc857c9d9d38e78d305a3385f51dc04366daf15fda2f17a3a0927d55bd67` |

Assets are immutable. Corrections require a new runtime tag and new app pins.
发布产物不可覆盖；修订需要新运行库标签和新的 App 哈希锁定。
