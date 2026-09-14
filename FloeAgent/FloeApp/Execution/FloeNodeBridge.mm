#import "FloeNodeBridge.h"
#import "FloeTLSConfiguration.h"
#import <unistd.h>
#import <fcntl.h>
#import <pthread.h>
#include <atomic>
#include <string>
#include <vector>
#include <memory>
#include <poll.h>
#if __has_include(<NodeMobile/NodeMobile.h>)
#import <NodeMobile/NodeMobile.h>
#define FLOE_HAS_NODE 1
#else
#define FLOE_HAS_NODE 0
#endif

namespace {
// A private nonblocking pipe prevents a Worker filesystem read from pinning a
// libuv thread forever. The pump owns its descriptors until it has really stopped.
struct InputPipe {
    int source = -1, reader = -1, writer = -1;
    std::atomic_bool stopped{false};
    ~InputPipe() {
        if (source >= 0) close(source);
        if (reader >= 0) close(reader);
        if (writer >= 0) close(writer);
    }
    static std::shared_ptr<InputPipe> create(int borrowed) {
        auto input = std::make_shared<InputPipe>();
        input->source = dup(borrowed);
        int descriptors[2];
        if (input->source < 0 || pipe(descriptors) != 0) return nullptr;
        input->reader = descriptors[0]; input->writer = descriptors[1];
        fcntl(input->reader, F_SETFL, fcntl(input->reader, F_GETFL) | O_NONBLOCK);
        fcntl(input->writer, F_SETFL, fcntl(input->writer, F_GETFL) | O_NONBLOCK);
        fcntl(input->writer, F_SETNOSIGPIPE, 1);
        [NSThread detachNewThreadWithBlock:^{
            @autoreleasepool {
                char bytes[4096];
                while (!input->stopped) {
                    pollfd source{input->source, POLLIN, 0};
                    if (poll(&source, 1, 20) <= 0) continue;
                    if (source.revents & (POLLERR | POLLNVAL)) break;
                    ssize_t count = read(input->source, bytes, sizeof(bytes));
                    if (count < 0 && (errno == EINTR || errno == EAGAIN)) continue;
                    if (count <= 0) break;
                    ssize_t offset = 0;
                    while (offset < count && !input->stopped) {
                        pollfd target{input->writer, POLLOUT, 0};
                        if (poll(&target, 1, 20) <= 0) continue;
                        ssize_t written = write(input->writer, bytes + offset, count - offset);
                        if (written < 0 && (errno == EINTR || errno == EAGAIN)) continue;
                        if (written <= 0) { input->stopped = true; break; }
                        offset += written;
                    }
                }
                close(input->writer); input->writer = -1; // EOF after buffered data.
            }
        }];
        return input;
    }
};
struct Host {
    NSLock *serial = [NSLock new];
    NSLock *startup = [NSLock new];
    NSLock *writer = [NSLock new];
    NSMutableDictionary<NSString *, NSDictionary *> *controlReplies = [NSMutableDictionary new];
    NSMutableSet<NSString *> *pendingControls = [NSMutableSet new];
    NSMutableDictionary<NSString *, NSString *> *serviceEnvironments = [NSMutableDictionary new];
    NSCondition *condition = [NSCondition new];
    int commands = -1;
    int results = -1;
    std::shared_ptr<InputPipe> activeInput;
    std::atomic_bool started{false};
    std::atomic_bool alive{false};
    std::atomic_bool ready{false};
    NSString *activeID = nil;
    NSString *environmentID = nil;
    NSDictionary *response = nil;
    NSString *version = nil;
};
Host &host() { static Host value; return value; }

bool send(NSDictionary *message) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:message options:0 error:nil];
    if (!data || data.length > 2 * 1024 * 1024) return false;
    NSMutableData *line = [data mutableCopy];
    [line appendBytes:"\n" length:1];
    auto &h = host();
    const double deadline = NSProcessInfo.processInfo.systemUptime + 5;
    while (![h.writer tryLock]) {
        if (NSProcessInfo.processInfo.systemUptime >= deadline) return false;
        [NSThread sleepForTimeInterval:0.01];
    }
    @try {
        const uint8_t *bytes = (const uint8_t *)line.bytes;
        NSUInteger offset = 0;
        while (offset < line.length) {
            pollfd target{h.commands, POLLOUT, 0};
            if (NSProcessInfo.processInfo.systemUptime >= deadline || h.commands < 0) break;
            if (poll(&target, 1, 20) <= 0) continue;
            ssize_t count = write(h.commands, bytes + offset, line.length - offset);
            if (count < 0 && (errno == EINTR || errno == EAGAIN)) continue;
            if (count <= 0) break;
            offset += count;
        }
        if (offset == line.length) return true;
        // A truncated frame cannot safely be followed by another request.
        // Closing the pipe makes the host stop every owned worker on EOF.
        if (h.commands >= 0) { close(h.commands); h.commands = -1; }
        return false;
    } @finally { [h.writer unlock]; }
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
                    if ([reply[@"status"] isEqual:@"ready"]) {
                        h.version = [reply[@"version"] isKindOfClass:NSString.class] ? reply[@"version"] : nil;
                        h.ready = true;
                    }
                    else if ([reply[@"event"] isEqual:@"serviceExited"]) {
                        [h.serviceEnvironments removeObjectForKey:reply[@"id"]];
                    } else if ([reply[@"id"] isKindOfClass:NSString.class] && [h.pendingControls containsObject:reply[@"id"]]) {
                        h.controlReplies[reply[@"id"]] = reply;
                    } else if ([reply[@"id"] isEqual:h.activeID]) {
                        h.response = reply;
                        h.activeID = nil;
                        h.environmentID = nil;
                        if (h.activeInput) { h.activeInput->stopped = true; h.activeInput.reset(); }
                    }
                }
                [h.condition broadcast]; [h.condition unlock];
            }
            buffer.erase(0, newline + 1);
        }
    }
    [h.condition lock]; h.alive = false; [h.condition broadcast]; [h.condition unlock];
}

