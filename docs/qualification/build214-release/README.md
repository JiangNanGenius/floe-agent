# Build 214 internal TestFlight delivery

Verified at **2026-09-20T21:32:34Z**: Apple **VALID**, unexpired, exactly the
existing private **Floe QA** group, **IN_BETA_TESTING**. Build 214 is available
for internal TestFlight installation. Physical-device acceptance belongs to
the user.

[Beta notes saved and read back](https://github.com/JiangNanGenius/floe-agent/actions/runs/35538948478)
for en-US and zh-Hans; [final availability verification](https://github.com/JiangNanGenius/floe-agent/actions/runs/35539017985).
Apple build ID: `0668a796-1936-4316-a727-4ff8ef5da78a`.
Group ID: `c09d3f5c-f5b3-485f-9ddb-98c61fa80ad1`.

- App: org.floeagent.ios, 1.7.0 (214), immutable tag `v1.7.0-beta.71`.
- App source: `33759e44fb574be9414012cedfbe7d776f9ce690`.
- Toolchain: Xcode 26.6 (17F113), iOS minimum 26.0.
- [App build and saved artifacts](https://github.com/JiangNanGenius/floe-agent/actions/runs/35536077150).
  Full App build passed; the later Apple validation failed on an embedded
  SDK link stub. This overall failed run is retained as original evidence.
- [Packaging-only recovery and accepted upload](https://github.com/JiangNanGenius/floe-agent/actions/runs/35537856984),
  policy commit `c4dddb79`. Reused the exact saved IPA and matching private
  symbols; did not rebuild the App. Removed only `Frameworks/libc++.tbd` after
  comparing its bytes with the accepted SDK, then re-signed and validated.
- Apple validation: 2026-09-20T21:16:33Z, no errors.
- Apple upload: 2026-09-20T21:19:46Z, no errors.
- Delivery UUID: `0668a796-1936-4316-a727-4ff8ef5da78a`.

## Retained recovery evidence

| Item | Artifact ID | Artifact ZIP SHA256 |
| --- | --- | --- |
| Original unsigned IPA | 10613153845 | 288072fc2d9f14a86ef1e3e1c31a620c7e40c1f57f616122d19aa8001b864281 |
| Matching private symbols | 10612752893 | e3164fa3fd9c77a46e52fefbbf452d11c851be92dc4e6e5a639ff3037cc8e81b |
| Signed TestFlight IPA and receipt | 10613800977 | dc10a98129e62cfc943730d61804a152f775c9fd487fd55ba4ef948126dcbb30 |
| Reuse verification | 10613810896 | 3baa90f2c3882fadb67043b42706fbf56c2d51b1f2832c5df7377f76d0cef44e |

Original unsigned IPA SHA256:
`4e22ed298fe99555c5585a4f0c9984b85668cadb287a381c7030780b94d2dcd4`.
App/dSYM UUID: `2E0DCB8A-6956-31DC-87EA-AFFA061551A1`.
The signed distribution differs by the recorded SDK-stub removal and signing;
the original unsigned IPA is preserved, not silently overwritten.

## Scope and limits

[TinyEMU component](https://github.com/JiangNanGenius/floe-agent/releases/tag/floe-linux-guest-20260921.1)
provides protocol 3, verified predecessor origins and corresponding-source
materials. Actual guest boot passed 43 focused checks; existing-disk upgrade
harness passed 17 checks. Native Python/Node payloads are absent from the
actual App and signed IPA; their source/recipes remain archived.

[Full repair ledger](../../FLOE_PHASE2_2026_09_21.md) covers concurrent command
and PTY execution, cancellation/recovery, environment/workspace ownership,
services, Office/PDF layout and recovery, Git, local-model tool/compaction,
cross-task retrieval, Notes tools/grants and native mindmap controls/dragging.
Git and local-model crash changes remain targeted mitigations until device
confirmation. XML/font metadata checks do not prove Office rendering.

Only focused checks and the real cloud App build were performed. Full UI and
package regression matrices were skipped at the user's request. Old-disk
upgrade, real SSH/SCP, performance, drag feel and crash resolution are for the
user's iPad acceptance. No production App Store, public App IPA, Feather
publication or main merge was performed.
