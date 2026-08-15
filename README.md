# Floe Agent

**Your models. Your files. Your machines.**

Floe Agent is a free, open-source, native AI agent workspace for iPhone and iPad. It is being built for people who want to bring their own model providers, work with documents and images, and supervise explicitly authorized SSH or VNC sessions without routing those connections through a Floe-operated service.

> [!IMPORTANT]
> Floe Agent is pre-release software. There is no supported public binary yet, and development builds must not be trusted with production credentials or production machines.

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
- Work with Files documents, images, SSH terminals, jump hosts, and VNC sessions.
- Require explicit, scoped approval for consequential actions and independently stop high-confidence catastrophic commands.
- Be honest about iOS background suspension, disconnected sessions, and incomplete work.

Floe Agent does not provide a hosted model proxy, Floe account, remote relay, model marketplace, advertising SDK, or arbitrary on-device execution of model-generated code.

## Repository status

The default branch currently contains the stable project documentation and community entry points. The active Alpha implementation remains on a review branch while its remaining production tool-runner gap is closed.

| Area | Status |
| --- | --- |
| Product, architecture, and security baseline | Documented |
| Swift package and native iPhone/iPad app | Implemented on the Alpha branch |
| Automated macOS/Linux and simulator checks | Passing on draft PR #4 |
| Public TestFlight or App Store release | Not available |
| Production-readiness | Not claimed |

This separation is intentional: a green build is useful evidence, but it is not the same as a supported release.

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

Floe Agent 是一款面向 iPhone 和 iPad 的开源原生 AI Agent 工作空间，目标是让用户自行连接模型、文件及已授权的电脑，并对重要操作进行明确审批和审计。项目目前仍处于预发布 Alpha 阶段，尚无可供日常生产使用的公开版本。请从上方“Start here”中的产品说明、开发计划和 Alpha 分支开始了解项目。