bool startUnlocked(NSTimeInterval remaining) {
    auto &h = host();
    if (h.started) return h.alive && h.ready;
    h.started = true; // node_start may only ever run once in this process.
#if FLOE_HAS_NODE
    NSString *script = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"NodeTools/host.cjs"];
    if (![NSFileManager.defaultManager fileExistsAtPath:script]) return false;
    int commands[2], results[2];
    if (pipe(commands) != 0) return false;
    if (pipe(results) != 0) { close(commands[0]); close(commands[1]); return false; }
    // The persistent JS host must never leave a blocking fs.read in libuv's
    // global pool: process exit joins that pool even when no job is active.
    const int commandFlags = fcntl(commands[0], F_GETFL);
    if (commandFlags < 0 || fcntl(commands[0], F_SETFL, commandFlags | O_NONBLOCK) < 0) {
        close(commands[0]); close(commands[1]); close(results[0]); close(results[1]);
        return false;
    }
    h.commands = commands[1]; h.results = results[0];
    fcntl(h.commands, F_SETNOSIGPIPE, 1);
    fcntl(h.commands, F_SETFL, fcntl(h.commands, F_GETFL) | O_NONBLOCK);
    NSArray<NSString *> *args = @[@"node", script, [NSString stringWithFormat:@"%d", commands[0]], [NSString stringWithFormat:@"%d", results[1]]];
    const int commandReadFD = commands[0], resultWriteFD = results[1];
    // Node loads extra roots once at runtime initialization, not per Worker.
    NSString *caBundle = FloeTLSCertificateBundle();
    if (caBundle) setenv("NODE_EXTRA_CA_CERTS", caBundle.fileSystemRepresentation, 1);
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
            [h.condition lock]; h.alive = false;
            if (h.activeInput) { h.activeInput->stopped = true; h.activeInput.reset(); }
            h.activeID = nil; h.environmentID = nil;
            [h.serviceEnvironments removeAllObjects];
            [h.condition broadcast]; [h.condition unlock];
        }
    }];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:MIN(15, remaining)];
    [h.condition lock];
    while (h.alive && !h.ready && [deadline timeIntervalSinceNow] > 0) [h.condition waitUntilDate:deadline];
    bool ready = h.ready && h.alive;
    [h.condition unlock];
    return ready;
