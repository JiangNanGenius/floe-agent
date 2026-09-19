//
//  feedback_shell_bridge_host.mm
//  Floe Agent — Build 199 shell-gate repair harness.
//
//  Compiles the real FloeShellBridge.mm for the macOS host against a scripted
//  stub engine (fixtures/ios_system/ios_system.h) and verifies the safety
//  contract the Build 198 transcript motivated and the Build 199 repair ships:
//    * the process-wide run gate is released only by the owning worker's own
//      teardown after ios_system has returned. A cooperative worker stops
//      inside the bounded cancellation grace, so the next command starts
//      immediately; a worker that ignores cancellation is quarantined instead:
//      while it is still alive the next command reports Busy/not-started and
//      never enters the engine, and the gate reopens only once the old worker
//      is proven stopped;
//    * cancellation gets the same quarantine treatment as a timeout;
//    * a descendant/detached thread holding the output pipe open cannot block
//      finalization: captured stdout/stderr is preserved and the worker stops;
//    * large output is captured up to the cap and the run still terminates;
//    * closed pipes/descriptors are released so repeated commands work;
//    * the bounded readiness wait drains a banner and captures the final
//      output of an immediately-exiting command;
//    * descriptor ownership transfers with FloeShellClaimSessionDescriptors,
//      and FloeShellCloseSession never closes a pump-owned descriptor;
//    * claiming after a close returns NO so the caller cannot touch recycled
//      descriptor numbers;
//    * interactive input written to the session's stdin descriptor reaches the
//      running program and its output comes back on the session pipe.
//
//  This is a desktop host check of the bridge state machine, not an iOS or
//  ios_system qualification.
//
#import <Foundation/Foundation.h>

#include <chrono>
#include <thread>
#include <vector>

#import "../../FloeApp/Execution/FloeShellBridge.h"
#import "../../FloeApp/Execution/FloeShellBridge.mm"

#pragma mark - Scripted engine stubs

FILE *thread_stdin = NULL;
FILE *thread_stdout = NULL;
FILE *thread_stderr = NULL;
void *thread_context = NULL;
static std::atomic<bool> gReleaseBlocked{false};

void initializeEnvironment(void) {}
bool joinMainThread = false;
void ios_setenv(const char *, const char *, int) {}
NSArray<NSString *> *environmentAsArray(void) { return @[]; }
bool ios_setMiniRoot(NSString *) { return true; }
void ios_setDirectoryURL(NSURL *) {}
void ios_setStreams(FILE *, FILE *, FILE *) {}
void ios_switchSession(const char *) {}
void ios_setContext(const char *session) { thread_context = (void *)session; }
pid_t ios_fork(void) { return 0; }
void ios_releaseThreadId(pid_t) {}
void ios_storeThreadId(pthread_t) {}
int ios_getCommandStatus(void) { return 0; }
void ios_closeSession(const char *) {}
void ios_setWindowSize(int, int, const char *) {}
NSString *ios_getLogicalPWD(void *) { return @"/"; }
void replaceCommand(NSString *, NSString *, bool) {}
NSDictionary<NSString *, NSString *> *FloeTLSEnvironment(void) { return @{}; }

static void writeBytes(const char *bytes, size_t count) {
    if (!thread_stdout) { return; }
    fwrite(bytes, 1, count, thread_stdout);
    fflush(thread_stdout);
}

