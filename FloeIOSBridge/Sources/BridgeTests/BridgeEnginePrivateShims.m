#import "BridgeEnginePrivateShims.h"
#import <UIKit/UIKit.h>
#import <XCTest/XCTest.h>
#import <dispatch/dispatch.h>
#import <notify.h>
#import <stdatomic.h>

#pragma mark - Safe invocation helpers

static id BRCallObject(id target, NSString *selectorName) {
    if (!target) { return nil; }
    SEL selector = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:selector]) { return nil; }
    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    if (!signature) { return nil; }
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.target = target;
    invocation.selector = selector;
    @try {
        [invocation invoke];
    } @catch (__unused NSException *exception) {
        return nil;
    }
    void *raw = NULL;
    [invocation getReturnValue:&raw];
    return (__bridge id)raw;
}

static int32_t BRCallInt32(id target, NSString *selectorName) {
    if (!target) { return 0; }
    SEL selector = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:selector]) { return 0; }
    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    if (!signature) { return 0; }
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.target = target;
    invocation.selector = selector;
    @try {
        [invocation invoke];
    } @catch (__unused NSException *exception) {
        return 0;
    }
    int32_t value = 0;
    [invocation getReturnValue:&value];
    return value;
}

static NSInteger BRCallInteger(id target, NSString *selectorName) {
    if (!target) { return 0; }
    SEL selector = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:selector]) { return 0; }
    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    if (!signature) { return 0; }
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.target = target;
    invocation.selector = selector;
    @try {
        [invocation invoke];
    } @catch (__unused NSException *exception) {
        return 0;
    }
    NSInteger value = 0;
    [invocation getReturnValue:&value];
    return value;
}

static BOOL BRCallBool1(id target, NSString *selectorName, id argument) {
    if (!target) { return NO; }
    SEL selector = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:selector]) { return NO; }
    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    if (!signature) { return NO; }
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.target = target;
    invocation.selector = selector;
    [invocation setArgument:&argument atIndex:2];
    @try {
        [invocation invoke];
    } @catch (__unused NSException *exception) {
        return NO;
    }
    BOOL value = NO;
    [invocation getReturnValue:&value];
    return value;
}

static BOOL BRCallBool2(id target, NSString *selectorName, id first, id second) {
    if (!target) { return NO; }
    SEL selector = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:selector]) { return NO; }
    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    if (!signature) { return NO; }
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.target = target;
    invocation.selector = selector;
    [invocation setArgument:&first atIndex:2];
    [invocation setArgument:&second atIndex:3];
    @try {
        [invocation invoke];
    } @catch (__unused NSException *exception) {
        return NO;
    }
    BOOL value = NO;
    [invocation getReturnValue:&value];
    return value;
}

static id BRAllocAndInit(id target, NSString *selectorName,
                         void (^configure)(NSInvocation *invocation)) {
    if (!target) { return nil; }
    SEL selector = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:selector]) { return nil; }
    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    if (!signature) { return nil; }
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.target = target;
    invocation.selector = selector;
    if (configure) { configure(invocation); }
    @try {
        [invocation invoke];
    } @catch (__unused NSException *exception) {
        return nil;
    }
    void *raw = NULL;
    [invocation getReturnValue:&raw];
    return (__bridge_transfer id)raw;
}

#pragma mark - Redacted typing

static Class BRPointerPathClass(void) {
    return NSClassFromString(@"XCPointerEventPath");
}

static Class BREventRecordClass(void) {
    return NSClassFromString(@"XCSynthesizedEventRecord");
}

BOOL BRRedactedTypingAvailable(void) {
    Class pathClass = BRPointerPathClass();
    Class recordClass = BREventRecordClass();
    if (!pathClass || !recordClass) { return NO; }
    SEL initSelector = NSSelectorFromString(@"initForTextInput");
    SEL typeSelector = NSSelectorFromString(@"typeText:atOffset:typingSpeed:shouldRedact:");
    id alloced = [pathClass alloc];
    BOOL pathOK = initSelector != NULL
        && [alloced respondsToSelector:initSelector]
        && [alloced methodSignatureForSelector:typeSelector] != nil;
    id record = [recordClass alloc];
    SEL recordInit = NSSelectorFromString(@"initWithName:");
    BOOL recordOK = recordInit != NULL
        && [record respondsToSelector:recordInit]
        && [record methodSignatureForSelector:NSSelectorFromString(@"addPointerEventPath:")] != nil
        && [record methodSignatureForSelector:NSSelectorFromString(@"synthesizeWithError:")] != nil;
    return pathOK && recordOK;
}