#else
    return false;
#endif
}
bool start(NSTimeInterval remaining) {
    auto &h = host();
    const double deadline = NSProcessInfo.processInfo.systemUptime + remaining;
    while (![h.startup tryLock]) {
        if (NSProcessInfo.processInfo.systemUptime >= deadline) return false;
        [NSThread sleepForTimeInterval:0.01];
    }
    @try { return startUnlocked(MAX(0.001, deadline - NSProcessInfo.processInfo.systemUptime)); }
    @finally { [h.startup unlock]; }
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
    BOOL active = (h.activeID != nil && [h.environmentID isEqual:environmentID]) ||
        [h.serviceEnvironments.allValues containsObject:environmentID];
    [h.condition unlock]; return active;
}
NSString *FloeNodeRuntimeVersion(void) {
    if (!FloeNodeRuntimeAvailable() || !start(10)) return nil;
    auto &h = host(); [h.condition lock];
    NSString *version = h.alive ? h.version : nil;
    [h.condition unlock]; return version;
}
NSArray<NSString *> *FloeNodeServiceIDs(NSString *environmentID) {
    auto &h = host(); [h.condition lock];
    NSMutableArray<NSString *> *ids = [NSMutableArray new];
    for (NSString *id in h.serviceEnvironments) {
        if ([h.serviceEnvironments[id] isEqual:environmentID]) [ids addObject:id];
    }
    [h.condition unlock]; return ids;
}
NSString *FloeNodeBundledToolPath(NSString *command) {
    NSDictionary *paths = @{@"npm": @"npm/bin/npm-cli.js", @"npx": @"npm/bin/npx-cli.js", @"pnpm": @"pnpm/bin/pnpm.cjs", @"pnpx": @"pnpm/bin/pnpx.cjs", @"yarn": @"yarn/bin/yarn.js"};
    NSString *relative = paths[command];
    if (!relative) return nil;
    NSString *path = [[NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"NodeTools"] stringByAppendingPathComponent:relative];
    return [NSFileManager.defaultManager fileExistsAtPath:path] ? path : nil;
}
FloeNodeBridgeStatus FloeNodeRun(NSString *entryScript, NSArray<NSString *> *arguments, NSString *workingDirectory,
    NSDictionary<NSString *, NSString *> *environment, NSData *stdinData, int stdinFileDescriptor, NSTimeInterval timeout, NSUInteger maxOutputBytes,
    BOOL (^shouldCancel)(void), NSString **outStdout, NSString **outStderr, int32_t *outExitCode, BOOL *outTruncated) {
    if (outTruncated) *outTruncated = NO;
    if (!FloeNodeRuntimeAvailable()) return FloeNodeBridgeStatusUnavailable;
    auto &h = host();
    const double deadline = NSProcessInfo.processInfo.systemUptime + MIN(600, MAX(0.001, timeout));
    while (![h.serial tryLock]) {
        if (NSProcessInfo.processInfo.systemUptime >= deadline) return FloeNodeBridgeStatusTimedOut;
        if (shouldCancel && shouldCancel()) return FloeNodeBridgeStatusCancelled;
        [NSThread sleepForTimeInterval:0.02];
    }
    @try {
        if (shouldCancel && shouldCancel()) return FloeNodeBridgeStatusCancelled;
        if (!start(MAX(0.001, deadline - NSProcessInfo.processInfo.systemUptime))) return FloeNodeBridgeStatusUnavailable;
        if (NSProcessInfo.processInfo.systemUptime >= deadline) return FloeNodeBridgeStatusTimedOut;
        [h.condition lock];
        if (h.activeID) { [h.condition unlock]; return FloeNodeBridgeStatusUnavailable; }
        auto input = stdinFileDescriptor >= 0 ? InputPipe::create(stdinFileDescriptor) : nullptr;
        if (stdinFileDescriptor >= 0 && !input) { [h.condition unlock]; return FloeNodeBridgeStatusUnavailable; }
        h.activeInput = input;
        const int inputFD = input ? input->reader : -1;
        NSString *id = NSUUID.UUID.UUIDString;
        h.activeID = id; h.environmentID = environment[@"FLOE_ENVIRONMENT_ID"]; h.response = nil;
        [h.condition unlock];
        NSTimeInterval boundedTimeout = MAX(0.001, deadline - NSProcessInfo.processInfo.systemUptime);
        NSMutableDictionary *job = [@{@"id": id, @"args": arguments, @"cwd": workingDirectory, @"env": environment,
            @"stdin": [stdinData ?: NSData.data base64EncodedStringWithOptions:0], @"timeoutMs": @((NSInteger)(boundedTimeout * 1000)),
            @"maxOutputBytes": @(MIN(1024 * 1024, MAX(1, maxOutputBytes)))} mutableCopy];
        if (entryScript.length) job[@"entry"] = entryScript;
        if (inputFD >= 0) job[@"stdinFD"] = @(inputFD);
        if (!send(job)) {
            // A partial request may still be in flight: retain active ownership.
            return FloeNodeBridgeStatusUnavailable;
        }
        bool cancelled = false, deadlineSent = false;
        double cancellationDeadline = 0;
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

NSDictionary *FloeNodeServiceCommand(NSDictionary *request, NSString *environmentID) {
    NSString *operation = request[@"service"];
    if (![operation isKindOfClass:NSString.class] || ![@[@"start", @"status", @"stop"] containsObject:operation] || !environmentID.length) {
        return @{@"status": @"invalid", @"stderr": @"An operation and owning environment are required"};
    }
    if (!FloeNodeRuntimeAvailable() || !start(10)) return @{@"status": @"unavailable"};
    auto &h = host();
    NSString *id = NSUUID.UUID.UUIDString;
    NSMutableDictionary *message = [request mutableCopy]; message[@"id"] = id;
    NSString *serviceID = [operation isEqual:@"start"] ? id : request[@"serviceID"];
    if (![serviceID isKindOfClass:NSString.class]) return @{@"status": @"invalid"};
    [h.condition lock];
    if ([operation isEqual:@"start"]) h.serviceEnvironments[id] = environmentID;
    else if (![h.serviceEnvironments[serviceID] isEqual:environmentID]) {
        [h.condition unlock]; return @{@"status": @"notFound"};
    }
    [h.pendingControls addObject:id];
    [h.condition unlock];
    bool sent = send(message);
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10];
    [h.condition lock];
    while (sent && h.alive && !h.controlReplies[id] && deadline.timeIntervalSinceNow > 0) {
        [h.condition waitUntilDate:deadline];
    }
    NSDictionary *response = h.controlReplies[id];
    if ([operation isEqual:@"start"] && response && ![response[@"status"] isEqual:@"started"]) {
        [h.serviceEnvironments removeObjectForKey:serviceID];
    }
    if (response && ![operation isEqual:@"start"] && ([@[@"stopped", @"notFound"] containsObject:response[@"status"]])) {
        [h.serviceEnvironments removeObjectForKey:serviceID];
    }
    [h.pendingControls removeObject:id]; [h.controlReplies removeObjectForKey:id];
    [h.condition unlock];
    // An uncertain start retains its environment ownership and ID, allowing
    // an explicit stop/reconciliation instead of releasing a live worker.
    return response ?: @{@"status": @"unknown", @"serviceID": serviceID};
}
