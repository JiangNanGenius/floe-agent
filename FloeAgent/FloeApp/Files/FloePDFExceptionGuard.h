#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Converts PDFKit's Objective-C exceptions (invalid indices, widget/form
/// mutations, KVC keys, malformed documents) into a returned message. Swift
/// cannot catch NSException, so without this boundary such an exception
/// terminates the process — the reported PDFedit crashes.
@interface FloePDFExceptionGuard : NSObject

/// Runs the block synchronously. Returns nil on success, or a bounded
/// human-readable reason when an NSException was raised.
+ (nullable NSString *)run:(void (^)(void))block;

@end

NS_ASSUME_NONNULL_END
