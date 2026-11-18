#import <Sparkle/Sparkle.h>

NS_ASSUME_NONNULL_BEGIN
@interface FixtureDriver : NSObject <SPUUserDriver>
@property (nonatomic, copy) void (^event)(NSString *);
@end
NS_ASSUME_NONNULL_END
