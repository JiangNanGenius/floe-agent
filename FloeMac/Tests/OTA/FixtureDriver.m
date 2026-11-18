#import "FixtureDriver.h"

@implementation FixtureDriver
- (void)showUpdatePermissionRequest:(SPUUpdatePermissionRequest *)request reply:(void (^)(SUUpdatePermissionResponse *))reply {
    reply([[SUUpdatePermissionResponse alloc] initWithAutomaticUpdateChecks:NO sendSystemProfile:NO]);
}
- (void)showUserInitiatedUpdateCheckWithCancellation:(void (^)(void))cancellation {
    self.event(@"checking");
}
- (void)showUpdateFoundWithAppcastItem:(SUAppcastItem *)item state:(SPUUserUpdateState *)state reply:(void (^)(SPUUserUpdateChoice))reply {
    self.event([@"found:" stringByAppendingString:item.versionString]);
    reply(SPUUserUpdateChoiceInstall);
}
- (void)showUpdateReleaseNotesWithDownloadData:(SPUDownloadData *)downloadData {}
- (void)showUpdateReleaseNotesFailedToDownloadWithError:(NSError *)error {}
- (void)showUpdateNotFoundWithError:(NSError *)error acknowledgement:(void (^)(void))acknowledgement {
    self.event([@"not-found:" stringByAppendingString:error.localizedDescription]);
    acknowledgement();
}
- (void)showUpdaterError:(NSError *)error acknowledgement:(void (^)(void))acknowledgement {
    self.event([NSString stringWithFormat:@"error:%@:%ld:%@", error.domain, (long)error.code, error.localizedDescription]);
    acknowledgement();
}
- (void)showDownloadInitiatedWithCancellation:(void (^)(void))cancellation { self.event(@"download"); }
- (void)showDownloadDidReceiveExpectedContentLength:(uint64_t)length {}
- (void)showDownloadDidReceiveDataOfLength:(uint64_t)length {}
- (void)showDownloadDidStartExtractingUpdate { self.event(@"extract"); }
- (void)showExtractionReceivedProgress:(double)progress {}
- (void)showReadyToInstallAndRelaunch:(void (^)(SPUUserUpdateChoice))reply {
    self.event(@"ready");
    reply(SPUUserUpdateChoiceInstall);
}
- (void)showInstallingUpdateWithApplicationTerminated:(BOOL)terminated retryTerminatingApplication:(void (^)(void))retry {
    self.event(terminated ? @"installing-after-termination" : @"installing");
}
- (void)showUpdateInstalledAndRelaunched:(BOOL)relaunched acknowledgement:(void (^)(void))acknowledgement {
    self.event(relaunched ? @"installed-relaunched" : @"installed");
    acknowledgement();
}
- (void)dismissUpdateInstallation {}
@end