BOOL BRTypeTextRedacted(NSString *text, NSError **error) {
    if (error) { *error = nil; }
    if (!BRRedactedTypingAvailable()) { return NO; }
    id allocedPath = [BRPointerPathClass() alloc];
    id path = BRAllocAndInit(allocedPath, @"initForTextInput", nil);
    if (!path) { return NO; }
    SEL typeSelector = NSSelectorFromString(@"typeText:atOffset:typingSpeed:shouldRedact:");
    NSMethodSignature *typeSignature = [path methodSignatureForSelector:typeSelector];
    if (!typeSignature) { return NO; }
    NSInvocation *typeInvocation = [NSInvocation invocationWithMethodSignature:typeSignature];
    typeInvocation.target = path;
    typeInvocation.selector = typeSelector;
    NSString *textArgument = text ?: @"";
    double offset = 0;
    NSUInteger speed = 60;
    BOOL redact = YES;
    [typeInvocation setArgument:&textArgument atIndex:2];
    [typeInvocation setArgument:&offset atIndex:3];
    [typeInvocation setArgument:&speed atIndex:4];
    [typeInvocation setArgument:&redact atIndex:5];
    @try {
        [typeInvocation invoke];
    } @catch (NSException *exception) {
        if (error) {
            *error = [NSError errorWithDomain:@"org.floeagent.iosbridge.private"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                    exception.reason ?: @"typing path threw"}];
        }
        return NO;
    }

    NSString *name = @"FloeType";
    id allocedRecord = [BREventRecordClass() alloc];
    SEL recordInit = NSSelectorFromString(@"initWithName:");
    NSMethodSignature *recordSignature = [allocedRecord methodSignatureForSelector:recordInit];
    if (!recordSignature) { return NO; }
    NSInvocation *recordInvocation = [NSInvocation invocationWithMethodSignature:recordSignature];
    recordInvocation.target = allocedRecord;
    recordInvocation.selector = recordInit;
    [recordInvocation setArgument:&name atIndex:2];
    @try {
        [recordInvocation invoke];
    } @catch (__unused NSException *exception) {
        return NO;
    }
    void *rawRecord = NULL;
    [recordInvocation getReturnValue:&rawRecord];
    id record = (__bridge_transfer id)rawRecord;
    if (!record) { return NO; }

    SEL addSelector = NSSelectorFromString(@"addPointerEventPath:");
    NSMethodSignature *addSignature = [record methodSignatureForSelector:addSelector];
    if (!addSignature) { return NO; }
    NSInvocation *addInvocation = [NSInvocation invocationWithMethodSignature:addSignature];
    addInvocation.target = record;
    addInvocation.selector = addSelector;
    [addInvocation setArgument:&path atIndex:2];
    @try {
        [addInvocation invoke];
    } @catch (__unused NSException *exception) {
        return NO;
    }

    SEL synthSelector = NSSelectorFromString(@"synthesizeWithError:");
    NSMethodSignature *synthSignature = [record methodSignatureForSelector:synthSelector];
    if (!synthSignature) { return NO; }
    NSInvocation *synthInvocation = [NSInvocation invocationWithMethodSignature:synthSignature];
    synthInvocation.target = record;
    synthInvocation.selector = synthSelector;
    void *nullError = NULL;
    [synthInvocation setArgument:&nullError atIndex:2];
    @try {
        [synthInvocation invoke];
    } @catch (NSException *exception) {
        if (error) {
            *error = [NSError errorWithDomain:@"org.floeagent.iosbridge.private"
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey:
                                                    exception.reason ?: @"event synthesis threw"}];
        }
        return NO;
    }
    BOOL synthesized = NO;
    [synthInvocation getReturnValue:&synthesized];
    return synthesized;
}

#pragma mark - Continuous drag

BOOL BRContinuousDragAvailable(void) {
    Class pathClass = BRPointerPathClass();
    Class recordClass = BREventRecordClass();
    if (!pathClass || !recordClass) { return NO; }
    id path = [pathClass alloc];
    id record = [recordClass alloc];
    return [path methodSignatureForSelector:NSSelectorFromString(@"initForTouchAtPoint:offset:")] != nil
        && [path methodSignatureForSelector:NSSelectorFromString(@"pressDownAtOffset:")] != nil
        && [path methodSignatureForSelector:NSSelectorFromString(@"moveToPoint:atOffset:")] != nil
        && [path methodSignatureForSelector:NSSelectorFromString(@"liftUpAtOffset:")] != nil
        && [record methodSignatureForSelector:NSSelectorFromString(@"initWithName:")] != nil
        && [record methodSignatureForSelector:NSSelectorFromString(@"addPointerEventPath:")] != nil
        && [record methodSignatureForSelector:NSSelectorFromString(@"synthesizeWithError:")] != nil;
}

