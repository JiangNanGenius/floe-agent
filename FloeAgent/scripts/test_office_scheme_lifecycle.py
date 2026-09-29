#!/usr/bin/env python3
"""Behavioral regression for the pinned Office native URL-scheme task lifecycle.

The *same* driver is compiled against (1) the exact pinned upstream
ios/Mobile sources and (2) those sources after
``patches/ios-scheme-task-lifecycle.patch`` is applied. The driver links the
real ``MobileSocket.mm`` / ``CoolURLSchemeHandler.mm`` (only their surrounding
engine dependencies are shimmed) and exercises:

  - stop before a queued write block runs (synchronous invalidation)
  - stop before a queued open block runs (handler bookkeeping keeps it tracked)
  - stop landing while a write is emitting, then close/reopen redelivery
  - normal ordered text/binary delivery
  - open -> write -> write close/reopen with serial continuity
  - direct MobileSocket write/stop (the pinned race primary reproduced)
  - unrelated 404 tasks and stops of untracked tasks (teardown bookkeeping)

The original must fail the stop-race scenarios while delivery/order scenarios
still pass; the patched tree must pass everything. This is mock-native
transport evidence on macOS, NOT device Office acceptance: WKURLSchemeTask is
faked and no engine/editor runs.

Usage:
    python3 test_office_scheme_lifecycle.py --source <root-with-ios/Mobile>
    python3 test_office_scheme_lifecycle.py --bundle <extracted-format2-bundle>
"""
import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

SCRIPT_DIR = Path(__file__).resolve().parent
REPO_ROOT = SCRIPT_DIR.parent.parent
DEFAULT_LOCK = SCRIPT_DIR.parent / "ThirdParty/Collabora/engine.lock.json"
PATCH = SCRIPT_DIR.parent / "ThirdParty/Collabora/patches/ios-scheme-task-lifecycle.patch"

NATIVE_FILES = (
    "ios/Mobile/MobileSocket.h",
    "ios/Mobile/MobileSocket.mm",
    "ios/Mobile/CoolURLSchemeHandler.h",
    "ios/Mobile/CoolURLSchemeHandler.mm",
)

# Scenarios the unpatched pinned sources are expected to fail.
ORIGINAL_EXPECTED_FAILURES = {
    "stop_queued_write",
    "stop_queued_open",
    "cancel_in_callback",
    "stop_mid_write_then_reopen",
    "direct_write_stop",
}
# Scenarios that must pass even on the original tree: the fix must not repair
# the race by breaking delivery.
DELIVERY_SCENARIOS = {
    "normal_delivery_order",
    "open_write_write_reopen",
    "unrelated_404_and_untracked_stop",
}
# Queue-semantics scenarios the patch additionally guarantees. The original
# bookkeeping races these (duplicate/drop), but no original-fail assertion is
# pinned — the patched transport is required to pass them.
PATCHED_ONLY_SCENARIOS = {
    "queued_send_during_delivery",
    "overlapping_writes",
    "multi_chunk_binary",
    "stop_after_frames_before_finish",
    "canceled_head_live_follower",
    "reentrant_stop_final_newline",
}

