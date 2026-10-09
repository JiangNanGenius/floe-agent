# content-hub

Signed, content-only packages for prompts, help, templates, provider compatibility
notes and model metadata. Nothing here is executed: packages are data that the
app's shared signed-content update core verifies before use. The builder is a
sibling of `skill-hub/build.py` and deliberately reuses its canonical JSON,
length-prefixed SHA-256 content digest, deterministic `ZIP_STORED` archives,
immutable published bytes and Ed25519 trust root (`official-2026-09`).

本目录提供提示词、帮助、模板、提供商兼容性说明与模型元数据的**纯内容**签名包。
所有包都只作为数据使用、绝不执行；App 的共享签名内容更新核心会先验证再使用。
构建脚本与 `skill-hub/build.py` 保持同一套约定：规范 JSON、带长度前缀的 SHA-256
内容摘要、确定性的 `ZIP_STORED` 归档、已发布字节不可变，以及同一 Ed25519 信任根
（`official-2026-09`）。

## Layout / 目录结构

```
content-hub/
  build.py                 builder, signer and verifier / 构建、签名与校验
  public-key.json          pinned trust root (same as skill-hub) / 固定信任根
  index.json               catalog (unsigned until the coordinator signs)
  index.sig                coordinator-produced Ed25519 envelope / 协调者签名
  sources/<kind>/<id>/     content.json plus payload files / 源包
  packages/<id>/<version>/<id>.zip
  test_build.py            offline unit tests / 离线单元测试
```

`<kind>` is one of `prompts`, `providers`, `models`, `help`, `templates`.

## Index schema / 索引结构

Canonical JSON (sorted keys, compact separators, UTF-8, `ensure_ascii=False`):

```json
{"schemaVersion":1,"publisher":"JiangNanGenius","generatedAt":"<ISO8601 UTC>","entries":[...]}
```

Each entry carries: `id`, `kind`, `version` (strict `X.Y.Z`), `schemaVersion`,
`minimumAppVersion` (strict `X.Y.Z`), `requiredCapabilities`, `dependencies`,
`path` (`content-hub/packages/<id>/<version>/<id>.zip`), `size`, `sha256`
(64 lowercase hex), `contentDigest` (64 hex), bilingual nonempty
`releaseNotes` (`zh-Hans`, `en`), `sourceRevision` (empty or 40 lowercase hex)
and `containsScripts`. `contentDigest` is SHA-256 over sorted (path, bytes)
pairs with 8-byte big-endian length prefixes for both, identical to skill-hub.

每个条目包含上述字段；`version` 与 `minimumAppVersion` 必须是严格的三段版本号，
`releaseNotes` 必须同时提供非空的中英文，`sha256`/`contentDigest` 为 64 位小写十六
进制。`contentDigest` 与 skill-hub 完全一致。

## Source packages / 源包

`sources/<kind>/<id>/content.json` must be a JSON object with at least
`{"schemaVersion":1,"id":"<id>","version":"X.Y.Z"}` plus domain fields. It also
provides `minimumAppVersion`, `releaseNotes`, and optionally `kind` (must match
the folder), `requiredCapabilities`, `dependencies`, `sourceRevision`,
`containsScripts`. All files under the source folder (including `content.json`)
are stored at archive root under their relative path with deterministic 1980
timestamps and `0644`, sorted. Dot-prefixed or unsafe paths and symlinks are
rejected. Prompts packages are descriptive metadata only; they must not claim to
be active runtime rules.

`content.json` 至少包含 `schemaVersion`、`id`、`version`，并携带
`minimumAppVersion`、`releaseNotes` 等上述字段。源目录下的全部文件（含
`content.json`）以相对路径写入归档根目录，时间戳固定为 1980-01-01、权限固定为
`0644`，条目排序。拒绝符号链接、点开头或越界路径。提示词包只是描述性元数据，
不得声称是生效中的运行时规则。

## Build / Check / Sign / 构建、校验、签名

```sh
python3 content-hub/build.py            # packages + unsigned index.json
python3 content-hub/build.py --check    # read-only, exit 1 on any mismatch
FLOE_CONTENT_HUB_SIGNING_KEY=<base64-raw-ed25519> python3 content-hub/build.py --sign
```

- `--sign` refreshes `generatedAt`, verifies the key matches the pinned
  `public-key.json`, then writes `index.json` and `index.sig`
  (`{"keyID","signature"}` base64). Unsigned builds preserve the existing
  `generatedAt`.
- `--check` verifies the signature with `public-key.json`, then every entry's
  `path`, `size`, `sha256` and `contentDigest` on disk. It never writes files
  and exits 1 on mismatch.
- Same `id` + `version` with different bytes is always refused; bump the version.

`--sign` 会刷新 `generatedAt`、校验私钥与固定公钥一致，然后写入 `index.json` 与
`index.sig`。普通构建保留已有 `generatedAt`。`--check` 只读校验签名与每个包的
路径、大小、`sha256`、`contentDigest`，不写文件，失败返回 1。同一 `id`+`version`
的字节变化一律拒绝，必须升版本号。

## Fixture / 本地端到端夹具

```sh
python3 content-hub/build.py --fixture Local/Private/content-update-fixtures/basic
python3 content-hub/build.py --check --fixture Local/Private/content-update-fixtures/basic
```

A fixture contains `index.json`, `index.sig`, `packages/...` and its own fresh
`public-key.json`; the freshly generated private key is written only inside the
fixture directory (`signing-key.b64`, mode `0600`). Fixture directories inside
the repository must live under the git-ignored `Local/`; paths outside the
repository (for example test temp directories) are allowed. `--check --fixture`
uses the fixture's own public key.

夹具包含上述文件，并在夹具目录内生成全新密钥对；私钥 `signing-key.b64`
（权限 `0600`）只存在于夹具目录。仓库内的夹具目录必须位于被 Git 忽略的
`Local/` 下；仓库外的临时目录允许使用。`--check --fixture` 使用夹具自带的公钥。

## Publish procedure / 发布流程

1. The existing Official Skill and Content Hubs workflow (mapping the existing
   `FLOE_SKILL_HUB_SIGNING_KEY` secret to the content builder)
   runs `--sign` on the exact release commit, then runs `--check`.
2. The commit containing `index.json`, `index.sig` and `packages/**` is an
   immutable revision; never move a tag or replace a published package.
3. The app resolves a commit, fetches `content-hub/index.json`,
   `content-hub/index.sig` and the package by `path`, and verifies all bytes.
   It never trusts a new key from the network; rotating the trust root requires
   an app release, exactly like skill-hub.

现有 Official Skill and Content Hubs 工作流（复用 Actions 密钥
`FLOE_SKILL_HUB_SIGNING_KEY`，映射给内容构建器）在确切的发布提交上运行
`--sign` 并随后执行 `--check`。包含 `index.json`、`index.sig` 与 `packages/**` 的
提交即为不可变版本，禁止移动标签或替换已发布包。App 按提交解析并验证全部字节，
绝不从网络信任新密钥；更换信任根必须随 App 版本发布，与 skill-hub 相同。

The committed `content-hub/index.json` is unsigned in the working tree because
the real signing key is an Actions secret; `content-hub/index.sig` must be
produced by the coordinator before publishing. No signature is fabricated with
the official key id.

由于真实签名密钥是 Actions 机密，工作树中的 `content-hub/index.json` 处于未签名
状态；发布前必须由协调者生成 `content-hub/index.sig`，不得用官方 keyID 伪造签名。
