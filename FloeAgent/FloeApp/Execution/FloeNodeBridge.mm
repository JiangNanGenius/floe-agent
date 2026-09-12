#import "FloeNodeBridge.h"
#import <unistd.h>
#import <fcntl.h>
#import <pthread.h>
#include <atomic>
#include <string>
#include <vector>
#if __has_include(<NodeMobile/NodeMobile.h>)
#import <NodeMobile/NodeMobile.h>
#define FLOE_HAS_NODE 1
#else
#define FLOE_HAS_NODE 0
#endif

namespace {
struct Host {
    NSLock *serial = [NSLock new];
    NSCondition *condition = [NSCondition new];
    int commands = -1;
    int results = -1;
    std::atomic_bool started{false};
    std::atomic_bool alive{false};
    std::atomic_bool ready{false};
    NSString *activeID = nil;
    NSString *environmentID = nil;
    NSDictionary *response = nil;
};
Host &host() { static Host value; return value; }

bool send(NSDictionary *message) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:message options:0 error:nil];
    if (!data || data.length > 2 * 1024 * 1024) return false;
    NSMutableData *line = [data mutableCopy];
    [line appendBytes:"\n" length:1];
    const uint8_t *bytes = (const uint8_t *)line.bytes;
    NSUInteger offset = 0;
    while (offset < line.length) {
        ssize_t count = write(host().commands, bytes + offset, line.length - offset);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return false;
        offset += count;
    }
    return true;
}

void receive() {
    auto &h = host();
    std::string buffer;
    char chunk[16384];
    ssize_t count;
    while ((count = read(h.results, chunk, sizeof(chunk))) > 0) {
        buffer.append(chunk, count);
        if (buffer.size() > 3 * 1024 * 1024) break;
        size_t newline;
        while ((newline = buffer.find('\n')) != std::string::npos) {
            @autoreleasepool {
                NSData *data = [NSData dataWithBytes:buffer.data() length:newline];
                NSDictionary *reply = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                [h.condition lock];
                if ([reply isKindOfClass:NSDictionary.class]) {
                    if ([reply[@"status"] isEqual:@"ready"]) h.ready = true;
                    else if ([reply[@"id"] isEqual:h.activeID]) {
                        h.response = reply;
                        h.activeID = nil;
                        h.environmentID = nil;
                    }
                }
                [h.condition broadcast]; [h.condition unlock];
            }
            buffer.erase(0, newline + 1);
        }
    }
    [h.condition lock]; h.alive = false; [h.condition broadcast]; [h.condition unlock];
}

bool start() {
    auto &h = host();
    if (h.started) return h.alive && h.ready;
    h.started = true; // node_start may only ever run once in this process.
#if FLOE_HAS_NODE
    NSString *script = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"NodeTools/host.cjs"];
    if (![NSFileManager.defaultManager fileExistsAtPath:script]) return false;
    int commands[2], results[2];
    if (pipe(commands) != 0) return false;
    if (pipe(results) != 0) { close(commands[0]); close(commands[1]); return false; }
    h.commands = commands[1]; h.results = results[0];
    fcntl(h.commands, F_SETNOSIGPIPE, 1);
    NSArray<NSString *> *args = @[@"node", script, [NSString stringWithFormat:@"%d", commands[0]], [NSString stringWithFormat:@"%d", results[1]]];
    const int commandReadFD = commands[0], resultWriteFD = results[1];
    h.alive = true;
    [NSThread detachNewThreadWithBlock:^{ @autoreleasepool { receive(); } }];
    [NSThread detachNewThreadWithBlock:^{
        @autoreleasepool {
            std::vector<char *> argv;
            for (NSString *arg in args) argv.push_back(strdup(arg.UTF8String));
            argv.push_back(nullptr);
            node_start((int)args.count, argv.data());
            for (char *arg : argv) free(arg);
            close(commandReadFD); close(resultWriteFD);
            [h.condition lock]; h.alive = false; [h.condition broadcast]; [h.condition unlock];
        }
    }];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:15];
    [h.condition lock];
    while (h.alive && !h.ready && [deadline timeIntervalSinceNow] > 0) [h.condition waitUntilDate:deadline];
    bool ready = h.ready && h.alive;
    [h.condition unlock];
    return ready;
#else
    return false;
#endif
}
NSString *decode(NSDictionary *response, NSString *key) {
    NSString *value = [response[key] isKindOfClass:NSString.class] ? response[key] : @"";
    if (![response[@"encoding"] isEqual:@"base64"]) return value;
    NSData *data = [[NSData alloc] initWithBase64EncodedString:value options:0];
    return [[NSString alloc] initWithData:data ?: NSData.data encoding:NSUTF8StringEncoding] ?: @"";
}
}