int ios_system(const char *command) {
    NSString *value = command ? [NSString stringWithUTF8String:command] : @"";
    if ([value hasPrefix:@"coop"]) {
        // Cooperative worker: observes the bridge cancellation flag on its own
        // execution thread and stops promptly, modelling dash (which polls
        // between commands) and the Floe replacement commands.
        while (!floe_shell_should_cancel()) { usleep(2000); }
        writeBytes("coop-done\n", 10);
        return 0;
    }
    if ([value hasPrefix:@"block"]) {
        // Non-cooperative native command: ignores the cancellation flag until
        // the flag models the native command finishing by itself.
        while (!gReleaseBlocked.load(std::memory_order_acquire)) { usleep(5000); }
        return 0;
    }
    if ([value hasPrefix:@"large-block"]) {
        // Emit a large payload and then ignore cooperative cancellation. The
        // caller's deadline must still return the captured bytes and the gate
        // must stay quarantined until the worker actually stops.
        std::vector<char> bytes(100 * 1024, 'x');
        writeBytes(bytes.data(), bytes.size());
        while (!gReleaseBlocked.load(std::memory_order_acquire)) { usleep(5000); }
        return 0;
    }
    if ([value isEqualToString:@"large"]) {
        std::vector<char> bytes(256 * 1024, 'x');
        writeBytes(bytes.data(), bytes.size());
        return 0;
    }
    if ([value isEqualToString:@"leak"]) {
        // Simulate a descendant that inherited the output write end and keeps
        // it open after the command itself returned. EOF never arrives; the
        // bridge must stop draining at its bounded deadline.
        writeBytes("leak-output\n", 12);
        int held = thread_stdout ? dup(fileno(thread_stdout)) : -1;
        std::thread([held] {
            std::this_thread::sleep_for(std::chrono::seconds(30));
            if (held >= 0) { close(held); }
        }).detach();
        return 0;
    }
    if ([value isEqualToString:@"banner"]) {
        if (thread_stdout) { fputs("banner\n", thread_stdout); fflush(thread_stdout); }
        char line[256];
        while (thread_stdin && fgets(line, sizeof(line), thread_stdin)) {
            if (thread_stdout) { fputs(line, thread_stdout); fflush(thread_stdout); }
        }
        return 0;
    }
    if ([value isEqualToString:@"bye"]) {
        if (thread_stdout) { fputs("bye\n", thread_stdout); fflush(thread_stdout); }
        return 0;
    }
    if ([value isEqualToString:@"ok"]) {
        writeBytes("ok\n", 3);
        return 0;
    }
    if (thread_stdout) { fputs("done\n", thread_stdout); fflush(thread_stdout); }
    return 0;
}

#pragma mark - Harness

static int failures = 0;
static int checks = 0;

static void check(BOOL condition, NSString *label) {
    checks += 1;
    if (condition) {
        printf("PASS  %s\n", label.UTF8String);
    } else {
        printf("FAIL  %s\n", label.UTF8String);
        failures += 1;
    }
}

static void *watchdog(void *) {
    sleep(120);
    printf("FAIL  watchdog expired; harness hung\n");
    _exit(97);
    return NULL;
}

static BOOL waitFor(BOOL (^condition)(void), NSTimeInterval seconds) {
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + seconds;
    while (NSProcessInfo.processInfo.systemUptime < deadline) {
        if (condition()) { return YES; }
        usleep(20000);
    }
    return condition();
}