static BOOL BRInvokeDouble(id target, NSString *selectorName, double value) {
    SEL selector = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:selector]) { return NO; }
    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.target = target;
    invocation.selector = selector;
    [invocation setArgument:&value atIndex:2];
    @try {
        [invocation invoke];
    } @catch (__unused NSException *exception) {
        return NO;
    }
    return YES;
}

static BOOL BRInvokePointOffset(id target, NSString *selectorName,
                                CGPoint point, double value) {
    SEL selector = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:selector]) { return NO; }
    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.target = target;
    invocation.selector = selector;
    [invocation setArgument:&point atIndex:2];
    [invocation setArgument:&value atIndex:3];
    @try {
        [invocation invoke];
    } @catch (__unused NSException *exception) {
        return NO;
    }
    return YES;
}

BOOL BRContinuousDrag(NSArray<NSValue *> *points, NSTimeInterval duration, NSError **error) {
    if (error) { *error = nil; }
    if (!BRContinuousDragAvailable() || points.count < 2 || duration <= 0) { return NO; }

    CGPoint first = CGPointZero;
    [points.firstObject getValue:&first];
    id allocedPath = [BRPointerPathClass() alloc];
    SEL initSelector = NSSelectorFromString(@"initForTouchAtPoint:offset:");
    NSMethodSignature *initSignature = [allocedPath methodSignatureForSelector:initSelector];
    if (!initSignature) { return NO; }
    NSInvocation *initInvocation = [NSInvocation invocationWithMethodSignature:initSignature];
    initInvocation.target = allocedPath;
    initInvocation.selector = initSelector;
    double zero = 0;
    [initInvocation setArgument:&first atIndex:2];
    [initInvocation setArgument:&zero atIndex:3];
    @try {
        [initInvocation invoke];
    } @catch (__unused NSException *exception) {
        return NO;
    }
    void *rawPath = NULL;
    [initInvocation getReturnValue:&rawPath];
    id path = (__bridge_transfer id)rawPath;
    if (!path) { return NO; }

    if (!BRInvokeDouble(path, @"pressDownAtOffset:", 0)) { return NO; }
    NSUInteger last = points.count - 1;
    for (NSUInteger index = 1; index < points.count; index++) {
        CGPoint point = CGPointZero;
        [points[index] getValue:&point];
        double offset = duration * ((double)index / (double)last);
        if (!BRInvokePointOffset(path, @"moveToPoint:atOffset:", point, offset)) { return NO; }
    }
    if (!BRInvokeDouble(path, @"liftUpAtOffset:", duration)) { return NO; }

    id allocedRecord = [BREventRecordClass() alloc];
    NSString *name = @"FloeDrag";
    SEL recordInit = NSSelectorFromString(@"initWithName:");
    NSMethodSignature *recordSignature = [allocedRecord methodSignatureForSelector:recordInit];
    if (!recordSignature) { return NO; }
    NSInvocation *recordInvocation = [NSInvocation invocationWithMethodSignature:recordSignature];
    recordInvocation.target = allocedRecord;
    recordInvocation.selector = recordInit;
    [recordInvocation setArgument:&name atIndex:2];
    @try {
        [recordInvocation invoke];
    } @catch (__unused NSException *exception) {
        return NO;
    }
    void *rawRecord = NULL;
    [recordInvocation getReturnValue:&rawRecord];
    id record = (__bridge_transfer id)rawRecord;
    if (!record) { return NO; }

    SEL addSelector = NSSelectorFromString(@"addPointerEventPath:");
    NSMethodSignature *addSignature = [record methodSignatureForSelector:addSelector];
    if (!addSignature) { return NO; }
    NSInvocation *addInvocation = [NSInvocation invocationWithMethodSignature:addSignature];
    addInvocation.target = record;
    addInvocation.selector = addSelector;
    [addInvocation setArgument:&path atIndex:2];
    @try {
        [addInvocation invoke];
    } @catch (__unused NSException *exception) {
        return NO;
    }

    SEL synthSelector = NSSelectorFromString(@"synthesizeWithError:");
    NSMethodSignature *synthSignature = [record methodSignatureForSelector:synthSelector];
    if (!synthSignature) { return NO; }
    NSInvocation *synthInvocation = [NSInvocation invocationWithMethodSignature:synthSignature];
    synthInvocation.target = record;
    synthInvocation.selector = synthSelector;
    void *nullError = NULL;
    [synthInvocation setArgument:&nullError atIndex:2];
    @try {
        [synthInvocation invoke];
    } @catch (__unused NSException *exception) {
        return NO;
    }
    BOOL synthesized = NO;
    [synthInvocation getReturnValue:&synthesized];
    return synthesized;
}