BOOL FloeNodeRuntimeAvailable(void) {
    if (!FLOE_HAS_NODE || (host().started && !host().alive)) return NO;
    NSString *root = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"NodeTools"];
    for (NSString *file in @[@"host.cjs", @"worker.cjs", @"worker-preload.cjs"]) {
        if (![NSFileManager.defaultManager fileExistsAtPath:[root stringByAppendingPathComponent:file]]) return NO;
    }
    return YES;
}
BOOL FloeNodeHasActiveTask(NSString *environmentID) {
    auto &h = host(); [h.condition lock];
    BOOL active = h.activeID != nil && [h.environmentID isEqual:environmentID];
    [h.condition unlock]; return active;
}
NSString *FloeNodeBundledToolPath(NSString *command) {
    NSDictionary *paths = @{@"npm": @"npm/bin/npm-cli.js", @"npx": @"npm/bin/npx-cli.js", @"pnpm": @"pnpm/bin/pnpm.cjs", @"pnpx": @"pnpm/bin/pnpx.cjs", @"yarn": @"yarn/bin/yarn.js"};
    NSString *relative = paths[command];
    if (!relative) return nil;
    NSString *path = [[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"NodeTools"] stringByAppendingPathComponent:relative];
    return [NSFileManager.defaultManager fileExistsAtPath:path] ? path : nil;
}
FloeNodeBridgeStatus FloeNodeRun(NSString *entryScript, NSArray<NSString *> *arguments, NSString *workingDirectory,
    NSDictionary<NSString *, NSString *> *environment, NSData *stdinData, NSTimeInterval timeout, NSUInteger maxOutputBytes,
    BOOL (^shouldCancel)(void), NSString **outStdout, NSString **outStderr, int32_t *outExitCode, BOOL *outTruncated) {
    if (outTruncated) *outTruncated = NO;
    if (!FloeNodeRuntimeAvailable()) return FloeNodeBridgeStatusUnavailable;
    auto &h = host();
    while (![h.serial tryLock]) {
        if (shouldCancel && shouldCancel()) return FloeNodeBridgeStatusCancelled;
        [NSThread sleepForTimeInterval:0.02];
    }
    @try {
        if (shouldCancel && shouldCancel()) return FloeNodeBridgeStatusCancelled;
        if (!start()) return FloeNodeBridgeStatusUnavailable;
        [h.condition lock];
        if (h.activeID) { [h.condition unlock]; return FloeNodeBridgeStatusUnavailable; }
        NSString *id = NSUUID.UUID.UUIDString;
        h.activeID = id; h.environmentID = environment[@"FLOE_ENVIRONMENT_ID"]; h.response = nil;
        [h.condition unlock];
        NSTimeInterval boundedTimeout = MIN(600, MAX(0.001, timeout));
        NSMutableDictionary *job = [@{@"id": id, @"args": arguments, @"cwd": workingDirectory, @"env": environment,
            @"stdin": [stdinData ?: NSData.data base64EncodedStringWithOptions:0], @"timeoutMs": @((NSInteger)(boundedTimeout * 1000)),
            @"maxOutputBytes": @(MIN(1024 * 1024, MAX(1, maxOutputBytes)))} mutableCopy];
        if (entryScript.length) job[@"entry"] = entryScript;
        if (!send(job)) {
            // A partial request may still be in flight: retain active ownership.
            return FloeNodeBridgeStatusUnavailable;
        }
        bool cancelled = false, deadlineSent = false;
        double cancellationDeadline = 0;
        double deadline = NSProcessInfo.processInfo.systemUptime + boundedTimeout;
        while (true) {
            [h.condition lock];
            NSDictionary *response = h.response;
            bool alive = h.alive;
            [h.condition unlock];
            if (response) {
                if (outStdout) *outStdout = decode(response, @"stdout");
                if (outStderr) *outStderr = decode(response, @"stderr");
                if (outExitCode) *outExitCode = [response[@"code"] intValue];
                if (outTruncated) *outTruncated = [response[@"truncated"] boolValue];
                if (cancelled) return FloeNodeBridgeStatusCancelled;
                if (deadlineSent || [response[@"status"] isEqual:@"timedOut"]) return FloeNodeBridgeStatusTimedOut;
                if ([response[@"status"] isEqual:@"cancelled"]) return FloeNodeBridgeStatusCancelled;
                return [response[@"status"] isEqual:@"ok"] ? FloeNodeBridgeStatusOK : FloeNodeBridgeStatusUnavailable;
            }
            if (!alive) return FloeNodeBridgeStatusUnavailable;
            if (!cancelled && shouldCancel && shouldCancel()) { cancelled = true; cancellationDeadline = NSProcessInfo.processInfo.systemUptime + 10; send(@{@"cancel": id}); }
            double now = NSProcessInfo.processInfo.systemUptime;
            if (!deadlineSent && now > deadline) { deadlineSent = true; send(@{@"cancel": id}); }
            if (now > deadline + 10 || (cancelled && now > cancellationDeadline)) return cancelled ? FloeNodeBridgeStatusCancelled : FloeNodeBridgeStatusTimedOut;
            [h.condition lock]; [h.condition waitUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.02]]; [h.condition unlock];
        }
    } @finally { [h.serial unlock]; }
}
