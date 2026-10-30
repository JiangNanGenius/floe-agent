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
  index.json               signed catalog / 签名索引
  index.sig                Actions-produced Ed25519 envelope / Actions 签名
  sources/<kind>/<id>/     content.json plus payload files / 源包
  packages/<id>/<version>/<id>.zip
  test_build.py            offline unit tests / 离线单元测试
```

`<kind>` is one of `prompts`, `providers`, `models`, `help`, `templates`.

### Provider model catalog / 模型目录

`providers/curated-overrides.json` records reviewed official plan and media facts
separately from the pinned models.dev baseline. The importer merges these declarations
deterministically; the bundled, canonical and content-package catalogs must agree.
`--check-offline` checks their local consistency and explicitly does not verify the
upstream network snapshot.

`floe.providers.compatibility` 1.1.2 requires App 1.7.64 and is a staged content
candidate. Its source and archive are checked independently of the existing signed
feed; publishing a new App does not replace the old feed's signature. The App bundles
the same reviewed model catalog, so these entries do not require a separate download.

`providers/curated-overrides.json` 单独记录经核对的官方套餐及媒体模型资料，
与固定的 models.dev 基线按确定规则合并；内置、规范目录和内容包正文保持一致。
`--check-offline` 只检查本地一致性，不代替上游原始快照校验。
兼容目录 1.1.2 的最低 App 版本为 1.7.64，目前是候选内容包；源文件与归档独立校验，
已发布目录的签名仍保留。App 内置相同模型目录，使用这些条目不需要另行下载。

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
rejected. Prompt packages may replace only the compiled allowlist of working-method,
communication and delivery sections. The runtime freezes the selected content
for each task. Permission, approval, tool protocol and security rules remain
compiled into the App and cannot be replaced by a content package.

`content.json` 至少包含 `schemaVersion`、`id`、`version`，并携带
`minimumAppVersion`、`releaseNotes` 等上述字段。源目录下的全部文件（含
`content.json`）以相对路径写入归档根目录，时间戳固定为 1980-01-01、权限固定为
`0644`，条目排序。拒绝符号链接、点开头或越界路径。提示词包只可替换代码白名单中的工作方法、
沟通和交付段落；运行时为每个任务冻结选定内容。权限、审批、工具协议和安全规则
仍由 App 代码固定，内容包不可替换。

### Search provider catalog / 搜索服务目录

`sources/providers/floe.search.providers/` is the search-provider catalog
package: `content.json` is the signed envelope and `SearchProviderCatalog.json`
is the payload the app validates. The signed feed still publishes 1.0.0 with
`minimumAppVersion` `1.7.47`; the staged 1.1.0 candidate adds DeepSeek's
compiled adapter kind and therefore requires App `1.7.65` (`1.7.64` fails
closed and drops that entry). The candidate is not signed or published yet.
Entries describe **existing compiled adapters only** —
preset id, adapter kind, bilingual name/blurb, documented default endpoint,
required credential field keys and option defaults. The package carries no
scripts, no credential values, no enablement flags and no new runtime
protocol; an adapter kind the app does not compile is dropped fail-closed and
needs an app update. The app installs it through the same signed transaction
as every other content kind and keeps its previously active catalog on any
signature/schema/minimum-version failure.

`sources/providers/floe.search.providers/` 为搜索服务目录包：`content.json`
是签名信封，`SearchProviderCatalog.json` 是 App 校验的目录正文。当前签名目录仍发布
1.0.0（`minimumAppVersion` 为 `1.7.47`）；暂存的 1.1.0 候选新增 DeepSeek 已编译
适配器类型，因此要求 App `1.7.65`（`1.7.64` 会安全失败并丢弃该条目）。候选包尚未
签名或发布。条目只描述**已编译的现有
适配器**：预设 ID、适配器类型、中英文名称与简介、官方默认端点、必填凭据字段与
选项默认值。包内无脚本、无凭据值、无启用开关、不引入新的运行时协议；App 未编译的
适配器类型会被安全丢弃并需升级 App。安装与其它内容类型使用同一签名事务，任何签名、
结构或最低版本失败都保留原有目录。

The search catalog package 1.0.0 remains signed by the official trust root in
the active feed. The 1.1.0 candidate (DeepSeek search adapter, minimum App
1.7.65) is staged only: its source and deterministic archive are checked, but
`index.json`/`index.sig` are unchanged, so it is not live. Tests verify the
published 1.0.0 bytes and pinned signature, both minimum App versions, package
hashes and the staged candidate archive. New candidates can be checked before
signing without replacing the active signed feed.

搜索目录包 1.0.0 仍由官方信任根签名并在当前目录中生效。1.1.0 候选（DeepSeek 搜索
适配器，最低 App 1.7.65）仅处于暂存状态：测试校验其源码与确定性归档，但
`index.json`/`index.sig` 未改动，因此尚未上线。测试同时核对已发布 1.0.0 的字节与
固定签名、两个最低 App 版本、包摘要以及暂存候选归档。新候选可在签名前验证，
不会替换当前有效的签名目录。

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

The official index and packages are signed through the existing hub workflow.
After editing sources, run the publisher again before release; `--check` must
pass for the exact committed bytes. Do not fabricate a signature or commit a
private signing key. The first content publication was verified in Actions run
[37877603979](https://github.com/JiangNanGenius/floe-agent/actions/runs/37877603979).

正式索引与包通过现有内容中心工作流签名。修改源内容后，发布前需要重新运行签名，
并对确切提交字节执行 `--check`。禁止伪造签名或提交签名私钥。
首轮内容发布已由上述 Actions 运行完成签名与校验；App 实际更新仍需独立验收。
