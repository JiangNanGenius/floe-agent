//
//  feedback_shell_bridge_host.mm
//  Floe Agent — Build191 runtime review harness.
//
//  Compiles the real FloeShellBridge.mm for the macOS host against a scripted
//  stub engine (fixtures/ios_system/ios_system.h) and verifies the behaviors
//  the runtime review fixed:
//    * a command that never acquired the process-wide run gate is reported as
//      Busy (not-started), never as a fabricated execution timeout;
//    * a cancelled caller is reported as Cancelled while the gate is held;
//    * the gate reopens only after the detached worker really stops;
//    * the bounded readiness wait drains a banner and captures the final
//      output of an immediately-exiting command;
//    * descriptor ownership transfers with FloeShellClaimSessionDescriptors,
//      and FloeShellCloseSession never closes a pump-owned descriptor;
//    * claiming after a close returns NO so the caller cannot touch recycled
//      descriptor numbers.
//
//  This is a desktop host check of the bridge state machine, not an iOS or
//  ios_system qualification.
//
#import <Foundation/Foundation.h>

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

int ios_system(const char *command) {
    NSString *value = command ? [NSString stringWithUTF8String:command] : @"";
    if ([value hasPrefix:@"block"]) {
        while (!gReleaseBlocked.load(std::memory_order_acquire)) { usleep(5000); }
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
    sleep(45);
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

int main(int argc, const char **argv) {
    @autoreleasepool {
        pthread_t watchdogThread;
        pthread_create(&watchdogThread, NULL, watchdog, NULL);
        pthread_detach(watchdogThread);

        NSString *root = NSTemporaryDirectory();
        root = [root stringByAppendingPathComponent:@"floe-shell-bridge-host"];
        [[NSFileManager defaultManager] createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];

        // S1: gate ownership and not-started vs timed-out.
        NSString *stdout1 = nil, *stderr1 = nil;
        int32_t code1 = 125;
        FloeShellBridgeStatus first = FloeShellRunCommand(@"block 5000", root, root, @"one-shot-1", @{}, nil,
            0.15, 0.15, 4096, nil, &stdout1, &stderr1, &code1);
        check(first == FloeShellBridgeStatusTimedOut, @"S1 started worker outliving its deadline reports timedOut");
        check(FloeShellHasActiveWorker(@"one-shot-1"), @"S1 detached worker is still tracked as active");

        NSString *stdout2 = nil, *stderr2 = nil;
        int32_t code2 = 125;
        FloeShellBridgeStatus second = FloeShellRunCommand(@"block 10", root, root, @"one-shot-2", @{}, nil,
            0.5, 0.15, 4096, nil, &stdout2, &stderr2, &code2);
        check(second == FloeShellBridgeStatusBusy, @"S1 queued command reports Busy (not-started), not timedOut");
        check(stdout2.length == 0 && stderr2.length == 0, @"S1 Busy carries no fabricated output");

        NSString *stdout3 = nil, *stderr3 = nil;
        int32_t code3 = 125;
        FloeShellBridgeStatus cancelled = FloeShellRunCommand(@"block 10", root, root, @"one-shot-3", @{}, nil,
            0.5, 0.15, 4096, ^BOOL { return YES; }, &stdout3, &stderr3, &code3);
        check(cancelled == FloeShellBridgeStatusCancelled, @"S1 cancelled caller reports Cancelled while the gate is held");

        gReleaseBlocked.store(true, std::memory_order_release);
        BOOL gateReopened = waitFor(^BOOL { return !FloeShellHasActiveWorker(@"one-shot-1"); }, 5.0);
        check(gateReopened, @"S1 detached worker actually stops");
        NSString *stdout4 = nil, *stderr4 = nil;
        int32_t code4 = 125;
        FloeShellBridgeStatus fourth = FloeShellRunCommand(@"ok", root, root, @"one-shot-4", @{}, nil,
            2.0, 2.0, 4096, nil, &stdout4, &stderr4, &code4);
        check(fourth == FloeShellBridgeStatusOK && code4 == 0, @"S1 gate reopens only after the worker stopped");

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
              && [diagnostics containsString:@"waitMsTotal="], @"S5 gate diagnostics expose bounded counters");

        printf("\n%d/%d shell bridge host checks passed\n", checks - failures, checks);
        return failures == 0 ? 0 : 1;
    }
}
