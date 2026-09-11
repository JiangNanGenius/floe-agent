#import "FloePDFExceptionGuard.h"

@implementation FloePDFExceptionGuard

+ (nullable NSString *)run:(void (^)(void))block {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        NSString *reason = exception.reason ?: @"unknown PDF engine exception";
        if (reason.length > 500) {
            reason = [reason substringToIndex:500];
        }
        return [NSString stringWithFormat:@"PDF engine rejected the operation: %@", reason];
    }
}

@end