#pragma mark - Lock state and button

enum {
    BRLockRawStateUnlocked = 0,
    BRLockRawStateLocked = 1,
    BRLockRawStateUnknown = 2,
};

// Start unknown, never "unlocked". A registered notify token whose current
// value has not been read successfully must keep input and frames refused.
static atomic_int BRLockRawValue = ATOMIC_VAR_INIT(BRLockRawStateUnknown);
static atomic_bool BRLockNotificationRegistered = ATOMIC_VAR_INIT(false);
static atomic_bool BRLockValueKnown = ATOMIC_VAR_INIT(false);
static int BRLockNotifyToken = 0;

static BOOL BRReadLockState(void) {
    uint64_t state = UINT64_MAX;
    int status = notify_get_state(BRLockNotifyToken, &state);
    if (status != NOTIFY_STATUS_OK || state == UINT64_MAX) {
        atomic_store(&BRLockRawValue, BRLockRawStateUnknown);
        atomic_store(&BRLockValueKnown, false);
        return NO;
    }
    atomic_store(&BRLockRawValue,
                 state != 0 ? BRLockRawStateLocked : BRLockRawStateUnlocked);
    atomic_store(&BRLockValueKnown, true);
    return YES;
}

static void BRRegisterLockNotification(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        int status = notify_register_dispatch("com.apple.springboard.lockstate",
                                              &BRLockNotifyToken,
                                              dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0),
                                              ^(int token) {
            uint64_t state = UINT64_MAX;
            int readStatus = notify_get_state(token, &state);
            if (readStatus != NOTIFY_STATUS_OK || state == UINT64_MAX) {
                // A failed callback read invalidates the previous value. Keep
                // the fail-closed unknown state until a later successful read.
                atomic_store(&BRLockRawValue, BRLockRawStateUnknown);
                atomic_store(&BRLockValueKnown, false);
                return;
            }
            atomic_store(&BRLockRawValue,
                         state != 0 ? BRLockRawStateLocked : BRLockRawStateUnlocked);
            atomic_store(&BRLockValueKnown, true);
        });
        atomic_store(&BRLockNotificationRegistered, status == NOTIFY_STATUS_OK);
        if (status == NOTIFY_STATUS_OK) {
            // The initial notification fires only on a change. Read the current
            // state once. If this read fails the state stays unknown (locked
            // for callers), not "unlocked".
            (void)BRReadLockState();
        }
    });
}

BOOL BRLockStateAvailable(void) {
    BRRegisterLockNotification();
    return atomic_load(&BRLockNotificationRegistered);
}

BOOL BRLockStateKnown(void) {
    BRRegisterLockNotification();
    return atomic_load(&BRLockValueKnown);
}

NSInteger BRLockRawState(void) {
    BRRegisterLockNotification();
    return (NSInteger)atomic_load(&BRLockRawValue);
}

BOOL BRIsLocked(void) {
    BRRegisterLockNotification();
    if (!atomic_load(&BRLockNotificationRegistered)) { return YES; }
    // Unknown is refusal, not an unlocked guess.
    return atomic_load(&BRLockRawValue) != BRLockRawStateUnlocked;
}

BOOL BRLockButtonAvailable(void) {
    Class deviceClass = NSClassFromString(@"XCUIDevice");
    if (!deviceClass) { return NO; }
    SEL sharedSelector = NSSelectorFromString(@"sharedDevice");
    if (![deviceClass respondsToSelector:sharedSelector]) { return NO; }
    id device = BRCallObject(deviceClass, @"sharedDevice");
    return device != nil
        && [device respondsToSelector:NSSelectorFromString(@"pressLockButton")];
}

