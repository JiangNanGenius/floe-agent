# Prompt to send to WorkBuddy

Continue the Floe Agent project in `/Volumes/TECLAST/IOS AI AGENT` on branch `agent/alpha-daily` and implement the complete daily-usable Alpha iteration.

Before editing, read these files in full and treat them as binding:

- `PRODUCT.md`
- `DESIGN.md`
- `docs/ALPHA_DAILY_PLAN.md`
- `docs/workbuddy/ALPHA_GREEDY_EXECUTION_PLAN.md`
- `docs/workbuddy/REVIEW_HANDOFF.md`
- `docs/DEVELOPMENT_PLAN.md`
- `docs/FRAMEWORK_AUDIT_2026-08-13.md`
- `FloeAgent/docs/M0_VALIDATION_REPORT.md`
- `FloeAgent/DELIVERY.md`

Work greedily through the phases: keep moving to the next safe, valuable vertical slice while the branch is healthy. Do not stop after scaffolding or placeholders, and do not ask about ordinary implementation details already resolved by the product/design documents. Compile and test frequently, make small coherent commits, push meaningful checkpoints, and fix GitHub CI before stopping.

The target is a real native iPhone/iPad Alpha with production app environment and schema v3; provider configuration/model discovery; real streaming BYOK chat; persistent agent event thread and approvals; polished Home/Chat/Files/Hosts/More navigation; SSH PTY and VNC lifecycle; Files round-trip; local image editing and capability-aware remote image adapters; English/Simplified Chinese; accessibility and recovery states. Use the committed design references only for hierarchy and atmosphere. Do not clone Manus/Codex, embed those images, invent live data, or claim unsupported work is complete.

Safety and authority: preserve MPL-2.0 and user changes; never expose or commit secrets; API keys/passwords/private-key passphrases belong only in Keychain. Full-control mode is scoped and time-bounded, and the independent catastrophic gate must still intercept high-confidence broadly destructive commands. Do not weaken it to satisfy tests. Do not add accounts, analytics, hosted proxy, downloaded plugins or arbitrary on-device code execution.

Do not merge PRs, rewrite history, alter App Store regions, trigger Xcode Cloud/TestFlight, spend cloud build hours, or make legal/export decisions. Cloud distribution is reserved for Codex after independent review.

When implementation and validation are complete, create `docs/workbuddy/IMPLEMENTATION_REPORT.md` from the handoff template with commit SHAs, exact commands/results, simulator evidence, known gaps, and the highest-risk review entry points. Push the final branch, confirm the worktree is clean, then stop and clearly report that Codex can begin its independent audit.
