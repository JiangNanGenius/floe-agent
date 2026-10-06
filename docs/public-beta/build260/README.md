# Build 260 external TestFlight review

Candidate `1.7.19 (260)`, immutable release tag `v1.7.19`. Reuses the existing `publictest1` group. Submission and availability must be confirmed from App Store Connect after upload.

[What to Test](whats-new.json), [Beta App Description](beta-description.json), and [review notes](review-notes.en-US.md) are prepared for this build. Physical iPad acceptance remains pending.

## Status — 2026-10-06 08:40 UTC

Apple processing is VALID and internal Floe QA availability is confirmed. External submission run [37436589061](https://github.com/JiangNanGenius/floe-agent/actions/runs/37436589061) stopped at the review-notes PATCH (HTTP 403), before group attachment and review submission. Browser fallback reached the review information page but its login session expired before saving. Build 260 is **not yet submitted or approved for external testing**. Resume with the prepared notes above, verify readback, then submit to the existing group.

Apple 处理通过，内部 Floe QA 已可用；外部送审被审核备注更新权限错误阻挡，网页会话也已过期。恢复登录并保存上述备注后继续送审；尚未提交或批准。

## Update — 2026-10-06 10:20 UTC

Login restored. Review notes were saved and verified. API group attachment also returned 403, so submission was completed through App Store Connect. Build 260 is now attached to publictest1 and **waiting for review**, not yet approved. Independent readback: [37449091089](https://github.com/JiangNanGenius/floe-agent/actions/runs/37449091089).

已通过网页完成 publictest1 关联与送审，当前正在等待审核；内部测试可用，外部尚未批准。上述登录阻碍已解除。
