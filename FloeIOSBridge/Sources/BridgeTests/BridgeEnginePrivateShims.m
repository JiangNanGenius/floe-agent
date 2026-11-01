#import "BridgeEnginePrivateShims.h"
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

// NSInvocation does not tell ARC that an initializer consumes its receiver
// and returns a +1 object. Pairing a strong alloc local with bridge_transfer of
// that untracked result over-releases a self-returning initializer. These
// checked IMP types carry both parts of the actual initializer ownership ABI.
typedef id __attribute__((ns_returns_retained)) (*BRInit0IMP)(id __attribute__((ns_consumed)), SEL);
typedef id __attribute__((ns_returns_retained)) (*BRInitObjectIMP)(id __attribute__((ns_consumed)), SEL, id);
typedef id __attribute__((ns_returns_retained)) (*BRInitPointIMP)(id __attribute__((ns_consumed)), SEL, CGPoint, double);

static BOOL BRInitSignature(NSMethodSignature *signature, NSArray<NSString *> *arguments) {
    if (!signature || signature.numberOfArguments != arguments.count + 2
        || signature.methodReturnType[0] != '@' || signature.methodReturnLength != sizeof(id)) { return NO; }
    for (NSUInteger index = 0; index < arguments.count; index++) {
        if (strcmp([signature getArgumentTypeAtIndex:index + 2], arguments[index].UTF8String) != 0) { return NO; }
    }
    return YES;
}

static id BRInitialize0(Class cls, NSString *name) {
    // Keep the strong allocation outside the try scope: its cleanup must also
    // run on the caught-exception path without relying on ARC EH cleanups.
    id allocated = nil;
    @try {
        allocated = [cls alloc];
        SEL selector = NSSelectorFromString(name);
        if (![allocated respondsToSelector:selector]
            || !BRInitSignature([allocated methodSignatureForSelector:selector], @[])) { return nil; }
        BRInit0IMP initialize = (BRInit0IMP)[allocated methodForSelector:selector];
        return initialize(allocated, selector);
    } @catch (__unused NSException *exception) { return nil; }
}

static id BRInitializeObject(Class cls, NSString *name, id argument) {
    // Keep the strong allocation outside the try scope: its cleanup must also
    // run on the caught-exception path without relying on ARC EH cleanups.
    id allocated = nil;
    @try {
        allocated = [cls alloc];
        SEL selector = NSSelectorFromString(name);
        if (![allocated respondsToSelector:selector]
            || !BRInitSignature([allocated methodSignatureForSelector:selector], @[@"@"])) { return nil; }
        BRInitObjectIMP initialize = (BRInitObjectIMP)[allocated methodForSelector:selector];
        return initialize(allocated, selector, argument);
    } @catch (__unused NSException *exception) { return nil; }
}

