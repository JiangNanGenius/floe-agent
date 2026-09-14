# Floe Agent Feather source

This source is being added with the current feedback release. It is not live
until a qualified GitHub IPA has been published and `feather.json` is present
on `main`.

The stable URL will be:

`https://raw.githubusercontent.com/JiangNanGenius/floe-agent/main/feather.json`

In Feather, open **Sources**, add this URL and choose **Floe Agent**. Feather
downloads the unsigned developer IPA; use your own certificate and provisioning
profile to sign and install it. The source does not distribute certificates.
TestFlight remains a separate installation channel.

The feed uses Feather's [AltStore-compatible format](https://github.com/claration/Feather).
Its app identifier, version, build number, minimum OS and byte size come from
the actual IPA. Download URLs point to immutable GitHub release assets; the
feed includes the SHA-256 as additional metadata, without claiming that every
Feather version verifies that field. The release also supplies a checksum file.

The publisher verifies the downloaded checksum and GitHub provenance for the
exact release tag and source commit before changing the feed. It rejects draft
releases, signed distribution bundles, other app identifiers and version
rollback. The ten most recent published builds are retained. Publishing a new
GitHub app release refreshes the same source URL without rebuilding the app.

## 简体中文

本轮会提供可添加到 Feather 的 Floe Agent 软件源，当前仍待合格安装包正式上传到 GitHub 预发布页后启用。

在 Feather 的「软件源 / Sources」中添加上方地址，选择 Floe Agent 下载，再使用自己的证书和描述文件签名安装。这里提供的是开发者未签名 IPA，TestFlight 是独立渠道。

版本、构建号、最低系统和文件大小从实际安装包读取；发布前核对校验和及构建来源。以后更新沿用同一个源地址，保留最近十个已发布构建。