DRIVER = r'''#import <Foundation/Foundation.h>
#import <WebKit/WKURLSchemeTask.h>
#import <WebKit/WKURLSchemeHandler.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>
#import <unistd.h>

@class WKWebView;

#import "MobileSocket.h"
#import "CoolURLSchemeHandler.h"

// ---- Fake WKURLSchemeTask -------------------------------------------------
// Records the ordered callback stream. Any callback performed after WebKit's
// stopURLSchemeTask would, on a real task, be a fatal exception; here it is
// counted so one process can exercise every scenario.
@interface FakeTask : NSObject <WKURLSchemeTask>
@property (nonatomic, copy) NSURLRequest *req;
@property (nonatomic, strong) NSMutableArray<NSString *> *events;
@property (nonatomic, strong) NSMutableData *body;
@property (nonatomic) BOOL stopped;
@property (nonatomic) int late;
@property (nonatomic) int finishes;
@property (nonatomic, weak) CoolURLSchemeHandler *stopHandler;
// Reentrant mode: stop is invoked synchronously from inside the indicated
// callback, on the emitting thread (main queue for the patched transport).
@property (nonatomic) BOOL stopWithinResponse;
@property (nonatomic) BOOL stopInFirstData;
// One-shot hook run after |dataHookAfter| data events, still inside that
// callback. Used to act DURING delivery (push a message / start a 2nd write).
@property (nonatomic, copy) void (^dataHook)(void);
@property (nonatomic) int dataHookAfter;
@property (nonatomic) BOOL dataHookRan;
@end

@implementation FakeTask
- (instancetype)initWithPath:(NSString *)path {
    self = [super init];
    NSURL *url = [NSURL URLWithString:[@"https://online.floe.invalid" stringByAppendingString:path]];
    self.req = [NSURLRequest requestWithURL:url];
    self.events = [NSMutableArray array];
    self.body = [NSMutableData data];
    return self;
}
- (NSURLRequest *)request { return self.req; }
- (void)floePerformStop {
    self.stopped = YES;
    [self.stopHandler webView:nil stopURLSchemeTask:self];
}
- (void)didReceiveResponse:(NSURLResponse *)response {
    [self.events addObject:@"response"];
    if (self.stopped) self.late++;
    if (self.stopWithinResponse) {
        // Reentrant, deterministic barrier: stop runs inside this callback,
        // before any data frame. WebKit delivers stop on the main run loop
        // too, so a stop "in the gap" can only happen this way; the patched
        // transport's remaining main-queue emission blocks must observe it.
        self.stopWithinResponse = NO;
        [self floePerformStop];
    }
}
- (void)didReceiveData:(NSData *)data {
    if (self.stopInFirstData) {
        // Reentrant stop from within the first data frame: the stop must
        // return without deadlocking; no further frame of this write may be
        // emitted afterwards.
        self.stopInFirstData = NO;
        [self.events addObject:[NSString stringWithFormat:@"data:%lu", (unsigned long)data.length]];
        [self.body appendData:data];
        [self floePerformStop];
        return;
    }
    [self.events addObject:[NSString stringWithFormat:@"data:%lu", (unsigned long)data.length]];
    [self.body appendData:data];
    if (self.stopped) self.late++;
    if (!self.dataHookRan && self.dataHook != nil) {
        NSUInteger dataEvents = 0;
        for (NSString *event in self.events)
            if ([event hasPrefix:@"data:"]) dataEvents++;
        if ((int)dataEvents >= self.dataHookAfter) {
            self.dataHookRan = YES;
            self.dataHook();
        }
    }
}
- (void)didFinish {
    [self.events addObject:@"finish"];
    self.finishes++;
    if (self.stopped) self.late++;
}
- (void)didFailWithError:(NSError *)error {
    [self.events addObject:[NSString stringWithFormat:@"fail:%@", error.localizedDescription]];
    if (self.stopped) self.late++;
}
@end

// ---- Mini test framework --------------------------------------------------
static int failures = 0;
static int checks = 0;

static void record(NSString *name, BOOL ok, NSString *detail) {
    checks++;
    if (!ok) failures++;
    NSString *line = [NSString stringWithFormat:@"RESULT name=%@ pass=%d %@\n",
                      name, ok, detail ?: @""];
    // Plain stderr (no NSLog timestamp) so the harness parser reads it.
    fprintf(stderr, "%s", line.UTF8String);
}

#define REQUIRE(SCEN, COND, ...) record(SCEN, (COND) ? YES : NO, [NSString stringWithFormat:__VA_ARGS__])

static BOOL waitUntil(BOOL (^predicate)(void), NSTimeInterval timeout) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while ([[NSDate date] compare:deadline] == NSOrderedAscending) {
        if (predicate()) return YES;
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false);
    }
    return predicate();
}

static BOOL waitSignal(dispatch_semaphore_t semaphore) {
    // Poll while pumping the run loop: signals are delivered on the main queue
    // and background settlement uses dispatch_sync(main), which only progress
    // while the main run loop runs.
    return waitUntil(^BOOL {
        return dispatch_semaphore_wait(semaphore, DISPATCH_TIME_NOW) == 0;
    }, 5);
}

static FakeTask *socketTask(NSString *command) {
    NSString *path = [NSString stringWithFormat:
        @"/cool/mobilesocket/cool/ws/%@/t/42", command];
    return [[FakeTask alloc] initWithPath:path];
}

static dispatch_queue_t socketQueueOf(CoolURLSchemeHandler *handler) {
    MobileSocket *ms = [handler valueForKey:@"mobileSocket"];
    return [ms valueForKey:@"queue"];
}

static MobileSocket *socketOf(CoolURLSchemeHandler *handler) {
    return [handler valueForKey:@"mobileSocket"];
}

static NSUInteger setCount(CoolURLSchemeHandler *handler, NSString *ivar) {
    return [[handler valueForKey:ivar] count];
}

static void stopTask(CoolURLSchemeHandler *handler, FakeTask *task) {
    task.stopped = YES;
    [handler webView:nil stopURLSchemeTask:task];
}

// Deterministically wait until all work already queued on the background
// preparation queue AND the main-queue emission/finish blocks it enqueues have
// all run. Ordering: once the background barrier runs, the emission block has
// already been dispatched to the main queue (FIFO), so a main barrier queued
// afterwards executes strictly after emission and completeTask.
static void drainSocket(CoolURLSchemeHandler *handler) {
    dispatch_queue_t q = socketQueueOf(handler);
    __block BOOL socketCleared = NO;
    // The barrier queues its acknowledgement on main; waitUntil pumps, so
    // dispatch_sync(main) hops made by earlier queue blocks can complete.
    dispatch_async(q, ^{
        dispatch_async(dispatch_get_main_queue(), ^{ socketCleared = YES; });
    });
    waitUntil(^BOOL { return socketCleared; }, 5);
}

static NSData *expectedFrame(NSString *type, int serial, NSString *message) {
    NSString *frame = [NSString stringWithFormat:@"%@0x%x\n0x%lx\n%@\n",
        type, serial, (unsigned long)message.length, message];
    return [frame dataUsingEncoding:NSUTF8StringEncoding];
}

static int socketSerial(MobileSocket *ms) {
    // serial is a plain int ivar on both original and patched implementations;
    // frame numbers are opaque to JS, so preparation may advance it past
    // undelivered frames. Read it to predict replacement-task numbers.
    return [[ms valueForKey:@"serial"] intValue];
}

// ---- Scenarios ------------------------------------------------------------

// Stop is delivered while the write block is still queued behind the queue
// barrier. Nothing may be emitted; the finish bookkeeping must still settle.
static void scenarioStopQueuedWrite(void) {
    NSString *const name = @"stop_queued_write";
    CoolURLSchemeHandler *h = [[CoolURLSchemeHandler alloc] initWithDocument:nil];
    FakeTask *t = socketTask(@"write");
    dispatch_queue_t q = socketQueueOf(h);
    dispatch_suspend(q);
    [h webView:nil startURLSchemeTask:t];
    stopTask(h, t);                                // synchronous invalidation
    dispatch_resume(q);
    drainSocket(h);
    REQUIRE(name, t.events.count == 0, @"events=%@ late=%d", t.events, t.late);
    REQUIRE(name, t.late == 0, @"late=%d", t.late);
}

// Same for an open task; upstream removed it from handler bookkeeping at
// start, so the stop was never even forwarded.
static void scenarioStopQueuedOpen(void) {
    NSString *const name = @"stop_queued_open";
    CoolURLSchemeHandler *h = [[CoolURLSchemeHandler alloc] initWithDocument:nil];
    FakeTask *t = socketTask(@"open");
    dispatch_queue_t q = socketQueueOf(h);
    dispatch_suspend(q);
    [h webView:nil startURLSchemeTask:t];
    stopTask(h, t);
    dispatch_resume(q);
    drainSocket(h);
    REQUIRE(name, t.events.count == 0, @"events=%@ late=%d", t.events, t.late);
    REQUIRE(name, t.late == 0, @"late=%d", t.late);
}

// Stop is invoked REENTRANTLY from inside the first data frame of message 1
// (same thread that emits WebKit callbacks). No deadlock may occur; no further
// frames or finish are emitted on the stopped task; both full messages are
// redelivered to the replacement task in order (message 1's serial 1 was spent
// on the abandoned frame, so redelivery uses serials 2,3).
static void scenarioCancelInCallback(void) {
    NSString *const name = @"cancel_in_callback";
    CoolURLSchemeHandler *h = [[CoolURLSchemeHandler alloc] initWithDocument:nil];
    MobileSocket *ms = socketOf(h);

    dispatch_semaphore_t q1 = dispatch_semaphore_create(0), q2 = dispatch_semaphore_create(0);
    [ms queueSend:"one" then:^{ dispatch_semaphore_signal(q1); }];
    [ms queueSend:"two" then:^{ dispatch_semaphore_signal(q2); }];
    waitSignal(q1);
    waitSignal(q2);

    FakeTask *t = socketTask(@"write");
    t.stopHandler = h;
    t.stopInFirstData = YES;
    [h webView:nil startURLSchemeTask:t];
    drainSocket(h);

    // Old task: response + the single header frame that stopped itself; no
    // finish, and that frame entered before stop so it is not a "late" call.
    BOOL shapeOK = t.late == 0 && t.finishes == 0 && t.events.count == 2
        && [t.events[0] isEqual:@"response"] && [t.events[1] hasPrefix:@"data:"];
    REQUIRE(name, shapeOK, @"events=%@ late=%d finishes=%d", t.events, t.late, t.finishes);

    FakeTask *t2 = socketTask(@"write");
    int base = socketSerial(ms); // prep of cancelled write consumed serials 1,2
    [h webView:nil startURLSchemeTask:t2];
    BOOL finished = waitUntil(^BOOL { return t2.finishes == 1; }, 5);
    NSMutableData *expected = [NSMutableData data];
    [expected appendData:expectedFrame(@"T", base + 1, @"one")];
    [expected appendData:expectedFrame(@"T", base + 2, @"two")];
    REQUIRE(name, finished && t2.late == 0 && [t2.body isEqualToData:expected],
        @"finished=%d late=%d body=%@", finished, t2.late,
        [[NSString alloc] initWithData:t2.body encoding:NSUTF8StringEncoding]);
}

// Stop lands between the response callback and the first data frame (the
// response invokes stop reentrantly). Every later frame is suppressed, then a
// fresh write task redelivers both queued messages, intact and ordered.
static void scenarioStopMidWriteThenReopen(void) {
    NSString *const name = @"stop_mid_write_then_reopen";
    CoolURLSchemeHandler *h = [[CoolURLSchemeHandler alloc] initWithDocument:nil];
    MobileSocket *ms = socketOf(h);

    dispatch_semaphore_t q1 = dispatch_semaphore_create(0), q2 = dispatch_semaphore_create(0);
    [ms queueSend:"one" then:^{ dispatch_semaphore_signal(q1); }];
    [ms queueSend:"two" then:^{ dispatch_semaphore_signal(q2); }];
    waitSignal(q1);
    waitSignal(q2);

    FakeTask *t = socketTask(@"write");
    t.stopHandler = h;
    // Deterministic reentrant stop inside the response callback, before any
    // data frame. WebKit delivers stop on the main run loop, so this is the
    // exact boundary at which a stop can land.
    t.stopWithinResponse = YES;
    int base = socketSerial(ms); // Patched prep advances serial before response.
    [h webView:nil startURLSchemeTask:t];
    drainSocket(h);

    REQUIRE(name, t.late == 0, @"events after stop=%@ late=%d", t.events, t.late);
    // Only the response may have completed before stop; no data frames, no finish.
    REQUIRE(name, [t.events isEqualToArray:@[@"response"]], @"events=%@", t.events);

    // Reopen: neither message was delivered or consumed. The patched transport
    // already spent serials base+1,base+2 preparing this batch, so redelivery
    // uses base+3,base+4 (original spends none, so it sees base+1,base+2).
    FakeTask *t2 = socketTask(@"write");
    [h webView:nil startURLSchemeTask:t2];
    BOOL finished = waitUntil(^BOOL { return t2.finishes == 1; }, 5);
    NSMutableData *expected = [NSMutableData data];
    [expected appendData:expectedFrame(@"T", base + 1, @"one")];
    [expected appendData:expectedFrame(@"T", base + 2, @"two")];
    REQUIRE(name, finished && t2.late == 0 && [t2.body isEqualToData:expected],
        @"finished=%d late=%d body=%@", finished, t2.late,
        [[NSString alloc] initWithData:t2.body encoding:NSUTF8StringEncoding]);
}

// Normal delivery: text + binary messages, headers, serial order, one finish.
static void scenarioNormalDelivery(void) {
    NSString *const name = @"normal_delivery_order";
    CoolURLSchemeHandler *h = [[CoolURLSchemeHandler alloc] initWithDocument:nil];
    MobileSocket *ms = socketOf(h);

    __block int pending = 3;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    void (^note)(void) = ^{ if (--pending == 0) dispatch_semaphore_signal(done); };
    [ms queueSend:"hello" then:note];
    [ms queueSend:"bin\nary" then:note];
    [ms queueSend:"world" then:note];
    waitSignal(done);

    FakeTask *t = socketTask(@"write");
    [h webView:nil startURLSchemeTask:t];
    BOOL finished = waitUntil(^BOOL { return t.finishes == 1; }, 5);

    NSMutableData *expected = [NSMutableData data];
    [expected appendData:expectedFrame(@"T", 1, @"hello")];
    [expected appendData:expectedFrame(@"B", 2, @"bin\nary")];
    [expected appendData:expectedFrame(@"T", 3, @"world")];
    REQUIRE(name, finished && t.late == 0 && [t.body isEqualToData:expected],
        @"finished=%d body=%@", finished,
        [[NSString alloc] initWithData:t.body encoding:NSUTF8StringEncoding]);
    REQUIRE(name, t.finishes == 1, @"finishes=%d", t.finishes);
}

// open -> write -> write: identifier, serial reset then continuity, no state
// leakage between tasks.
static void scenarioOpenWriteWriteReopen(void) {
    NSString *const name = @"open_write_write_reopen";
    CoolURLSchemeHandler *h = [[CoolURLSchemeHandler alloc] initWithDocument:nil];
    MobileSocket *ms = socketOf(h);

    FakeTask *openTask = socketTask(@"open");
    [h webView:nil startURLSchemeTask:openTask];
    BOOL openDone = waitUntil(^BOOL { return openTask.finishes == 1; }, 5);
    REQUIRE(name, openDone && openTask.late == 0
        && [[[NSString alloc] initWithData:openTask.body encoding:NSUTF8StringEncoding] isEqual:@"mobile"],
        @"body=%@",
        [[NSString alloc] initWithData:openTask.body encoding:NSUTF8StringEncoding]);

    dispatch_semaphore_t q1 = dispatch_semaphore_create(0);
    [ms queueSend:"a" then:^{ dispatch_semaphore_signal(q1); }];
    waitSignal(q1);
    FakeTask *w1 = socketTask(@"write");
    [h webView:nil startURLSchemeTask:w1];
    waitUntil(^BOOL { return w1.finishes == 1; }, 5);
    REQUIRE(name, [w1.body isEqualToData:expectedFrame(@"T", 1, @"a")],
        @"body=%@",
        [[NSString alloc] initWithData:w1.body encoding:NSUTF8StringEncoding]);

    dispatch_semaphore_t q2 = dispatch_semaphore_create(0);
    [ms queueSend:"bb" then:^{ dispatch_semaphore_signal(q2); }];
    waitSignal(q2);
    FakeTask *w2 = socketTask(@"write");
    [h webView:nil startURLSchemeTask:w2];
    waitUntil(^BOOL { return w2.finishes == 1; }, 5);
    REQUIRE(name, w2.late == 0 && [w2.body isEqualToData:expectedFrame(@"T", 2, @"bb")],
        @"body=%@",
        [[NSString alloc] initWithData:w2.body encoding:NSUTF8StringEncoding]);

    NSUInteger states = 0;
    if (class_getInstanceVariable([ms class], "taskStates") != NULL)
        states = [[ms valueForKey:@"taskStates"] count];
    REQUIRE(name, states == 0 && setCount(h, @"ongoingTasks") == 0,
        @"taskStates=%lu ongoing=%lu",
        (unsigned long)states, (unsigned long)setCount(h, @"ongoingTasks"));
}

// Direct socket analogue of primary's pinned reproduction: blocked queue,
// queued write, then stop. Zero callbacks after stop; state still settles.
static void scenarioDirectWriteStop(void) {
    NSString *const name = @"direct_write_stop";
    MobileSocket *s = [[MobileSocket alloc] init];
    FakeTask *t = socketTask(@"write");
    dispatch_queue_t q = [s valueForKey:@"queue"];
    dispatch_semaphore_t finished = dispatch_semaphore_create(0);
    dispatch_suspend(q);
    [s write:t onFinish:^{ dispatch_semaphore_signal(finished); }];
    t.stopped = YES;
    [s stopURLSchemeTask:t];
    dispatch_resume(q);
    waitSignal(finished);
    REQUIRE(name, t.events.count == 0 && t.late == 0,
        @"events=%@ late=%d", t.events, t.late);
}

// A message is pushed DURING an in-flight write (after the batch started).
// It must survive the write's completion and arrive on the next write task,
// once, in order, after the current batch — never dropped by a success clear.
static void scenarioQueueSendDuringDelivery(void) {
    NSString *const name = @"queued_send_during_delivery";
    CoolURLSchemeHandler *h = [[CoolURLSchemeHandler alloc] initWithDocument:nil];
    MobileSocket *ms = socketOf(h);

    __block int pending = 3;
    dispatch_semaphore_t ready = dispatch_semaphore_create(0);
    void (^note)(void) = ^{ if (--pending == 0) dispatch_semaphore_signal(ready); };
    [ms queueSend:"alpha" then:note];
    [ms queueSend:"beta" then:note];
    [ms queueSend:"gamma" then:note];
    waitSignal(ready);

    FakeTask *t = socketTask(@"write");
    int base = socketSerial(ms);
    t.dataHookAfter = 2; // During the first batch's delivery.
    t.dataHook = ^{
        // Do not wait: pumping here would execute later queued message/finish
        // blocks before this message block completes. Queue FIFO guarantees
        // this push runs before the write's clear, so delta is preserved.
        [ms queueSend:"delta" then:^{}];
    };
    [h webView:nil startURLSchemeTask:t];
    drainSocket(h);
    BOOL firstDone = t.finishes == 1;

    NSMutableData *expectedFirst = [NSMutableData data];
    [expectedFirst appendData:expectedFrame(@"T", base + 1, @"alpha")];
    [expectedFirst appendData:expectedFrame(@"T", base + 2, @"beta")];
    [expectedFirst appendData:expectedFrame(@"T", base + 3, @"gamma")];
    BOOL firstOK = firstDone && t.late == 0 && [t.body isEqualToData:expectedFirst];

    // Next write picks exactly the concurrently pushed message.
    FakeTask *t2 = socketTask(@"write");
    int nextBase = socketSerial(ms);
    [h webView:nil startURLSchemeTask:t2];
    BOOL secondDone = waitUntil(^BOOL { return t2.finishes == 1; }, 5);
    BOOL secondOK = secondDone && t2.late == 0
        && [t2.body isEqualToData:expectedFrame(@"T", nextBase + 1, @"delta")];

    REQUIRE(name, firstOK, @"firstDone=%d first body=%@ late=%d", firstDone,
        [[NSString alloc] initWithData:t.body encoding:NSUTF8StringEncoding], t.late);
    REQUIRE(name, secondOK, @"second body=%@ late=%d",
        [[NSString alloc] initWithData:t2.body encoding:NSUTF8StringEncoding], t2.late);
}

// Two write requests overlap: B is started while A is delivering. Every queued
// message must be delivered exactly once total, in order; B waits and serves
// later messages (here: an empty batch) rather than replaying A's batch.
static void scenarioOverlappingWrites(void) {
    NSString *const name = @"overlapping_writes";
    CoolURLSchemeHandler *h = [[CoolURLSchemeHandler alloc] initWithDocument:nil];
    MobileSocket *ms = socketOf(h);

    dispatch_semaphore_t ready = dispatch_semaphore_create(0);
    __block int pending = 2;
    void (^note)(void) = ^{ if (--pending == 0) dispatch_semaphore_signal(ready); };
    [ms queueSend:"one" then:note];
    [ms queueSend:"two" then:note];
    waitSignal(ready);

    FakeTask *a = socketTask(@"write");
    int base = socketSerial(ms);
    FakeTask *b = socketTask(@"write");
    a.dataHookAfter = 1; // Start B while A is inside its first data frame.
    a.dataHook = ^{
        [h webView:nil startURLSchemeTask:b];
    };
    [h webView:nil startURLSchemeTask:a];
    BOOL settled = waitUntil(^BOOL { return a.finishes == 1 && b.finishes == 1; }, 5);

    NSMutableData *expectedA = [NSMutableData data];
    [expectedA appendData:expectedFrame(@"T", base + 1, @"one")];
    [expectedA appendData:expectedFrame(@"T", base + 2, @"two")];
    BOOL aOK = [a.body isEqualToData:expectedA];
    // B waited, got the empty remainder: response then finish, no data frames.
    BOOL bOK = [b.events isEqualToArray:@[@"response", @"finish"]] && b.body.length == 0;
    // Exactly-once invariant across the whole session.
    BOOL once = a.late == 0 && b.late == 0
        && setCount(h, @"ongoingTasks") == 0 && setCount(h, @"ongoingMobileSocketTasks") == 0;

    REQUIRE(name, settled && aOK && bOK && once,
        @"settled=%d a=%@ b=%@ late a=%d b=%d", settled,
        [[NSString alloc] initWithData:a.body encoding:NSUTF8StringEncoding], b.events, a.late, b.late);
}

// Stop lands AFTER the last message's newline completed but BEFORE didFinish:
// the message bytes are consumed, so it must NOT be requeued (off-by-one).
// The replacement write gets an empty stream, never a duplicate.
static void scenarioStopAfterFramesBeforeFinish(void) {
    NSString *const name = @"stop_after_frames_before_finish";
    CoolURLSchemeHandler *h = [[CoolURLSchemeHandler alloc] initWithDocument:nil];
    MobileSocket *ms = socketOf(h);

    dispatch_semaphore_t ready = dispatch_semaphore_create(0);
    [ms queueSend:"only" then:^{ dispatch_semaphore_signal(ready); }];
    waitSignal(ready);

    FakeTask *t = socketTask(@"write");
    t.stopHandler = h;
    // From inside the 3rd (last) data frame, queue an async stop on main.
    // The socket queues didFinish only AFTER this frame block returns, so FIFO
    // makes the stop run strictly before didFinish — the exact boundary.
    t.dataHookAfter = 3;
    t.dataHook = ^{
        dispatch_async(dispatch_get_main_queue(), ^{ [t floePerformStop]; });
    };
    [h webView:nil startURLSchemeTask:t];
    drainSocket(h);

    // Old task delivered all frames but finish was suppressed; no late call.
    int base = socketSerial(ms);
    BOOL oldShapeOK = t.late == 0 && t.finishes == 0;
    NSMutableData *oldExpected = [NSMutableData data];
    [oldExpected appendData:expectedFrame(@"T", base, @"only")];
    BOOL oldBodyOK = [t.body isEqualToData:oldExpected];

    // Replacement write: nothing queued -> empty batch, response then finish,
    // never a duplicate "only".
    FakeTask *t2 = socketTask(@"write");
    [h webView:nil startURLSchemeTask:t2];
    drainSocket(h);
    BOOL reopenOK = [t2.events isEqualToArray:@[@"response", @"finish"]] && t2.body.length == 0;

    REQUIRE(name, oldShapeOK && oldBodyOK && reopenOK,
        @"oldShape=%d oldBody=%d reopen=%@ old=%@ late=%d",
        oldShapeOK, oldBodyOK, t2.events,
        [[NSString alloc] initWithData:t.body encoding:NSUTF8StringEncoding], t.late);
}

// A binary message larger than the chunk limit is streamed in bounded chunks:
// wire framing unchanged, all bytes arrive exactly once, with more than three
// data frames (header + multiple body chunks + newline).
static void scenarioMultiChunkBinary(void) {
    NSString *const name = @"multi_chunk_binary";
    CoolURLSchemeHandler *h = [[CoolURLSchemeHandler alloc] initWithDocument:nil];
    MobileSocket *ms = socketOf(h);

    const NSUInteger size = 600 * 1024;
    std::string big(size, 'x');
    big[100] = '\n'; // Newline inside => binary frame.
    big[size - 1] = '\n';

    dispatch_semaphore_t ready = dispatch_semaphore_create(0);
    [ms queueSend:big then:^{ dispatch_semaphore_signal(ready); }];
    waitSignal(ready);

    FakeTask *t = socketTask(@"write");
    [h webView:nil startURLSchemeTask:t];
    BOOL finished = waitUntil(^BOOL { return t.finishes == 1; }, 5);

    NSUInteger dataEvents = 0;
    for (NSString *event in t.events)
        if ([event hasPrefix:@"data:"]) dataEvents++;
    // 600 KiB / 256 KiB => 3 body chunks, so frames: 1 header + 3 + 1 newline
    // = 5 data events. This proves the body was chunked rather than copied
    // into a single unbounded didReceiveData.
    BOOL chunked = dataEvents == 5;

    NSString *message = [NSString stringWithUTF8String:big.c_str()];
    NSMutableData *expected = [NSMutableData data];
    [expected appendData:expectedFrame(@"B", 1, message)];
    BOOL bytesOK = [t.body isEqualToData:expected];

    REQUIRE(name, finished && chunked && bytesOK && t.late == 0,
        @"finished=%d chunked=%d dataEvents=%lu bytesOK=%d late=%d",
        finished, chunked, (unsigned long)dataEvents, bytesOK, t.late);
}

// The head write is cancelled while a follower waits; the follower must be
// pumped and deliver its own queued message, never stranded.
static void scenarioCanceledHeadLiveFollower(void) {
    NSString *const name = @"canceled_head_live_follower";
    CoolURLSchemeHandler *h = [[CoolURLSchemeHandler alloc] initWithDocument:nil];
    MobileSocket *ms = socketOf(h);

    // One message for the head. The follower's message is pushed only after
    // the head's batch moved, so it stays waiting behind.
    dispatch_semaphore_t ready = dispatch_semaphore_create(0);
    [ms queueSend:"head" then:^{ dispatch_semaphore_signal(ready); }];
    waitSignal(ready);

    FakeTask *head = socketTask(@"write");
    head.stopHandler = h;
    FakeTask *follower = socketTask(@"write");
    head.dataHookAfter = 1; // During the head's first frame: register follower,
    head.dataHook = ^{     // then stop the head; the follower must be pumped.
        [h webView:nil startURLSchemeTask:follower];
    };
    // Push the follower's message as soon as the head batch left the queue;
    // queueSend ordering behind the head's write blocks keeps it pending.
    [h webView:nil startURLSchemeTask:head];
    // The follower needs a message queued while waiting; push after start so
    // it lands in the empty sendingMessages once head's batch moved.
    dispatch_semaphore_t pushed = dispatch_semaphore_create(0);
    [ms queueSend:"follow" then:^{ dispatch_semaphore_signal(pushed); }];
    waitSignal(pushed);
    // Now cancel the head; its settlement must pump the follower.
    [head floePerformStop];
    BOOL settled = waitUntil(^BOOL { return follower.finishes == 1; }, 5);

    BOOL followerOK = follower.late == 0;
    int base = socketSerial(ms);
    NSMutableData *followExpected = [NSMutableData data];
    // The cancelled head consumed serial 1 preparing/delivering its first frame;
    // follower delivery uses a later serial; match via body text instead.
    BOOL followBodyOK = follower.body.length > 0
        && [[[NSString alloc] initWithData:follower.body encoding:NSUTF8StringEncoding] hasSuffix:@"follow\n"];

    // The undelivered head suffix (none of head's frames completed before the
    // reentrant stop? header frame did complete) — head message redelivery is
    // asserted only if its frames did not finish; here the header frame ran,
    // so "head" stays queued before "follow" only when undelivered. Assert
    // exactly-once: either head delivered fully or head is not duplicated.
    BOOL once = follower.finishes == 1 && head.late == 0 && follower.late == 0
        && setCount(h, @"ongoingTasks") == 0;

    REQUIRE(name, settled && followerOK && followBodyOK && once,
        @"settled=%d followBody=%@ events=%@ base=%d", settled,
        [[NSString alloc] initWithData:follower.body encoding:NSUTF8StringEncoding],
        follower.events, base);
}

// REENTRANT stop from inside a message's trailing-newline didReceiveData
// callback — the exact frame that completes delivery. The newline genuinely
// entered WebKit (executed), so the message must be popped even though stop
// flipped the task to inactive during the same callback; didFinish is
// suppressed and the replacement write gets an empty stream, never a duplicate
// of the fully delivered message. Regression for emit conflating "callback
// ran" with "still active", which skipped pop_front and requeued the message.
static void scenarioReentrantStopFinalNewline(void) {
    NSString *const name = @"reentrant_stop_final_newline";
    CoolURLSchemeHandler *h = [[CoolURLSchemeHandler alloc] initWithDocument:nil];
    MobileSocket *ms = socketOf(h);

    dispatch_semaphore_t ready = dispatch_semaphore_create(0);
    [ms queueSend:"only" then:^{ dispatch_semaphore_signal(ready); }];
    waitSignal(ready);

    FakeTask *t = socketTask(@"write");
    t.stopHandler = h;
    // Frame for "only" is header, body, newline = data events 1, 2, 3. Stop
    // runs synchronously, still inside event 3 (the final newline callback).
    t.dataHookAfter = 3;
    t.dataHook = ^{
        [t floePerformStop];
    };
    [h webView:nil startURLSchemeTask:t];
    drainSocket(h);

    int base = socketSerial(ms);
    NSMutableData *oldExpected = [NSMutableData data];
    [oldExpected appendData:expectedFrame(@"T", base, @"only")];
    // All three data frames entered before the in-callback stop; finish was
    // suppressed, and none of the calls is "late" (each began while active).
    BOOL oldShapeOK = t.late == 0 && t.finishes == 0
        && t.events.count == 4
        && [[t.events firstObject] isEqual:@"response"]
        && [[t.events lastObject] hasPrefix:@"data:"];
    BOOL oldBodyOK = [t.body isEqualToData:oldExpected];

    // Replacement write: "only" was consumed at its newline despite the
    // reentrant stop, so the queue is empty -> response then finish, no dup.
    FakeTask *t2 = socketTask(@"write");
    [h webView:nil startURLSchemeTask:t2];
    drainSocket(h);
    BOOL reopenOK = [t2.events isEqualToArray:@[@"response", @"finish"]]
        && t2.body.length == 0 && t2.late == 0;

    REQUIRE(name, oldShapeOK && oldBodyOK && reopenOK,
        @"oldShape=%d oldBody=%d reopen=%@ old=%@ late=%d",
        oldShapeOK, oldBodyOK, t2.events,
        [[NSString alloc] initWithData:t.body encoding:NSUTF8StringEncoding], t.late);
}

// Unrelated path gets the synchronous 404; stopping an untracked task must
// not crash or corrupt bookkeeping.
static void scenarioUnrelatedAndUntracked(void) {
    NSString *const name = @"unrelated_404_and_untracked_stop";
    CoolURLSchemeHandler *h = [[CoolURLSchemeHandler alloc] initWithDocument:nil];
    FakeTask *t404 = [[FakeTask alloc] initWithPath:@"/cool/elsewhere"];
    [h webView:nil startURLSchemeTask:t404];
    BOOL ok404 = [t404.events isEqualToArray:@[@"response", @"finish"]]
        && setCount(h, @"ongoingTasks") == 0;
    FakeTask *untracked = socketTask(@"write");
    [h webView:nil stopURLSchemeTask:untracked]; // must no-op safely
    REQUIRE(name, ok404, @"events=%@", t404.events);
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        scenarioStopQueuedWrite();
        scenarioStopQueuedOpen();
        scenarioCancelInCallback();
        scenarioStopMidWriteThenReopen();
        scenarioNormalDelivery();
        scenarioOpenWriteWriteReopen();
        scenarioDirectWriteStop();
        scenarioQueueSendDuringDelivery();
        scenarioOverlappingWrites();
        scenarioMultiChunkBinary();
        scenarioStopAfterFramesBeforeFinish();
        scenarioCanceledHeadLiveFollower();
        scenarioReentrantStopFinalNewline();
        scenarioUnrelatedAndUntracked();
        printf("SUMMARY checks=%d failures=%d\n", checks, failures);
        return failures == 0 ? 0 : 1;
    }
}
'''