static FloeShellBridgeStatus runCommand(NSString *command, NSTimeInterval timeout, NSString **stdoutText, NSString **stderrText, int32_t *code, NSTimeInterval gateTimeout = 2.0, BOOL (^shouldCancel)(void) = nil) {
    return FloeShellRunCommand(command, NSTemporaryDirectory(), NSTemporaryDirectory(), [NSString stringWithFormat:@"host-%@", NSUUID.UUID.UUIDString], @{}, nil, timeout, gateTimeout, 256 * 1024, shouldCancel, stdoutText, stderrText, code);
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        pthread_t watchdogThread;
        pthread_create(&watchdogThread, NULL, watchdog, NULL);
        pthread_detach(watchdogThread);

        NSString *root = NSTemporaryDirectory();
        root = [root stringByAppendingPathComponent:@"floe-shell-bridge-host"];
        [[NSFileManager defaultManager] createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];

        // S0: a cooperative worker actually stops inside the bounded grace. The
        // caller joins it, the worker's own teardown releases the gate, and
        // the next command starts immediately — the safe fast path.
        NSString *coopOut = nil, *coopErr = nil;
        int32_t coopCode = 125;
        FloeShellBridgeStatus coop = FloeShellRunCommand(@"coop", root, root, @"one-shot-coop", @{}, nil,
            0.15, 0.15, 4096, nil, &coopOut, &coopErr, &coopCode);
        check(coop == FloeShellBridgeStatusTimedOut, @"S0 cooperative worker outliving its deadline reports timedOut");
        check([coopOut containsString:@"coop-done"], @"S0 cooperative worker flushed its final output before stopping");
        check(!FloeShellHasActiveWorker(@"one-shot-coop"), @"S0 cooperative worker already stopped inside the grace");
        check(![FloeShellRunGateDiagnostics() containsString:@"quarantineOwner=one-shot-coop"],
              @"S0 cooperative stop leaves no quarantine behind");
        NSString *afterCoopOut = nil, *afterCoopErr = nil;
        int32_t afterCoopCode = 125;
        FloeShellBridgeStatus afterCoop = FloeShellRunCommand(@"ok", root, root, @"one-shot-after-coop", @{}, nil,
            2.0, 0.15, 4096, nil, &afterCoopOut, &afterCoopErr, &afterCoopCode);
        check(afterCoop == FloeShellBridgeStatusOK && afterCoopCode == 0 && [afterCoopOut containsString:@"ok"],
              @"S0 next command runs immediately after a cooperative timeout");

        // S1: a timed-out NON-cooperative worker quarantines the gate. The
        // bridge must never release the process-wide engine while that worker
        // can still touch global state, and it must never start a second
        // command concurrently.
        gReleaseBlocked.store(false, std::memory_order_release);
        NSString *stdout1 = nil, *stderr1 = nil;
        int32_t code1 = 125;
        FloeShellBridgeStatus first = FloeShellRunCommand(@"block 5000", root, root, @"one-shot-1", @{}, nil,
            0.15, 0.15, 4096, nil, &stdout1, &stderr1, &code1);
        check(first == FloeShellBridgeStatusTimedOut, @"S1 started worker outliving its deadline reports timedOut");
        check(FloeShellHasActiveWorker(@"one-shot-1"), @"S1 quarantined worker is still tracked as active");
        check([FloeShellRunGateDiagnostics() containsString:@"quarantined=1"], @"S1 quarantine is recorded in gate diagnostics");
        check([FloeShellRunGateDiagnostics() containsString:@"quarantineOwner=one-shot-1"], @"S1 quarantine names the owning session");

        // Safety invariant: while the quarantined worker is still alive, the
        // next command must NOT enter the engine; it reports not-started.
        NSString *busyOut = nil, *busyErr = nil;
        int32_t busyCode = 125;
        FloeShellBridgeStatus busy = FloeShellRunCommand(@"ok", root, root, @"one-shot-busy", @{}, nil,
            2.0, 0.15, 4096, nil, &busyOut, &busyErr, &busyCode);
        check(busy == FloeShellBridgeStatusBusy, @"S1 next command reports Busy while the quarantined worker lives");
        check(busyOut.length == 0 && busyErr.length == 0, @"S1 Busy carries no fabricated output");

        // Once the native command returns by itself, the worker stops and its
        // own teardown — not the timed-out caller — reopens the gate.
        gReleaseBlocked.store(true, std::memory_order_release);
        check(waitFor(^BOOL { return !FloeShellHasActiveWorker(@"one-shot-1"); }, 5.0),
              @"S1 quarantined worker stops once the command returns");
        check(![FloeShellRunGateDiagnostics() containsString:@"quarantineOwner=one-shot-1"],
              @"S1 quarantine clears when the worker stops");
        NSString *stdoutNext = nil, *stderrNext = nil;
        int32_t codeNext = 125;
        FloeShellBridgeStatus next = FloeShellRunCommand(@"ok", root, root, @"one-shot-next", @{}, nil,
            2.0, 0.15, 4096, nil, &stdoutNext, &stderrNext, &codeNext);
        check(next == FloeShellBridgeStatusOK && codeNext == 0, @"S1 next command runs after the old worker is proven stopped");
        check([stdoutNext containsString:@"ok"], @"S1 next command returns its own output");

        // S1b: cancellation quarantines the gate the same way, and the gate
        // reopens only after that worker actually stops.
        gReleaseBlocked.store(false, std::memory_order_release);
        NSTimeInterval cancelStarted = NSProcessInfo.processInfo.systemUptime;
        NSString *stdoutCancel = nil, *stderrCancel = nil;
        int32_t codeCancel = 125;
        FloeShellBridgeStatus cancelled = FloeShellRunCommand(@"block 5000", root, root, @"one-shot-cancel", @{}, nil,
            5.0, 0.15, 4096, ^BOOL { return NSProcessInfo.processInfo.systemUptime - cancelStarted > 0.2; },
            &stdoutCancel, &stderrCancel, &codeCancel);
        check(cancelled == FloeShellBridgeStatusCancelled, @"S1b cancelled caller reports Cancelled");
        check(FloeShellHasActiveWorker(@"one-shot-cancel"), @"S1b cancelled non-cooperative worker is quarantined, not released");
        NSString *busyCancelOut = nil, *busyCancelErr = nil;
        int32_t busyCancelCode = 125;
        FloeShellBridgeStatus busyCancel = FloeShellRunCommand(@"ok", root, root, @"one-shot-busy-cancel", @{}, nil,
            2.0, 0.15, 4096, nil, &busyCancelOut, &busyCancelErr, &busyCancelCode);
        check(busyCancel == FloeShellBridgeStatusBusy, @"S1b next command reports Busy while the cancelled worker lives");
        gReleaseBlocked.store(true, std::memory_order_release);
        check(waitFor(^BOOL { return !FloeShellHasActiveWorker(@"one-shot-cancel"); }, 5.0),
              @"S1b cancelled worker stops once the command returns");
        NSString *stdoutAfterCancel = nil, *stderrAfterCancel = nil;
        int32_t codeAfterCancel = 125;
        FloeShellBridgeStatus afterCancel = FloeShellRunCommand(@"ok", root, root, @"one-shot-after-cancel", @{}, nil,
            2.0, 0.15, 4096, nil, &stdoutAfterCancel, &stderrAfterCancel, &codeAfterCancel);
        check(afterCancel == FloeShellBridgeStatusOK && [stdoutAfterCancel containsString:@"ok"],
              @"S1b gate reopens only after the cancelled worker actually stops");

        // S1c: repeated commands on a clean gate.
        BOOL repeatedOK = YES;
        for (int index = 0; index < 5; index++) {
            NSString *out = nil, *err = nil; int32_t code = 125;
            FloeShellBridgeStatus status = runCommand(@"ok", 2.0, &out, &err, &code);
            if (status != FloeShellBridgeStatusOK || code != 0 || ![out containsString:@"ok"]) { repeatedOK = NO; }
        }
        check(repeatedOK, @"S1c five repeated commands each run and return output");

        // S1d: a descendant holding the write end open must not block
        // finalization; the captured output is still returned.
        NSString *leakOut = nil, *leakErr = nil;
        int32_t leakCode = 125;
        NSTimeInterval leakStarted = NSProcessInfo.processInfo.systemUptime;
        FloeShellBridgeStatus leak = FloeShellRunCommand(@"leak", root, root, @"one-shot-leak", @{}, nil,
            5.0, 2.0, 64 * 1024, nil, &leakOut, &leakErr, &leakCode);
        NSTimeInterval leakDuration = NSProcessInfo.processInfo.systemUptime - leakStarted;
        check(leak == FloeShellBridgeStatusOK && leakCode == 0, @"S1d output pipe held open by a descendant still finalizes as exited");
        check([leakOut containsString:@"leak-output"], @"S1d descendant run preserves its captured stdout");
        check(leakDuration < 2.0, @"S1d finalization is bounded (did not wait for descendant EOF)");
        check(waitFor(^BOOL { return !FloeShellHasActiveWorker(@"one-shot-leak"); }, 3.0), @"S1d worker stops after bounded drain");

        // S1e: large output is captured to the cap and the run terminates.
        NSString *largeOut = nil, *largeErr = nil;
        int32_t largeCode = 125;
        FloeShellBridgeStatus large = FloeShellRunCommand(@"large", root, root, @"one-shot-large", @{}, nil,
            5.0, 2.0, 64 * 1024, nil, &largeOut, &largeErr, &largeCode);
        check(large == FloeShellBridgeStatusOK && largeCode == 0, @"S1e large output run exits normally");
        check(largeOut.length == 64 * 1024, @"S1e large output is captured exactly to the cap");

        // S1f: a timed-out large-output worker still returns the bytes already
        // captured, then quarantines the gate until the worker stops.
        gReleaseBlocked.store(false, std::memory_order_release);
        NSString *partialOut = nil, *partialErr = nil;
        int32_t partialCode = 125;
        FloeShellBridgeStatus partial = FloeShellRunCommand(@"large-block 5000", root, root, @"one-shot-partial", @{}, nil,
            0.15, 2.0, 256 * 1024, nil, &partialOut, &partialErr, &partialCode);
        check(partial == FloeShellBridgeStatusTimedOut, @"S1f non-cooperative large worker reports timedOut");
        check(partialOut.length == 100 * 1024, @"S1f partial stdout is fully preserved before finalization");
        check(FloeShellHasActiveWorker(@"one-shot-partial"), @"S1f large worker is quarantined while still running");
        NSString *busyPartialOut = nil, *busyPartialErr = nil;
        int32_t busyPartialCode = 125;
        FloeShellBridgeStatus busyPartial = FloeShellRunCommand(@"ok", root, root, @"one-shot-busy-partial", @{}, nil,
            2.0, 0.15, 4096, nil, &busyPartialOut, &busyPartialErr, &busyPartialCode);
        check(busyPartial == FloeShellBridgeStatusBusy, @"S1f gate reports Busy while the quarantined large worker lives");
        gReleaseBlocked.store(true, std::memory_order_release);
        check(waitFor(^BOOL { return !FloeShellHasActiveWorker(@"one-shot-partial"); }, 5.0),
              @"S1f quarantined large worker stops once released");
        NSString *afterPartialOut = nil, *afterPartialErr = nil;
        int32_t afterPartialCode = 125;
        FloeShellBridgeStatus afterPartial = FloeShellRunCommand(@"ok", root, root, @"one-shot-after-partial", @{}, nil,
            2.0, 0.15, 4096, nil, &afterPartialOut, &afterPartialErr, &afterPartialCode);
        check(afterPartial == FloeShellBridgeStatusOK && [afterPartialOut containsString:@"ok"],
              @"S1f gate is usable again only after the quarantined worker stopped");

        // S2: session readiness, claim and descriptor ownership.
        int inFD = -1, outFD = -1;
        NSString *initial = nil;
        BOOL opened = FloeShellOpenSession(@"banner", root, root, @"session-1", @{}, 80, 24, &inFD, &outFD, &initial);
        check(opened && inFD >= 0 && outFD >= 0, @"S2 interactive session opens");
        check([initial containsString:@"banner"], @"S2 readiness wait drained the banner");
        check(FloeShellSessionAlive(@"session-1"), @"S2 running program reports alive after readiness");
        check(FloeShellClaimSessionDescriptors(@"session-1") == YES, @"S2 descriptor claim succeeds once");
        FloeShellCloseSession(@"session-1");
        ssize_t wrote = write(inFD, "x\n", 2);
        check(wrote == 2, @"S2 close never closes a pump-owned descriptor");
        BOOL echoed = waitFor(^BOOL {
            char buffer[64];
            ssize_t count = read(outFD, buffer, sizeof(buffer));
            return count > 0;
        }, 2.0);
        check(echoed, @"S2 pump-owned descriptor still delivers the program's output");
        // S2b: a second exchange on the same session keeps working (the
        // interactive channel is not one-shot).
        ssize_t wroteAgain = write(inFD, "y\n", 2);
        BOOL echoedAgain = wroteAgain == 2 && waitFor(^BOOL {
            char buffer[64];
            ssize_t count = read(outFD, buffer, sizeof(buffer));
            return count > 0;
        }, 2.0);
        check(echoedAgain, @"S2b repeated interactive exchange delivers output again");
        close(inFD);
        BOOL eof = waitFor(^BOOL {
            char buffer[64];
            return read(outFD, buffer, sizeof(buffer)) == 0;
        }, 3.0);
        check(eof, @"S2 closing the pump-owned write end ends the program");
        close(outFD);
        FloeShellEndSession(@"session-1");
        check(FloeShellClaimSessionDescriptors(@"session-1") == NO, @"S2 claim after end returns NO");

        // S3: close before claim must not hand descriptors to a later pump.
        int inFD2 = -1, outFD2 = -1;
        NSString *initial2 = nil;
        BOOL opened2 = FloeShellOpenSession(@"banner", root, root, @"session-2", @{}, 80, 24, &inFD2, &outFD2, &initial2);
        check(opened2, @"S3 second session opens");
        FloeShellCloseSession(@"session-2");
        check(FloeShellClaimSessionDescriptors(@"session-2") == NO, @"S3 claim after close returns NO (descriptors already closed)");

        // S4: immediately-exiting command keeps its final output and is not alive.
        int inFD3 = -1, outFD3 = -1;
        NSString *initial3 = nil;
        BOOL opened3 = FloeShellOpenSession(@"bye", root, root, @"session-3", @{}, 80, 24, &inFD3, &outFD3, &initial3);
        check(opened3 && [initial3 containsString:@"bye"], @"S4 final output of an immediately-exiting command is drained");
        check(!FloeShellSessionAlive(@"session-3"), @"S4 exited session is not reported alive");
        if (inFD3 >= 0) { close(inFD3); }
        if (outFD3 >= 0) { close(outFD3); }
        FloeShellCloseSession(@"session-3");

        // S5: bounded diagnostics for the gate.
        NSString *diagnostics = FloeShellRunGateDiagnostics();
        check([diagnostics containsString:@"gate owner="] && [diagnostics containsString:@"busyReturns="]
              && [diagnostics containsString:@"quarantined="] && [diagnostics containsString:@"waitMsTotal="],
              @"S5 gate diagnostics expose bounded counters");

        printf("\n%d/%d shell bridge host checks passed\n", checks - failures, checks);
        return failures == 0 ? 0 : 1;
    }
}