static id BRInitializePoint(Class cls, NSString *name, CGPoint point, double offset) {
    // Keep the strong allocation outside the try scope: its cleanup must also
    // run on the caught-exception path without relying on ARC EH cleanups.
    id allocated = nil;
    @try {
        allocated = [cls alloc];
        SEL selector = NSSelectorFromString(name);
        if (![allocated respondsToSelector:selector]
            || !BRInitSignature([allocated methodSignatureForSelector:selector],
                                @[@(@encode(CGPoint)), @(@encode(double))])) { return nil; }
        BRInitPointIMP initialize = (BRInitPointIMP)[allocated methodForSelector:selector];
        return initialize(allocated, selector, point, offset);
    } @catch (__unused NSException *exception) { return nil; }
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
    id path = BRInitialize0(BRPointerPathClass(), @"initForTextInput");
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

    id record = BRInitializeObject(BREventRecordClass(), @"initWithName:", @"FloeType");
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
    id path = BRInitializePoint(BRPointerPathClass(), @"initForTouchAtPoint:offset:", first, 0);
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

    id record = BRInitializeObject(BREventRecordClass(), @"initWithName:", @"FloeDrag");
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

NSInteger BRAppStateForBundleIdentifier(NSString *bundleIdentifier) {
    if (bundleIdentifier.length == 0) { return 0; }
    Class appClass = NSClassFromString(@"XCUIApplication");
    if (!appClass) { return 0; }
    id app = BRInitializeObject(appClass, @"initWithBundleIdentifier:", bundleIdentifier);
    if (!app) { return 0; }
    return BRCallInteger(app, @"state");
}

BOOL BRAppStateAvailable(void) {
    Class appClass = NSClassFromString(@"XCUIApplication");
    return appClass != nil && [appClass instancesRespondToSelector:NSSelectorFromString(@"state")];
}

// This section deliberately accepts only validated Objective-C ABI shapes.
// A private selector's presence alone does not establish a safe return type.
static const char *BRForegroundUnqualifiedType(const char *type) {
    while (*type && strchr("rnNoORV", *type)) { type++; }
    return type;
}

static BOOL BRForegroundObjectSignature(NSMethodSignature *signature, NSUInteger arguments) {
    return signature && signature.numberOfArguments == arguments
        && *BRForegroundUnqualifiedType(signature.methodReturnType) == '@'
        && signature.methodReturnLength == sizeof(id);
}

static BOOL BRForegroundHasObjectGetter(id target, NSString *name) {
    @try {
        SEL selector = NSSelectorFromString(name);
        return target && [target respondsToSelector:selector]
            && BRForegroundObjectSignature([target methodSignatureForSelector:selector], 2);
    } @catch (__unused NSException *exception) { return NO; }
}

static id BRForegroundObject(id target, NSString *name) {
    @try {
        if (!BRForegroundHasObjectGetter(target, name)) { return nil; }
        SEL selector = NSSelectorFromString(name);
        NSInvocation *call = [NSInvocation invocationWithMethodSignature:[target methodSignatureForSelector:selector]];
        call.target = target;
        call.selector = selector;
        [call invoke];
        __unsafe_unretained id value = nil;
        [call getReturnValue:&value];
        return value;
    } @catch (__unused NSException *exception) { return nil; }
}

static int32_t BRForegroundPID(id target) {
    for (NSString *name in @[@"processIdentifier", @"processID"]) {
        @try {
            SEL selector = NSSelectorFromString(name);
            if (![target respondsToSelector:selector]) { continue; }
            NSMethodSignature *signature = [target methodSignatureForSelector:selector];
            if (!signature || signature.numberOfArguments != 2) { return 0; }
            const char *type = BRForegroundUnqualifiedType(signature.methodReturnType);
            if ((*type != 'i' && *type != 'q') || signature.methodReturnLength > sizeof(int64_t)) { return 0; }
            NSInvocation *call = [NSInvocation invocationWithMethodSignature:signature];
            call.target = target;
            call.selector = selector;
            [call invoke];
            int64_t value = 0;
            if (*type == 'i') {
                int32_t small = 0;
                [call getReturnValue:&small];
                value = small;
            } else { [call getReturnValue:&value]; }
            return value > 0 && value <= INT32_MAX ? (int32_t)value : 0;
        } @catch (__unused NSException *exception) { return 0; }
    }
    return 0;
}

static id BRForegroundMonitoredApp(id tracker, int32_t pid) {
    @try {
        SEL selector = NSSelectorFromString(@"monitoredApplicationWithProcessIdentifier:");
        if (!tracker || pid <= 0 || ![tracker respondsToSelector:selector]) { return nil; }
        NSMethodSignature *signature = [tracker methodSignatureForSelector:selector];
        if (!BRForegroundObjectSignature(signature, 3)
            || strcmp(BRForegroundUnqualifiedType([signature getArgumentTypeAtIndex:2]), @encode(int32_t)) != 0) { return nil; }
        NSInvocation *call = [NSInvocation invocationWithMethodSignature:signature];
        call.target = tracker;
        call.selector = selector;
        [call setArgument:&pid atIndex:2];
        [call invoke];
        __unsafe_unretained id value = nil;
        [call getReturnValue:&value];
        return value;
    } @catch (__unused NSException *exception) { return nil; }
}

static NSString *BRForegroundBundleID(id app) {
    for (NSString *name in @[@"bundleIdentifier", @"bundleID"]) {
        id value = BRForegroundObject(app, name);
        if ([value isKindOfClass:NSString.class] && [value length] > 0 && [value length] <= 256) {
            return [value copy];
        }
    }
    return nil;
}

static NSLock *BRForegroundDiagnosticLock(void) {
    static NSLock *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ lock = [NSLock new]; });
    return lock;
}
static NSDictionary<NSString *, id> *BRLastForegroundDiagnostic;
static void BRRecordForeground(NSString *source, NSString *reason, NSUInteger count) {
    NSLock *lock = BRForegroundDiagnosticLock();
    [lock lock];
    BRLastForegroundDiagnostic = @{@"source": source, @"reason_code": reason,
                                  @"candidate_count": @(count),
                                  @"captured_at": @([NSDate date].timeIntervalSince1970)};
    [lock unlock];
}
NSDictionary<NSString *, id> *BRForegroundHelperLastDiagnostic(void) {
    NSLock *lock = BRForegroundDiagnosticLock();
    [lock lock];
    NSDictionary *value = [BRLastForegroundDiagnostic copy];
    [lock unlock];
    return value ?: @{@"reason_code": @"not_observed"};
}

