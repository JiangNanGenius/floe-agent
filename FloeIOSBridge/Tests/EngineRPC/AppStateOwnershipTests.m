#import <Foundation/Foundation.h>
#import "BridgeEnginePrivateShims.h"

static NSUInteger created, destroyed, replacements, replacementDestroyed, paths, pathDestroyed, records, recordDestroyed;
@interface FGReplacement : NSObject
- (NSInteger)state;
@end
@implementation FGReplacement
- (instancetype)init { if ((self=[super init])) { replacements++; } return self; }
- (NSInteger)state { return 4; }
- (void)dealloc { replacementDestroyed++; }
@end
@interface XCUIApplication : NSObject
- (instancetype)initWithBundleIdentifier:(NSString *)bundle;
- (NSInteger)state;
@end
@implementation XCUIApplication
- (instancetype)initWithBundleIdentifier:(NSString *)bundle {
    if ((self = [super init])) { created++; }
    if ([bundle isEqual:@"nil"]) { self=nil; return nil; }
    if ([bundle isEqual:@"replacement"]) { self=nil; return (id)[FGReplacement new]; }
    if ([bundle isEqual:@"throw"]) { self=nil; @throw [NSException exceptionWithName:@"fixture" reason:nil userInfo:nil]; }
    return self;
}
- (NSInteger)state { return 4; }
- (void)dealloc { destroyed++; }
@end
@interface XCPointerEventPath : NSObject
- (instancetype)initForTextInput;
- (instancetype)initForTouchAtPoint:(CGPoint)point offset:(double)offset;
- (void)typeText:(NSString *)text atOffset:(double)offset typingSpeed:(NSUInteger)speed shouldRedact:(BOOL)redact;
- (void)pressDownAtOffset:(double)offset;
- (void)moveToPoint:(CGPoint)point atOffset:(double)offset;
- (void)liftUpAtOffset:(double)offset;
@end
@implementation XCPointerEventPath
+ (id)allocWithZone:(struct _NSZone *)zone { paths++; return [super allocWithZone:zone]; }
- (instancetype)initForTextInput { return [super init]; }
- (instancetype)initForTouchAtPoint:(CGPoint)point offset:(double)offset { return [self initForTextInput]; }
- (void)typeText:(NSString *)text atOffset:(double)offset typingSpeed:(NSUInteger)speed shouldRedact:(BOOL)redact {}
- (void)pressDownAtOffset:(double)offset {}
- (void)moveToPoint:(CGPoint)point atOffset:(double)offset {}
- (void)liftUpAtOffset:(double)offset {}
- (void)dealloc { pathDestroyed++; }
@end
@interface XCSynthesizedEventRecord : NSObject
- (instancetype)initWithName:(NSString *)name;
- (void)addPointerEventPath:(id)path;
- (BOOL)synthesizeWithError:(NSError **)error;
@end
@implementation XCSynthesizedEventRecord
+ (id)allocWithZone:(struct _NSZone *)zone { records++; return [super allocWithZone:zone]; }
- (instancetype)initWithName:(NSString *)name { return [super init]; }
- (void)addPointerEventPath:(id)path {}
- (BOOL)synthesizeWithError:(NSError **)error { return YES; }
- (void)dealloc { recordDestroyed++; }
@end
static void Check(BOOL ok, const char *name) { if (!ok) { fprintf(stderr,"FAIL %s\n",name); exit(1); } }
int main(void) {
    @autoreleasepool {
        for (NSUInteger index=0; index<100; index++) {
            @autoreleasepool {
                Check(BRAppStateForBundleIdentifier(@"self")==4,"self initializer");
                Check(BRAppStateForBundleIdentifier(@"replacement")==4,"replacement initializer");
                Check(BRAppStateForBundleIdentifier(@"nil")==0,"nil initializer");
                Check(BRAppStateForBundleIdentifier(@"throw")==0,"throw initializer");
                Check(BRTypeTextRedacted(@"synthetic",NULL),"zero and object initializers");
                CGPoint a=CGPointMake(0,0),b=CGPointMake(1,1);
                Check(BRContinuousDrag(@[[NSValue value:&a withObjCType:@encode(CGPoint)],
                                        [NSValue value:&b withObjCType:@encode(CGPoint)]],1,NULL),"point and object initializers");
            }
        }
        printf("COUNTS apps=%lu/%lu replacements=%lu/%lu paths=%lu/%lu records=%lu/%lu\n",created,destroyed,replacements,replacementDestroyed,paths,pathDestroyed,records,recordDestroyed);
        Check(created==destroyed,"app lifetime balanced");
        Check(replacements==replacementDestroyed,"replacement lifetime balanced");
        Check(paths==pathDestroyed,"path lifetime balanced");
        Check(records==recordDestroyed,"record lifetime balanced");
        puts("APPSTATE-OWNERSHIP PASS iterations=100 modes=self,replacement,nil,throw,typing,drag");
    }
    return 0;
}