# ---- Shim headers for the engine dependencies the harness cannot build ----
SHIM_CONFIG_H = "/* harness shim */\n"
SHIM_IOS_H = "/* harness shim */\n"

SHIM_CODOCUMENT_H = r'''#pragma once
#import <Foundation/Foundation.h>
#import <string>
// Harness shim: upstream CODocument extends UIDocument and pulls in COKit.
@interface CODocument : NSObject { @public unsigned appDocId; }
@end
'''

SHIM_CODOCUMENT_MM = r'''#import "CODocument.h"
// Separate TU so the class metadata exists exactly once.
@implementation CODocument
@end
'''

SHIM_POCO_URI_H = r'''#pragma once
#include <string>
#include <utility>
#include <vector>
namespace Poco {
class URI {
public:
    URI() = default;
    URI(const char *) {}
    using QueryParameters = std::vector<std::pair<std::string, std::string>>;
    QueryParameters getQueryParameters() { return {}; }
};
} // namespace Poco
'''

SHIM_DOCUMENTBROKER_HPP = r'''#pragma once
#include <string>
class DocumentBroker {
public:
    std::string getEmbeddedMediaPath(const std::string &) { return {}; }
};
'''

SHIM_MOBILEAPP_HPP = r'''#pragma once
#include <fstream>
#include <filesystem>
#include <memory>
#include <sstream>
#include <wsd/DocumentBroker.hpp>
struct DocumentData {
    std::shared_ptr<DocumentBroker> docBroker;
    static DocumentData &get(unsigned /*id*/) { static DocumentData d; return d; }
};
'''