static NSString *BRResolveForeground(id device, NSInteger (^stateForBundle)(NSString *)) {
    id client = BRForegroundObject(device, @"accessibilityInterface");
    id system = BRForegroundObject(device, @"system");
    NSString *source = @"unavailable";
    id value = nil;
    if (BRForegroundHasObjectGetter(client, @"activeForegroundApplications")) {
        source = @"accessibility_foreground";
        value = BRForegroundObject(client, @"activeForegroundApplications");
    } else if (BRForegroundHasObjectGetter(system, @"activeForegroundApplications")) {
        source = @"system_foreground";
        value = BRForegroundObject(system, @"activeForegroundApplications");
    } else if (BRForegroundHasObjectGetter(client, @"activeApplications")) {
        source = @"accessibility_active";
        value = BRForegroundObject(client, @"activeApplications");
    }
    if (![value isKindOfClass:NSArray.class] || [value count] == 0 || [value count] > 32) {
        BRRecordForeground(source, @"applications_unknown", 0);
        return nil;
    }
    NSArray *apps = value;
    id tracker = BRForegroundObject(client, @"applicationProcessTracker");
    NSString *candidate = nil;
    for (id element in apps) {
        NSString *bundle = BRForegroundBundleID(element);
        if (!bundle) { bundle = BRForegroundBundleID(BRForegroundMonitoredApp(tracker, BRForegroundPID(element))); }
        if (!bundle) { BRRecordForeground(source, @"identity_unknown", apps.count); return nil; }
        NSInteger state = stateForBundle(bundle);
        if (state < 1 || state > 4) { BRRecordForeground(source, @"state_unknown", apps.count); return nil; }
        if (state != 4) { continue; }
        NSString *lower = bundle.lowercaseString;
        if ([lower isEqualToString:@"com.apple.springboard"]) { continue; }
        if ([@[@"com.apple.authkitui", @"com.apple.localauthentication.remoteui",
               @"com.apple.authenticationservices.ui", @"com.apple.passcodesettings"] containsObject:lower]) {
            BRRecordForeground(source, @"authorization_foreground", apps.count);
            return nil;
        }
        if (candidate && [candidate caseInsensitiveCompare:bundle] != NSOrderedSame) {
            BRRecordForeground(source, @"multiple_foreground", apps.count);
            return nil;
        }
        candidate = bundle;
    }
    BRRecordForeground(source, candidate ? @"unique_foreground" : @"no_ordinary_foreground", apps.count);
    return candidate;
}

BOOL BRForegroundHelperAvailable(void) {
    id device = BRForegroundObject(NSClassFromString(@"XCUIDevice"), @"sharedDevice");
    id client = BRForegroundObject(device, @"accessibilityInterface");
    id system = BRForegroundObject(device, @"system");
    return BRForegroundHasObjectGetter(client, @"activeForegroundApplications")
        || BRForegroundHasObjectGetter(system, @"activeForegroundApplications")
        || BRForegroundHasObjectGetter(client, @"activeApplications");
}

NSString *BRCurrentForegroundBundleID(void) {
    id device = BRForegroundObject(NSClassFromString(@"XCUIDevice"), @"sharedDevice");
    @try {
        return BRResolveForeground(device, ^NSInteger(NSString *bundle) {
            return BRAppStateForBundleIdentifier(bundle);
        });
    } @catch (__unused NSException *exception) {
        BRRecordForeground(@"unavailable", @"query_failed", 0);
        return nil;
    }
}

#if BRIDGE_ENGINE_TESTING
NSString *BRForegroundBundleIDForTesting(id device, NSInteger (^stateForBundle)(NSString *)) {
    @try { return BRResolveForeground(device, stateForBundle); }
    @catch (__unused NSException *exception) { return nil; }
}
#endif

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
