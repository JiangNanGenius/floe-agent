#import "ExceptionCatcher.h"

BOOL BRCatchException(void (^block)(void), NSError **error) {
    @try {
        if (block) { block(); }
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            NSString *message = exception.reason
                ?: [NSString stringWithFormat:@"Objective-C exception %@", exception.name ?: @"<unknown>"];
            NSMutableDictionary *userInfo = [@{
                NSLocalizedDescriptionKey: message,
                @"exceptionName": exception.name ?: @"<unknown>",
            } mutableCopy];
            if (exception.callStackSymbols.count > 0) {
                userInfo[@"callStack"] = [exception.callStackSymbols componentsJoinedByString:@"\n"];
            }
            *error = [NSError errorWithDomain:@"org.floeagent.iosbridge.exception"
                                         code: 1
                                     userInfo:userInfo];
        }
        return NO;
    }
}
