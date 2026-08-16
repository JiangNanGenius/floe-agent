# Floe Agent

**Your models. Your files. Your machines.**

Floe Agent is a free, open-source, native AI agent workspace for iPhone and iPad. It is being built for people who want to bring their own model providers, work with documents and images, and supervise explicitly authorized SSH or VNC sessions without routing those connections through a Floe-operated service.

> [!IMPORTANT]
> Floe Agent is pre-release software. GitHub prereleases may include a community **unsigned IPA**, but it must be inspected and signed by the user before sideloading. It is not an App Store package, cannot normally be installed directly, and must not be trusted with production credentials or production machines.

## Start here

| If you want to… | Go to… |
| --- | --- |
| Understand the product and its boundaries | [Product overview](PRODUCT.md) |
| See the engineering roadmap and release gates | [Development plan](docs/DEVELOPMENT_PLAN.md) |
| Review the interface direction | [Design direction](DESIGN.md) |
| Explore the current Alpha implementation | [`agent/alpha-daily`](https://github.com/JiangNanGenius/floe-agent/tree/agent/alpha-daily) and [draft PR #4](https://github.com/JiangNanGenius/floe-agent/pull/4) |
| Build or contribute | [Contributing guide](CONTRIBUTING.md) |
| Report a vulnerability | [Security policy](SECURITY.md) |
| Ask for help | [Support guide](SUPPORT.md) |

## What Floe Agent is designed to do

- Connect directly to OpenAI-compatible and Anthropic-compatible model APIs with user-supplied credentials.
- Keep model secrets in Keychain and non-secret configuration under user-controlled Apple services.
- Present agent work as inspectable threads with progress, approvals, errors, checkpoints, and evidence.
- Use one workbench for task overview, new tasks, workspaces, and conversation history, with durable Plan and Goal modes.
- Install validated declarative Skills, create local instruction Skills, and use a selected model to rewrite Finder candidates for iOS before deterministic review.
- Automate a user-visible WebKit browser through the allowlisted [Floe Browser Protocol](docs/FLOE_BROWSER_PROTOCOL.md): stable DOM references, lifecycle events, bounded waits, screenshots, coordinate/element actions, and explicit user takeover.
- Keep bounded, user-reviewable local memory and inject it as potentially stale context rather than authority.
- Work with Files documents, images, SSH terminals, jump hosts, and VNC sessions.
- Require explicit, scoped approval for consequential actions and independently stop high-confidence catastrophic commands.
- Be honest about iOS background suspension, disconnected sessions, and incomplete work.

Floe Agent does not provide a hosted model proxy, Floe account, remote relay, model marketplace, advertising SDK, or arbitrary on-device execution of model-generated code. Installed Skills are declarative workflow/knowledge packages, not native plugins; scripts remain visible source text and local execution is not registered in production.

## Repository status

The default branch currently contains the stable project documentation and community entry points. The active Alpha implementation remains on a review branch while its remaining production tool-runner gap is closed.

| Area | Status |
| --- | --- |
| Product, architecture, and security baseline | Documented |
| Swift package and native iPhone/iPad app | Implemented on the Alpha branch |
| Automated macOS/Linux and simulator checks | Passing on draft PR #4 |
| Community unsigned IPA | Automated for future SemVer-tagged GitHub prereleases; user signing required |
| Public TestFlight or App Store release | Not available |
| Production-readiness | Not claimed |

This separation is intentional: a green build is useful evidence, but it is not the same as a supported release.

## Unsigned IPA prereleases

The release workflow builds every future `vX.Y.Z` release tag for a generic arm64 iOS device with code signing disabled. After tests, secret scanning, dependency checks, SBOM generation, and archive validation pass, GitHub publishes a prerelease containing:

- `Floe-Agent-X.Y.Z-buildN-unsigned.ipa` and its SHA-256 checksum;
- an SPDX SBOM and third-party license inventory;
- a test summary, secret-scan report, and GitHub build-provenance attestation.

An unsigned IPA is source-adjacent build output for advanced testers. iOS will not normally install it as downloaded. Verify its checksum and provenance, review the source, then sign it with your own certificate through a compatible sideloading tool. Floe does not provide certificates, provisioning profiles, or a signing service.

## Try the development source

Requirements: macOS with a full Xcode installation supporting Swift 6.2 and the iOS 26 SDK.

```bash
git clone https://github.com/JiangNanGenius/floe-agent.git
cd floe-agent
git switch agent/alpha-daily
cd FloeAgent
scripts/local_build.sh
```

You can also run `swift build` and `swift test` from `FloeAgent/`. Some targets require the iOS SDK and therefore a full Xcode installation. Read the branch-local `FloeAgent/README.md` for implementation-specific notes and open gates.

## Project principles

1. Keep credentials, files, and machines under user control.
2. Make the current task, next decision, and supporting evidence legible.
3. Prefer recoverability and honest interruption over pretending work continued.
4. Make powerful access explicit, scoped, time-bounded, and stoppable.
5. Treat model output, remote content, and tool arguments as untrusted input.

## Contributing

The project is early and its interfaces are still moving. Before investing in a large change, read [CONTRIBUTING.md](CONTRIBUTING.md) and open an issue describing the user problem, intended scope, and security impact. Please do not post vulnerability details in public issues.

## License

Original Floe Agent code is licensed under the [Mozilla Public License 2.0](LICENSE). Third-party components retain their own licenses and notices.

## 简体中文

Floe Agent 是一款面向 iPhone 和 iPad 的开源原生 AI Agent 工作空间，目标是让用户自行连接模型、文件及已授权的电脑，并对重要操作进行明确审批和审计。项目目前仍处于预发布阶段；GitHub Release 可能提供面向高级测试者的未签名 IPA，但该文件不能直接安装，也不是 App Store 安装包。请先核验校验和与来源证明，再使用自己的证书签名和侧载，且不要用于生产凭据或生产主机。
