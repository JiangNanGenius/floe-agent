# Agent UI lifecycle regression design

The M00 Agent UI is a UI-only process. These checks do not establish that a
future Agent run is safe to terminate. Add `AgentUIComponentController.swift`
and the eventual test implementation to a dedicated macOS test target, or build
a small temporary test host; the existing service-test target does not compile
this controller. Use a task-owned disposable fixture application and controllable
NSWorkspace launcher/process seams. Never attach to an existing user process.

1. Hold the first open completion. Call launch twice; verify exactly one open
   is issued. Deliver its result and verify only that PID becomes the owner.
2. Hold open, request close, then complete open. Verify the late-created owned
   instance receives graceful termination, no second launch is admitted until
   it settles, and state becomes idle only after confirmed exit.
3. Hold an asynchronous close open. Call launch and close again; verify no new
   instance or duplicate termination request is made while closing.
4. Have the owned process refuse graceful termination. Verify no force kill,
   reference retained and failed state reported. Observe later termination and
   verify state becomes idle. Verify user-owned fixtures outside the controller
   receive no process signal.
5. Interleave smoke probe with launch and close. Verify admission is exclusive,
   a close during open/inspection is honored, no other application is adopted,
   and an unconfirmed stop is reported as failure rather than idle.
6. Exercise application shutdown while open is still pending; show that the
   close intent is recorded. The app can exit before the callback arrives, so
   this does not prove the child is reclaimed. Production Agent lifecycle must
   fence and await in-flight launches before permitting host termination.
7. Launch returns a process that has already exited: verify it is not shown as
   running. Simulate a stale termination notification and verify it cannot erase
   a newer owned process.
8. An open call returns an error or an unconfirmed outcome. Verify it is shown
   as unknown, Close cannot relabel it idle, and another open or probe is not
   admitted without a future explicit reconciliation mechanism.

Compilation, these tests and real AppKit behavior are not yet verified.
