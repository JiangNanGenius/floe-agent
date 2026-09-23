# Floe GitHub → Gitee 发行版镜像（refs 与资产）/ GitHub → Gitee release mirror (refs and assets)

GitHub Releases 是承担信任的唯一主源；Gitee 只是可选的**中国大陆下载镜像**。本页记录两条互相独立、分别可见的门禁、镜像工具的真实行为与限制，以及哪些消费方可以使用分片 URL。

GitHub Releases is the single trust-bearing primary; Gitee is only an optional **China download mirror**. This page describes the two separately visible gates, the real behavior and limits of the mirror tool, and which consumers may use shard URLs.

## 两条独立门禁 / Two separate gates

| 门禁 | 位置 | 覆盖范围 | 验证方式 |
| --- | --- | --- | --- |
| refs 门禁 | `.github/workflows/gitee-mirror.yml` 的 `mirror` 作业 | `main`、`v*`、`floe-linux-guest-*` 标签的单向推送 | 推送后比对 Gitee `main` 的 commit SHA 与 GitHub `main`；标签从不强制移动 |
| 发行版门禁 | 同一工作流的 `release-assets` 作业 + `FloeAgent/scripts/sync_release_to_gitee.py` | 一个已发布 Release 的元数据与全部资产 | 每个文件按大小与 SHA-256 校验；生成并回读 `GITEE-MIRROR-MANIFEST.json` |

refs 同步成功**不**代表资产已同步；两者分别报告，不能互相替代。

A successful refs sync does **not** prove asset sync; the two gates are reported separately and never substitute for each other.

## 什么会被镜像 / What is mirrored

- Release 元数据：`name`、`body`（追加镜像说明与 GitHub 主源链接）、`prerelease` 标志、`target_commitish` = GitHub 标签解析出的 commit SHA。
- 每个资产逐字节复制。GitHub API 现在为资产提供 `sha256:` 摘要；工具在流式下载时同时计算 SHA-256，任何不一致都会在**上传之前**失败关闭（`--include-assets` 之外的资产不会被替换）。
- 生成 `GITEE-MIRROR-MANIFEST.json`（schema `floe-gitee-release-mirror/v1`）：每个资产的名称、大小、SHA-256 与对应的 Gitee 附件名（含分片），并在上传后读回校验。

- Release metadata: `name`, `body` (with a mirror notice and the GitHub primary link), `prerelease`, `target_commitish` = the commit SHA the GitHub tag resolves to.
- Every asset is copied byte-for-byte. The GitHub API reports a `sha256:` digest per asset; the tool hashes the stream itself and fails closed **before upload** on any mismatch.
- `GITEE-MIRROR-MANIFEST.json` (schema `floe-gitee-release-mirror/v1`) pins every asset's name, size, SHA-256 and the Gitee attachment names, and is read back after upload.

## 直接下载与分片重建 / Direct downloads vs shard reconstruction

**≤ 分片阈值（默认 64 MiB）的资产**以原名镜像，可直接下载：

```
https://gitee.com/JiangNanGenius/floe-agent/releases/download/<tag>/<asset-name>
```

**超过阈值的资产**以固定分片发布，没有可直接安装的 Gitee 单文件 URL：

```
<asset-name>.part-00.bin ... <asset-name>.part-NN.bin
<asset-name>.parts.json        # schema floe-release-shard-manifest/v1
```

`*.parts.json` 固定：源仓库/标签/资产 URL、整文件大小与 SHA-256、每个分片的序号/名称/字节数/SHA-256。重建后的字节与 GitHub 完全相同：

```bash
cat Floe-Agent-1.7.0-build225-unsigned.ipa.part-*.bin > Floe-Agent-1.7.0-build225-unsigned.ipa
shasum -a 256 Floe-Agent-1.7.0-build225-unsigned.ipa   # 必须等于 parts.json 的 sha256（也等于 GitHub 资产摘要）
```

消费方规则：

