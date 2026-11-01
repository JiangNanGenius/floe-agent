#import <Foundation/Foundation.h>
#import "BridgeEnginePrivateShims.h"

@interface FGApp : NSObject
@property(copy) id bundleID;
@end
@implementation FGApp
@end
@interface FGElement : NSObject
@property int32_t processIdentifier;
@end
@implementation FGElement
@end
@interface FGTracker : NSObject
@property(copy) NSDictionary<NSNumber *, id> *apps;
- (id)monitoredApplicationWithProcessIdentifier:(int32_t)pid;
@end
@implementation FGTracker
- (id)monitoredApplicationWithProcessIdentifier:(int32_t)pid { return self.apps[@(pid)]; }
@end
@interface FGClient : NSObject
@property(copy) id activeForegroundApplications;
@property(strong) id applicationProcessTracker;
@end
@implementation FGClient
@end
@interface FGLegacyClient : NSObject
@property(copy) id activeApplications;
@property(strong) id applicationProcessTracker;
@end
@implementation FGLegacyClient
@end
@interface FGDevice : NSObject
@property(strong) id accessibilityInterface;
@property(strong) id system;
@end
@implementation FGDevice
@end
@interface FGWrongSignature : NSObject
- (NSInteger)activeForegroundApplications;
@end
@implementation FGWrongSignature
- (NSInteger)activeForegroundApplications { return 42; }
@end
@interface FGThrowingClient : NSObject
- (id)activeForegroundApplications;
@end
@implementation FGThrowingClient
- (id)activeForegroundApplications { @throw [NSException exceptionWithName:@"fixture" reason:nil userInfo:nil]; }
@end

@interface FGWrongPID : NSObject
- (double)processIdentifier;
@end
@implementation FGWrongPID
- (double)processIdentifier { return 123; }
@end
@interface FGWrongTracker : NSObject
- (id)monitoredApplicationWithProcessIdentifier:(double)pid;
@end
@implementation FGWrongTracker
- (id)monitoredApplicationWithProcessIdentifier:(double)pid { return [NSObject new]; }
@end

static NSUInteger checks;
static void Check(BOOL value, NSString *name) {
    checks++;
    if (!value) { fprintf(stderr, "FAIL %s\n", name.UTF8String); exit(1); }
}
static FGApp *App(id bundle) { FGApp *a=[FGApp new]; a.bundleID=bundle; return a; }
static NSString *Resolve(FGDevice *device, NSDictionary *states) {
    return BRForegroundBundleIDForTesting(device, ^NSInteger(NSString *bundle) {
        return [states[bundle] integerValue];
    });
}
static void Reason(NSString *expected) {
    NSDictionary *d=BRForegroundHelperLastDiagnostic();
    Check([d[@"reason_code"] isEqual:expected], expected);
    Check([NSJSONSerialization isValidJSONObject:d], @"diagnostic JSON safe");
    NSData *json=[NSJSONSerialization dataWithJSONObject:d options:0 error:nil];
    NSString *text=[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    Check(![text containsString:@"com.example"] && ![text containsString:@"com.apple"], @"diagnostic excludes IDs");
}
int main(void) {
    @autoreleasepool {
        FGDevice *device=[FGDevice new]; FGClient *client=[FGClient new]; device.accessibilityInterface=client;
        FGApp *settings=App(@"com.apple.Preferences"), *shell=App(@"com.apple.springboard");
        NSDictionary *states=@{@"com.apple.Preferences":@4, @"com.apple.springboard":@4};
        client.activeForegroundApplications=@[shell,settings];
        Check([Resolve(device,states) isEqual:settings.bundleID], @"current monitored apps resolve unique foreground");
        Reason(@"unique_foreground");
        Check([BRForegroundHelperLastDiagnostic()[@"source"] isEqual:@"accessibility_foreground"], @"current API selected");
        client.activeForegroundApplications=@[settings,App(@"com.example.other")];
        Check(Resolve(device,@{@"com.apple.Preferences":@4,@"com.example.other":@4})==nil, @"split view refused"); Reason(@"multiple_foreground");
        client.activeForegroundApplications=@[settings,App(@"COM.APPLE.AUTHKITUI")];
        Check(Resolve(device,@{@"com.apple.Preferences":@4,@"COM.APPLE.AUTHKITUI":@4})==nil, @"authorization conflict case-insensitive refusal"); Reason(@"authorization_foreground");
        client.activeForegroundApplications=@[settings];
        Check(Resolve(device,@{@"com.apple.Preferences":@0})==nil, @"unknown state refused"); Reason(@"state_unknown");
        Check(Resolve(device,@{@"com.apple.Preferences":@3})==nil, @"background refused");
        client.activeForegroundApplications=@[App(@42)];
        Check(Resolve(device,@{})==nil, @"nonstring identity refused"); Reason(@"identity_unknown");
        client.activeForegroundApplications=@[App(@"")]; Check(Resolve(device,@{})==nil,@"empty identity refused");
        client.activeForegroundApplications=@[]; Check(Resolve(device,@{})==nil,@"empty set refused"); Reason(@"applications_unknown");
        client.activeForegroundApplications=@42; Check(Resolve(device,@{})==nil,@"wrong array type refused");
        client.activeForegroundApplications=@[shell]; Check(Resolve(device,states)==nil,@"shell alone never ordinary"); Reason(@"no_ordinary_foreground");
        FGApp *owner=App(@"Custom.Resigned.Bridge"); client.activeForegroundApplications=@[owner];
        Check([Resolve(device,@{@"Custom.Resigned.Bridge":@4}) isEqual:owner.bundleID], @"owner identity preserved for downstream hard denial");
        FGLegacyClient *legacy=[FGLegacyClient new]; FGTracker *tracker=[FGTracker new]; FGElement *ax=[FGElement new]; ax.processIdentifier=123;
        legacy.activeApplications=@[ax]; tracker.apps=@{@123:settings}; legacy.applicationProcessTracker=tracker; device.accessibilityInterface=legacy;
        Check([Resolve(device,states) isEqual:settings.bundleID],@"legacy AX PID resolves through tracker");
        Check([BRForegroundHelperLastDiagnostic()[@"source"] isEqual:@"accessibility_active"],@"legacy path selected");
        tracker.apps=@{}; Check(Resolve(device,states)==nil,@"missing tracker identity refused");
        legacy.activeApplications=@[[FGWrongPID new]]; Check(Resolve(device,states)==nil,@"wrong PID ABI refused");
        legacy.activeApplications=@[ax]; legacy.applicationProcessTracker=[FGWrongTracker new];
        Check(Resolve(device,states)==nil,@"wrong tracker argument ABI refused");
        device.accessibilityInterface=[FGWrongSignature new]; device.system=nil;
        Check(Resolve(device,states)==nil,@"scalar getter signature refused without invocation");
        device.accessibilityInterface=[FGThrowingClient new]; Check(Resolve(device,states)==nil,@"exception refuses");
        device.accessibilityInterface=nil; device.system=client; client.activeForegroundApplications=@[settings];
        Check([Resolve(device,states) isEqual:settings.bundleID],@"system monitored API fallback");
        Check([BRForegroundHelperLastDiagnostic()[@"source"] isEqual:@"system_foreground"],@"system path selected");
        device.accessibilityInterface=[FGClient new];
        Check(Resolve(device,states)==nil,@"present but unknown preferred API cannot fall back to favorable result");
        printf("FOREGROUND-HELPER PASS checks=%lu\n", (unsigned long)checks);
    }
    return 0;
}