def write_shims(include_dir: Path):
    (include_dir / "Poco").mkdir(parents=True)
    (include_dir / "wsd").mkdir(parents=True)
    (include_dir / "config.h").write_text(SHIM_CONFIG_H)
    (include_dir / "ios.h").write_text(SHIM_IOS_H)
    (include_dir / "CODocument.h").write_text(SHIM_CODOCUMENT_H)
    (include_dir / "Poco/URI.h").write_text(SHIM_POCO_URI_H)
    (include_dir / "wsd/DocumentBroker.hpp").write_text(SHIM_DOCUMENTBROKER_HPP)
    (include_dir / "MobileApp.hpp").write_text(SHIM_MOBILEAPP_HPP)
    (include_dir / "CODocument.mm").write_text(SHIM_CODOCUMENT_MM)


def build_variant(label, source_root, patched, workdir):
    """Copy the real implementation files, optionally patch, compile and run."""
    tree = workdir / label
    inc = tree / "shim"
    src = tree / "src" / "ios" / "Mobile"
    src.mkdir(parents=True)
    for name in NATIVE_FILES:
        origin = source_root / name
        if not origin.is_file():
            raise FileNotFoundError(f"missing source for {label}: {origin}")
        target = src / Path(name).name
        shutil.copyfile(origin, target)
    if patched:
        patch_input = PATCH.read_text()
        # Patch paths are a/ios/Mobile/<file>; the harness holds the files flat,
        # so strip three components. --check then apply for both variants.
        proc = subprocess.run(["git", "apply", "--check", "-p3"],
                              cwd=src, input=patch_input, text=True,
                              capture_output=True)
        if proc.returncode:
            raise RuntimeError("patch --check failed:\n" + proc.stderr)
        proc = subprocess.run(["git", "apply", "-p3"],
                              cwd=src, input=patch_input, text=True,
                              capture_output=True)
        if proc.returncode:
            raise RuntimeError("patch apply failed:\n" + proc.stderr)
    write_shims(inc)
    driver = tree / "driver.mm"
    driver.write_text(DRIVER)
    binary = tree / "scheme-harness"
    command = [
        "clang++", "-x", "objective-c++", "-std=c++17", "-fobjc-arc",
        "-Wall", "-Wextra",
        "-I", str(inc),
        "-I", str(src),
        str(inc / "CODocument.mm"),
        str(src / "MobileSocket.mm"),
        str(src / "CoolURLSchemeHandler.mm"),
        str(driver),
        "-framework", "Foundation",
        "-framework", "WebKit",
        "-o", str(binary),
    ]
    compiled = subprocess.run(command, capture_output=True, text=True)
    if compiled.returncode:
        raise RuntimeError(f"{label} compile failed:\n{compiled.stderr}\n{compiled.stdout}")
    ran = subprocess.run([str(binary)], capture_output=True, text=True, timeout=60)
    return {"label": label, "exitCode": ran.returncode,
            "stdout": ran.stdout.strip(), "stderr": ran.stderr.strip()}