BOOL BRPressLockButton(void) {
    Class deviceClass = NSClassFromString(@"XCUIDevice");
    if (!deviceClass) { return NO; }
    id device = BRCallObject(deviceClass, @"sharedDevice");
    SEL selector = NSSelectorFromString(@"pressLockButton");
    if (!device || ![device respondsToSelector:selector]) { return NO; }
    NSMethodSignature *signature = [device methodSignatureForSelector:selector];
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.target = device;
    invocation.selector = selector;
    @try {
        [invocation invoke];
    } @catch (__unused NSException *exception) {
        return NO;
    }
    return YES;
}

#pragma mark - Foreground app

BOOL BRForegroundHelperAvailable(void) {
    Class deviceClass = NSClassFromString(@"XCUIDevice");
    if (!deviceClass) { return NO; }
    id device = BRCallObject(deviceClass, @"sharedDevice");
    id client = BRCallObject(device, @"accessibilityInterface");
    return client != nil
        && [client respondsToSelector:NSSelectorFromString(@"activeApplications")];
}

NSInteger BRAppStateForBundleIdentifier(NSString *bundleIdentifier) {
    if (bundleIdentifier.length == 0) { return 0; }
    Class appClass = NSClassFromString(@"XCUIApplication");
    if (!appClass) { return 0; }
    id alloced = [appClass alloc];
    SEL selector = NSSelectorFromString(@"initWithBundleIdentifier:");
    if (![alloced respondsToSelector:selector]) { return 0; }
    NSMethodSignature *signature = [alloced methodSignatureForSelector:selector];
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.target = alloced;
    invocation.selector = selector;
    NSString *argument = bundleIdentifier;
    [invocation setArgument:&argument atIndex:2];
    @try {
        [invocation invoke];
    } @catch (__unused NSException *exception) {
        return 0;
    }
    void *rawApp = NULL;
    [invocation getReturnValue:&rawApp];
    id app = (__bridge_transfer id)rawApp;
    if (!app) { return 0; }
    return BRCallInteger(app, @"state");
}

BOOL BRAppStateAvailable(void) {
    Class appClass = NSClassFromString(@"XCUIApplication");
    return appClass != nil && [appClass instancesRespondToSelector:NSSelectorFromString(@"state")];
}

static NSString *BRBundleIDForElement(id element) {
    if (!element) { return nil; }
    NSString *identifier = BRCallObject(element, @"bundleIdentifier");
    if (identifier.length > 0) { return [identifier copy]; }
    identifier = BRCallObject(element, @"bundleID");
    if (identifier.length > 0) { return [identifier copy]; }
    int32_t pid = BRCallInt32(element, @"processIdentifier");
    if (pid <= 0) { return nil; }
    Class appClass = NSClassFromString(@"XCUIApplication");
    if (!appClass) { return nil; }
    id alloced = [appClass alloc];
    SEL selector = NSSelectorFromString(@"initWithProcessID:");
    if (![alloced respondsToSelector:selector]) { return nil; }
    NSMethodSignature *signature = [alloced methodSignatureForSelector:selector];
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    invocation.target = alloced;
    invocation.selector = selector;
    pid_t processID = (pid_t)pid;
    [invocation setArgument:&processID atIndex:2];
    @try {
        [invocation invoke];
    } @catch (__unused NSException *exception) {
        return nil;
    }
    void *rawApp = NULL;
    [invocation getReturnValue:&rawApp];
    id app = (__bridge_transfer id)rawApp;
    if (!app) { return nil; }
    NSString *resolved = BRCallObject(app, @"bundleID");
    return [resolved copy];
}

NSString *BRCurrentForegroundBundleID(void) {
    Class deviceClass = NSClassFromString(@"XCUIDevice");
    if (!deviceClass) { return nil; }
    id device = BRCallObject(deviceClass, @"sharedDevice");
    id client = BRCallObject(device, @"accessibilityInterface");
    NSArray *apps = BRCallObject(client, @"activeApplications");
    if (![apps isKindOfClass:[NSArray class]] || apps.count == 0) { return nil; }
    NSString *springboard = nil;
    for (id element in apps) {
        NSString *bundleIdentifier = BRBundleIDForElement(element);
        if (bundleIdentifier.length == 0) { continue; }
        if ([bundleIdentifier isEqualToString:@"com.apple.springboard"]) {
            springboard = bundleIdentifier;
            continue;
        }
        NSInteger state = BRAppStateForBundleIdentifier(bundleIdentifier);
        if (state == 4 || state == 0) { return bundleIdentifier; }
    }
    if (springboard) { return springboard; }
    return BRBundleIDForElement(apps.firstObject);
}

#pragma mark - Installed apps

