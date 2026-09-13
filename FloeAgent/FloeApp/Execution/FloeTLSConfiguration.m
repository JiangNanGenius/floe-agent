// SPDX-License-Identifier: MPL-2.0
#import "FloeTLSConfiguration.h"

NSString *FloeTLSCertificateBundle(void) {
    // Both resources are shipped in the signed application. The first is the
    // hash-pinned certifi distribution; pip's vendored bundle is recovery only.
    NSString *root = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"python/lib/python3.13"];
    for (NSString *relative in @[@"site-packages/certifi/cacert.pem", @"pip/_vendor/certifi/cacert.pem"]) {
        NSString *path = [root stringByAppendingPathComponent:relative];
        NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
        if ([attributes[NSFileType] isEqual:NSFileTypeRegular] && [attributes[NSFileSize] unsignedLongLongValue] > 0) return path;
    }
    return nil;
}
NSDictionary<NSString *, NSString *> *FloeTLSEnvironment(void) {
    NSString *path = FloeTLSCertificateBundle();
    if (!path) return @{};
    return @{@"SSL_CERT_FILE": path, @"CURL_CA_BUNDLE": path, @"REQUESTS_CA_BUNDLE": path,
             @"PIP_CERT": path, @"NODE_EXTRA_CA_CERTS": path, @"npm_config_cafile": path};
}