- **Feather / AltStore / 任何直接安装路径不得使用分片 URL**：它们没有分片组装与整包摘要校验，分片 URL 不是 IPA，也不能当作 IPA 宣传或投递。
- 只有实现了「逐片大小 + SHA-256 校验 + 重组后整包摘要校验」的消费方才可以使用分片：目前是 App 内 Linux 客户机镜像回退（`floe-image-shard-manifest/v1`，见 [Linux 客户机镜像](FLOE_LINUX_GUEST_IMAGE_BUILD.md#distribution-mirror-gitee-sharded)）。
- GitHub 主源优先级不变：App 的 Linux 镜像下载先访问 GitHub，只有主源出现有界可用性失败才回退 Gitee；4xx、无效响应、取消一律 fail closed。

**Assets at or below the shard threshold (64 MiB by default)** are mirrored verbatim and are directly downloadable at the URL above. **Assets above it** are published as the shard set plus a manifest; there is **no direct installable single-file IPA URL on Gitee**. Feather/AltStore and any direct install path must not consume shard URLs — they do not verify or reassemble them. Only consumers with verified assembly (per-piece size + SHA-256 and a whole-file digest check before use) may read the shards; today that is the App's Linux guest image fallback (`floe-image-shard-manifest/v1`). GitHub stays the trust-bearing primary.

## 幂等、续传与失败语义 / Idempotence, resume and truthful failure

- 已存在且通过大小 + SHA-256 校验的附件不会重复上传；重名重复项会被去重，只保留已验证的一份。
- 上传或校验失败的资产记录为 `failed` 并以退出码 3 结束；已上传的其余分片保留，下一次运行按清单/摘要续传，不会重传已验证部分。
- `--dry-run` 只读；`--time-budget-minutes` 在预算耗尽时把剩余资产标记为 `deferred` 并同样以 3 退出（不伪装成功）。
- 校验模式：`--verify hash`（默认，下载回读比对摘要）、`size`（只比大小，明确记录为 size-only）、`none`。
- 令牌只经 `GITEE_TOKEN` → 0600 临时文件 → `GITEE_TOKEN_FILE` 环境变量传递；argv、URL、日志、汇总与提交中只出现变量名。

## 实际测量限制（2026-09-23，GitHub-hosted `ubuntu-latest` → gitee.com）/ Measured limits

| 方向 | 实测 | 说明 |
| --- | --- | --- |
| GitHub 资产下载（range 206） | 64 MiB / 1.55 s ≈ **43.3 MB/s** | 712 MiB IPA 整包下载约 19 s |
| GitHub Actions → Gitee `attach_files` 上传 | 16 MiB curl 探针：240 s 超时仅发出 6.75 MiB ≈ **29 KB/s**（HTTP 100，仍在等待响应） | 单连接上传 712 MiB 理论上需约 7 小时；`--upload-workers` 并行分片可缓解 |
| **Gitee 仓库附件配额** | 实测 400：`{"message":"验证失败：文件大小已超出仓库附件配额：1 GB"}`（上传体收完后才拒绝） | 配额为**仓库级 1 GiB**，不是单文件 100 MB；当前仓库已用 1,043,397,060 B（见下节） |
| 单附件/分片大小 | 既有 Linux 镜像以 64 MiB 分片成功发布；仓库文档记录 100 MB 说法 | 工具默认 `--shard-mib 64`，并设 `--gitee-attachment-quota-mib`（默认 1024）预检 |

具体云端镜像结果与链接见本页末尾的状态小节。

## 为什么 712 MiB 的 App IPA 不能托管在 Gitee（实测）/ Why the 712 MiB IPA is not hosted on Gitee

2026-09-23 云端实测（run [35836567963](https://github.com/JiangNanGenius/floe-agent/actions/runs/35836567963)）：

- 4 个并行连接各上传 64 MiB 分片，每个分片约 2,300–3,000 s 完成（约 28 KB/s/连接，聚合约 0.1 MB/s）。
- 分片上传体被接收后 Gitee 一律返回 HTTP 400：`验证失败：文件大小已超出仓库附件配额：1 GB`。
- 只读求和：镜像仓库当前附件总量 = 1,043,384,668 B（`floe-linux-guest-20260922.2` 发行版，其中 7 个分片各有 2 份重复，重复占 469,762,048 B）+ 12,392 B（本发行版）= 1,043,397,060 B ≈ 0.97 GiB。
- 再加一个 64 MiB 分片 = 1,110,505,924 B > 1,073,741,824 B（1 GiB），因此任何新附件都会因仓库配额被拒；712 MiB 的 IPA 无论是否分片都无法放入。
- 即使删掉重复分片（可回收约 448 MiB），已用约 547 MiB，剩余约 477 MiB，仍小于 712 MiB。

结论与安全回退：

1. **App IPA 的 Gitee 托管当前不可行**，这不是同步工具的缺陷；GitHub 主源是唯一可安装来源。
2. 可直接下载的小资产（元数据、校验文件等，单个远小于配额）仍镜像到 Gitee；`GITEE-MIRROR-MANIFEST.json` 的每个资产带 `state` 与 `complete`，未托管/未校验的资产明确为 `complete: false`。
3. **不得**把分片 URL 当作 IPA 投递给 Feather/AltStore 或运行时回退；也不得把它描述为 Gitee 托管的 IPA。
4. 如需中国大陆托管安装包：需要更大附件配额的 Gitee 账号/仓库（用 `--gitee-attachment-quota-mib` 抬高预检），或由支持「逐片校验 + 重组后整包摘要校验」的消费方处理分片；当前 App IPA 安装路径没有这种消费方。
5. 工具在上传前做配额预检（可用 `--no-quota-check` 关闭），配额不足的资产会立即以 `failed` 报告原因，不再浪费数十分钟上传后才收到 400。

## 自动化触发 / Automation

`release-assets` 作业在以下事件运行：

- `release`（`published` / `released` / `edited`）——人工或 PAT 发布的 Release；
- `repository_dispatch`，类型 `gitee-release-sync`，payload `tag`；
- `workflow_run`（App 发布、`linux-guest-distribute`、`linux-guest-runner-update`、`component-image-ci` 完成时，尽力而为）；
- 每周 `schedule` 对最新已发布 Release 做一次幂等对账；
- `workflow_dispatch`（可指定 `release_tag`、`dry_run`、`include_assets`、`shard_mib`、`verify`、`upload_workers`、`time_budget_minutes` 等）。

用仓库 `GITHUB_TOKEN` 创建的 Release **不会**触发新的 `release` 工作流运行（`workflow_dispatch` 与 `repository_dispatch` 是文档化的例外），因此发布流程或维护者可显式通知：

```bash
gh api repos/JiangNanGenius/floe-agent/dispatches \
  -f event_type=gitee-release-sync -f client_payload[tag]=v1.7.0-beta.82
```

手动镜像一个已发布但尚未同步的 Release：

```bash
gh workflow run gitee-mirror.yml --ref main \
  -f mirror_refs=false -f release_tag=<tag>
```

## 剩余的中国大陆加速集成 / Remaining China acceleration integration

1. **仓库附件配额（当前主要阻塞）**：镜像仓库 1 GiB 附件配额已用 995.1 MiB（其中约 448 MiB 是 `floe-linux-guest-20260922.2` 发行版的重复分片）。在此之前需要：删除重复分片回收空间、或改用配额更大的 Gitee 账号/仓库；即使回收重复，712 MiB IPA 仍放不下。
2. **App IPA（> 64 MiB）没有可直接安装的 Gitee URL**：Gitee 只能托管分片，而当前配额连分片也放不下。中国大陆用户要获得加速安装，需要一个「下载分片 → 校验 → 重组 → 再安装」的消费方；Feather/AltStore 均不支持，因此当前 App 安装路径仍以 GitHub 为主源。
3. **上传带宽**：GitHub-hosted runner 到 Gitee 的上传实测约 29 KB/s（单连接，4 连接聚合约 0.1 MB/s）；从中国大陆网络发起上传会快得多。云端 `--upload-workers` 已实现。
4. Linux 客户机镜像的 Gitee 回退已由 App 实现并验证（`shard-manifest.json` v1）；新的组件发行版仍需把镜像 URL 固定进 App 目录（`LinuxGuestImageStore` 的 catalog），这是版本发布流程的一部分，不是本工作流自动完成的。
5. 每个新 Release 的镜像结果（`gitee-release-mirror-<tag>-<run_id>` 工件）应在发布记录中引用；refs 门禁与资产门禁分别记录。

## 状态 / Status（2026-09-23 实测）

载体：分支 `codex/gitee-release-asset-mirror`，最终修订 `5a502af9`；成功运行 [35844170219](https://github.com/JiangNanGenius/floe-agent/actions/runs/35844170219)（首次发布清单）与 [35844874266](https://github.com/JiangNanGenius/floe-agent/actions/runs/35844874266)（幂等复核：`verified=6 uploaded=0 skipped=6 failed=0`，清单字节一致被跳过；仅 `prerelease` 元数据修正为与 GitHub 一致）。

- Gitee Release [v1.7.0-beta.82](https://gitee.com/JiangNanGenius/floe-agent/releases/tag/v1.7.0-beta.82)（id 1162007）：名称与 GitHub 一致，`prerelease=true`，`target_commitish=fe0852b4…`（GitHub 标签 SHA），正文附双语镜像说明（含「分片不是可安装包」警告）。
- 6 个可直下资产：`state=verified`、`complete=true`，每个计划文件名只对应一个已验证附件 id，逐文件 SHA-256 与 GitHub 摘要一致；URL 形如 `https://gitee.com/JiangNanGenius/floe-agent/releases/download/v1.7.0-beta.82/<name>`。
- 712 MiB 未签名 IPA：`state=not-selected`、`complete=false`，未托管（仓库附件配额 1 GiB，已用 995.1 MiB，剩余 28.9 MiB）。安装仍以 GitHub 主源为准；分片能力由 mock/契约测试（26 项）与真实上传/配额探测覆盖，但本仓库配额下无法完成托管。
- `GITEE-MIRROR-MANIFEST.json` 的顶层 `complete=false`，逐资产 `state`/`giteeFiles`（名称、字节、摘要、唯一附件 id、校验级别）构成可审计的镜像状态；未选中的兄弟资产只能通过「先前已验证的附件 id 仍原样存在」继承 complete，不会被同名杂物提升为 complete。

The published manifest is the audit surface: per-asset `state`, unique verified `giteeFiles` (name, bytes, digests, attach id, verification level) and a top-level `complete`; an asset is never promoted to complete by the mere presence of a same-name attachment.