BOOL BRInstalledAppsAvailable(void) {
    Class workspaceClass = NSClassFromString(@"LSApplicationWorkspace");
    if (!workspaceClass) { return NO; }
    return [workspaceClass respondsToSelector:NSSelectorFromString(@"defaultWorkspace")];
}

NSArray<NSDictionary<NSString *, NSString *> *> *BRInstalledApps(BOOL userOnly) {
    id workspace = BRCallObject(NSClassFromString(@"LSApplicationWorkspace"), @"defaultWorkspace");
    if (!workspace) { return nil; }
    NSArray *apps = BRCallObject(workspace, @"allApplications");
    if (![apps isKindOfClass:[NSArray class]] || apps.count == 0) {
        apps = BRCallObject(workspace, @"allInstalledApplications");
    }
    if (![apps isKindOfClass:[NSArray class]]) { return nil; }
    NSMutableArray *output = [NSMutableArray array];
    for (id proxy in apps) {
        @try {
            NSString *bundleIdentifier = BRCallObject(proxy, @"applicationIdentifier");
            NSString *name = BRCallObject(proxy, @"localizedName");
            NSString *type = BRCallObject(proxy, @"applicationType");
            if (bundleIdentifier.length == 0) { continue; }
            if (userOnly && type.length > 0 && ![type isEqualToString:@"User"]) { continue; }
            [output addObject:@{
                @"bundle_id": bundleIdentifier,
                @"name": name ?: @"",
                @"type": type ?: @"",
            }];
        } @catch (__unused NSException *exception) {
            continue;
        }
    }
    [output sortUsingComparator:^NSComparisonResult(NSDictionary *lhs, NSDictionary *rhs) {
        return [lhs[@"name"] localizedCaseInsensitiveCompare:rhs[@"name"]];
    }];
    return output;
}

#pragma mark - URL / app opening

static id BRWorkspace(void) {
    return BRCallObject(NSClassFromString(@"LSApplicationWorkspace"), @"defaultWorkspace");
}

BOOL BROpenURLAvailable(void) {
    Class sessionClass = NSClassFromString(@"XCTRunnerDaemonSession");
    if (sessionClass) {
        id session = BRCallObject(sessionClass, @"sharedSession");
        if (session && [session respondsToSelector:
                        NSSelectorFromString(@"openDefaultApplicationForURL:completion:")]) {
            return YES;
        }
    }
    id workspace = BRWorkspace();
    return workspace != nil
        && ([workspace respondsToSelector:NSSelectorFromString(@"openSensitiveURL:withOptions:")]
            || [workspace respondsToSelector:NSSelectorFromString(@"openURL:")]);
}

BOOL BROpenURL(NSURL *url) {
    if (!url) { return NO; }
    Class sessionClass = NSClassFromString(@"XCTRunnerDaemonSession");
    id session = BRCallObject(sessionClass, @"sharedSession");
    SEL openSelector = NSSelectorFromString(@"openDefaultApplicationForURL:completion:");
    if (session && [session respondsToSelector:openSelector]) {
        NSMethodSignature *signature = [session methodSignatureForSelector:openSelector];
        NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
        invocation.target = session;
        invocation.selector = openSelector;
        __block BOOL opened = NO;
        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
        void (^completion)(BOOL, NSError *) = ^(BOOL result, NSError *error) {
            opened = result && (error == nil);
            dispatch_semaphore_signal(semaphore);
        };
        [invocation setArgument:&url atIndex:2];
        [invocation setArgument:&completion atIndex:3];
        @try {
            [invocation invoke];
            dispatch_semaphore_wait(semaphore,
                                    dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)));
            if (opened) { return YES; }
        } @catch (__unused NSException *exception) {
            // Fall through to the workspace path.
        }
    }

    id workspace = BRWorkspace();
    if (!workspace) { return NO; }
    if ([workspace respondsToSelector:NSSelectorFromString(@"openSensitiveURL:withOptions:")]) {
        return BRCallBool2(workspace, @"openSensitiveURL:withOptions:", url, nil);
    }
    if ([workspace respondsToSelector:NSSelectorFromString(@"openURL:")]) {
        return BRCallBool1(workspace, @"openURL:", url);
    }
    return NO;
}

BOOL BROpenBundleIdentifier(NSString *bundleIdentifier) {
    if (bundleIdentifier.length == 0) { return NO; }
    id workspace = BRWorkspace();
    if (!workspace) { return NO; }
    return BRCallBool1(workspace, @"openApplicationWithBundleID:", bundleIdentifier);
}
