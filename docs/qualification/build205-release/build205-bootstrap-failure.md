# Build 205 — stopped before App compilation

- Immutable source: `f2d3ae37ba321d47201798099d2c8a38de1d11ed`.
- Immutable tag: `v1.7.0-beta.62` (retained without movement).
- [Release run 35495093115](https://github.com/JiangNanGenius/floe-agent/actions/runs/35495093115).
- Accepted upload toolchain: Xcode 26.6 / 17F113.

The lean release source job passed. The App rebuild step stopped in dependency
bootstrap, before the App compiler: `bootstrap_office_host.py:43` raised
`ValueError: Native host must be rebuilt for its changed public or implementation source`.
The Office close lifecycle repair changed `FloeOfficeNative.h` and `.mm`, while
`engine.lock.json` still referenced the separately built host from run 35450834975.
Its source hashes correctly rejected the stale binary.

No App IPA or matching App symbols were produced. Signing, upload, Apple
processing and group availability were not reached. Build 205 was not uploaded.
The existing build 204 remains the last verified installable build at this point.

Recovery rebuilds the native host from the exact changed source in
[run 35495484711](https://github.com/JiangNanGenius/floe-agent/actions/runs/35495484711),
then records the verified archive, binary and manifest hashes in a new source
commit/build/tag. The failed tag is never changed. No consistency check is bypassed.
A new read-only preflight invokes the same source-pin check before expensive App
bootstrap.

本次失败是 Office 原生宿主的源码／二进制一致性检查，尚未到 App 编译、
签名和上传。修复方式是重建宿主、核对实际工件并更新依赖 pin，再使用新的
构建号与标签发布；不移动 beta.62，不修改校验规则来接受旧二进制。