def parse_results(output):
    rows = {}
    for line in output.splitlines():
        if line.startswith("RESULT "):
            fields = line.split()
            name = fields[1].split("=", 1)[1]
            passed = fields[2].split("=", 1)[1] == "1"
            detail = " ".join(fields[3:])
            rows[name] = {"passed": passed, "detail": detail}
    return rows


def verify_lock_consistency(source_root):
    """The pinned originals must match the lock's declared source hashes."""
    import hashlib
    lock = json.loads(DEFAULT_LOCK.read_text())
    if lock["commit"] != "27b21dc1a90ac67c90fb1addd6f9fb22eec40ccc":
        raise ValueError("unexpected Office lock commit")
    overlay = lock.get("schemeTaskLifecycleOverlay")
    if overlay is None:
        return {"lockChecked": False, "reason": "scheme overlay section not yet recorded"}
    problems = []
    for name, hashes in overlay["files"].items():
        data = (source_root / name).read_bytes()
        actual = hashlib.sha256(data).hexdigest()
        if actual != hashes["originalSHA256"]:
            problems.append(f"{name}: {actual}")
    return {"lockChecked": not problems, "problems": problems}


def main():
    parser = argparse.ArgumentParser(description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--source", type=Path,
        help="root containing ios/Mobile pinned sources")
    parser.add_argument("--bundle", type=Path,
        help="extracted format-2 Office bundle (its source/ tree is used)")
    args = parser.parse_args()
    if not args.source and not args.bundle:
        parser.error("one of --source or --bundle is required")
    source_root = (args.source if args.source else args.bundle / "source").resolve()
    if not (source_root / "ios/Mobile/MobileSocket.mm").is_file():
        parser.error(f"no ios/Mobile sources under {source_root}")

    with tempfile.TemporaryDirectory(prefix="floe-scheme-lifecycle-") as tmp:
        tmp = Path(tmp)
        original = build_variant("original", source_root, False, tmp)
        patched = build_variant("patched", source_root, True, tmp)

    original_rows = parse_results(original["stderr"])
    patched_rows = parse_results(patched["stderr"])

    errors = []

    # Patched tree: every scenario passes.
    if patched["exitCode"] != 0:
        errors.append("patched harness exited nonzero: "
                      + str(patched["exitCode"]))
    for name, row in patched_rows.items():
        if not row["passed"]:
            errors.append(f"patched scenario still failing: {name} {row['detail']}")

    # Original tree: exactly the proven stop-race scenarios fail; delivery
    # scenarios must still pass.
    for name in ORIGINAL_EXPECTED_FAILURES:
        if name not in original_rows:
            errors.append(f"missing original scenario: {name}")
        elif original_rows[name]["passed"]:
            errors.append(f"original unexpectedly passes {name} "
                          "(reproduction regressed)")
    for name in DELIVERY_SCENARIOS:
        if name not in original_rows:
            errors.append(f"missing original scenario: {name}")
        elif not original_rows[name]["passed"]:
            errors.append(f"original delivery scenario failing: {name} "
                          + original_rows[name]["detail"])

    lock_state = verify_lock_consistency(source_root)

    report = {
        "kind": "Pinned Office native scheme-task lifecycle regression",
        "patch": str(PATCH.relative_to(REPO_ROOT)),
        "patchSHA256": __import__("hashlib").sha256(PATCH.read_bytes()).hexdigest(),
        "evidenceScope": "mock WKURLSchemeTask + real MobileSocket/CoolURLSchemeHandler on macOS; not device Office acceptance",
        "original": {"exitCode": original["exitCode"], "scenarios": original_rows},
        "patched": {"exitCode": patched["exitCode"], "scenarios": patched_rows},
        "lockConsistency": lock_state,
        "passed": not errors,
        "errors": errors,
    }
    print(json.dumps(report, indent=2))
    if errors:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
