# Device storage warning — 2026-11-06

Adds a non-blocking device-volume warning separately from the existing Floe storage census. Unknown capacity is never reported as zero. Below 1 GiB is low; below 256 MiB is critical. Dismissal survives repeated checks at the same severity, and a more serious state or a later recovery/new shortage re-arms the notice. No user data is deleted.

The ordinary root checks at launch/foreground and once per minute while active. Typed Cocoa out-of-space, POSIX ENOSPC/quota and SQLite FULL failures can raise a notice immediately. Notification payloads contain no SQL, file paths or user content. Database and atomic-file callers retain their original error and rollback/commit behavior. Startup failures identify storage exhaustion; an emergency in-memory launch asks the user to free space and reopen rather than pretending it can reload the durable graph.

English and Simplified Chinese include available bytes, recovery guidance and the existing Floe storage-management entry. Linux image space errors reuse that product wording. Existing resource checks remain in place; no second downloader or automatic cleanup was added.

## Qualification

- Actual Xcode 27.1 / Swift 6 App, module and hosted-test object compilation passed.
- 7 behavior tests plus 1 existing-iPad-Simulator UI test passed, with 0 failures and 0 skips.
- A tiny isolated in-memory SQLite page quota produces real SQLITE_FULL, verifies rollback, then removes the quota and verifies a successful retry. Staged-file failure preserves the previous destination and removes the failed stage.
- The real root UI displays a synthetic 192 MiB reading; the workbench remains accessible, help opens, dismissal restores the ordinary layout. Three screenshots are retained privately; the shared Simulator's existing data was preserved and the device was shut down.
- The user's iPad was not filled. This is not a reproduction of the friend's device or proof that iPadOS can launch an app when the OS itself refuses to start it.

Original local build/entrypoint failures remain recorded: a stale static FloeCore module shadowed the newly compiled framework, and two test-command membership/argument preconditions refused before tests ran. The obsolete module was isolated; no production assertion, data or release gate was weakened. Xcode's optional post-test Simulator diagnostic collection warned about its inherited xcrun path; test execution and explicit Simulator shutdown succeeded.

This source change is for the next TestFlight candidate. Build 317 remains immutable; the existing Build 315 formal App Store review and automatic-release choice are unchanged.
