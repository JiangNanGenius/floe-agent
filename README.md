# Floe Agent

**Your models. Your files. Your machines.**

Floe Agent is a planned open-source, native AI agent workspace for iPhone and iPad. It is designed around bring-your-own API keys, direct connections to computers you own or are authorized to operate, and user-controlled approval policies.

The first public release is intended to combine:

- OpenAI Responses and Chat Completions compatible APIs
- Anthropic Messages compatible APIs
- Volcengine Ark and Alibaba Model Studio providers
- Office document editing powered by Collabora/LibreOffice
- Local and model-powered image editing
- SSH, SFTP, jump hosts, and recoverable terminal sessions
- VNC remote desktop and multimodal agent control
- Human approval, approval-model, and explicitly enabled full-control modes
- iCloud Keychain synchronization for model secrets
- CloudKit synchronization for non-secret model configuration
- iCloud Drive and Files integration for user documents

## Project status

Floe Agent is currently in the architecture and technical-validation phase. No production app or binary is available yet.

The implementation is deliberately gated on three early feasibility tests:

1. Building and embedding the Collabora/LibreOffice editor on the minimum supported devices.
2. Running stable SSH PTY and multi-hop jump-host sessions with strict host-key verification.
3. Rendering and controlling VNC sessions with acceptable performance on real iPhone and iPad hardware.

See the [complete development plan](docs/DEVELOPMENT_PLAN.md) for architecture, security policy, milestones, tests, and release constraints.

## Product baseline

- App name: **Floe Agent**
- App Store subtitle: **Private AI Agent Workspace**
- Minimum OS: iOS 26.0 and iPadOS 26.0
- Minimum performance: iPhone 15 Pro equivalent performance tier
- Distribution: free and open source; mainland China App Store excluded
- Backend: no Floe-operated account, model proxy, or inference service
- Telemetry: no advertising or third-party behavioral analytics SDKs

## Security

Floe Agent will be able to operate remote terminals and desktops. Treat all pre-release code as experimental and do not use it on production systems until a reviewed release is available.

Please read [SECURITY.md](SECURITY.md) before reporting a vulnerability.

## License

Original Floe Agent code is licensed under the [Mozilla Public License 2.0](LICENSE). Bundled components retain their own licenses and notices.
