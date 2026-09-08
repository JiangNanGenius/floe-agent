#!/usr/bin/env python3
"""Execute locked native copy-opening code with real files and controlled sockets.

This does not open UIDocument, render WebKit, or run the Office engine.
"""
import argparse
import json
from pathlib import Path
import subprocess
import tempfile
from test_office_native_lifecycle import BASE, checked_source


def check(root):
    lock = json.loads((BASE / 'engine.lock.json').read_text())
    source = checked_source(root, 'ios/Mobile/CODocument.mm', lock)
    start = source.index('- (instancetype)initWithFileURL:')
    initialize = source[start:source.index('\n- (id)contentsForType:', start)]
    start = source.index('- (BOOL)loadFromContents:')
    opening = source[start:source.index('    NSURLComponents *components', start)] + '    return YES;\n}\n'
    harness = HEADER + '\n@implementation CODocument\n' + initialize + opening + '\n@end\n' + MAIN
    with tempfile.TemporaryDirectory(prefix='floe-native-open-') as temporary:
        folder = Path(temporary)
        (folder / 'open.mm').write_text(harness)
        subprocess.run(['xcrun', '--sdk', 'macosx', 'clang++', '-std=c++20', '-fobjc-arc', '-fblocks',
            '-Wall', '-Werror', '-framework', 'Foundation', str(folder / 'open.mm'), '-o', str(folder / 'open')],
            check=True, capture_output=True, text=True)
        result = subprocess.run([str(folder / 'open')], check=True, capture_output=True, text=True, timeout=20)
    return {'patchSHA256': lock['embeddingOverlay']['sha256'], 'checksPassed': result.stdout.splitlines(),
        'kind': 'locked copy-opening fragment with real files and controlled resources/sockets',
        'fullNativeDocumentOpened': False, 'deviceRoundtripPassed': False}


HEADER = r'''
#import <Foundation/Foundation.h>
#include <atomic>
#include <cassert>
#include <cstdio>
static std::atomic<unsigned> appDocIdCounter(1);
static int socketCalls = 0;
static int socketResult = 42;
static int fakeSocketSocket() { socketCalls++; return socketResult; }
static NSURL *resourceURL;
@interface FixtureBundle : NSObject
+ (instancetype)mainBundle;
- (NSURL *)URLForResource:(NSString *)name withExtension:(NSString *)extension;
@end
@implementation FixtureBundle
+ (instancetype)mainBundle { return [self new]; }
- (NSURL *)URLForResource:(NSString *)name withExtension:(NSString *)extension { return resourceURL; }
@end
@interface FixtureDocument : NSObject
@property NSURL *fileURL;
- (instancetype)initWithFileURL:(NSURL *)url;
@end
@implementation FixtureDocument
- (instancetype)initWithFileURL:(NSURL *)url {
    if ((self = [super init])) _fileURL = url;
    return self;
}
@end
@interface CODocument : FixtureDocument {
@public int fakeClientFd; NSURL *copyFileURL; unsigned appDocId;
}
@property NSURL *floeEngineCopyDirectory;
- (BOOL)loadFromContents:(id)contents ofType:(NSString *)type error:(NSError **)error;
@end
#define NSBundle FixtureBundle
'''

MAIN = r'''
int main() { @autoreleasepool {
    NSURL *root = [NSFileManager.defaultManager.temporaryDirectory URLByAppendingPathComponent:NSUUID.UUID.UUIDString];
    assert([NSFileManager.defaultManager createDirectoryAtURL:root withIntermediateDirectories:YES attributes:nil error:nil]);
    NSURL *original = [root URLByAppendingPathComponent:@"working.docx"];
    NSData *bytes = [@"document bytes" dataUsingEncoding:NSUTF8StringEncoding];
    assert([bytes writeToURL:original atomically:YES]);
    NSURL *copies = [root URLByAppendingPathComponent:@"engine"];
    CODocument *first = [[CODocument alloc] initWithFileURL:original];
    first.floeEngineCopyDirectory = copies;
    assert(first->fakeClientFd == -1);
    NSError *error = nil;
    resourceURL = nil;
    assert(![first loadFromContents:nil ofType:@"docx" error:&error]);
    assert(error.code == NSFileReadNoSuchFileError && socketCalls == 0 && first->fakeClientFd == -1);
    puts("missing editor resources do not allocate a socket or mark the document open");
    NSArray *before = [NSFileManager.defaultManager contentsOfDirectoryAtURL:copies includingPropertiesForKeys:nil options:0 error:nil];
    assert(before.count == 1);
    NSURL *retained = [before.firstObject URLByAppendingPathComponent:@"working.docx"];
    assert([[NSData dataWithContentsOfURL:retained] isEqual:bytes]);
    resourceURL = [root URLByAppendingPathComponent:@"cool.html"];
    assert([first loadFromContents:nil ofType:@"docx" error:nil]);
    assert(socketCalls == 1 && first->fakeClientFd == 42);
    assert(![first->copyFileURL isEqual:retained] && [[NSData dataWithContentsOfURL:retained] isEqual:bytes]);
    assert([[NSData dataWithContentsOfURL:first->copyFileURL] isEqual:bytes]);
    puts("retry creates a new persistent generation and retains the failed-open copy");
    NSURL *opened = first->copyFileURL;
    assert([first loadFromContents:nil ofType:@"docx" error:nil]);
    assert(socketCalls == 1 && [first->copyFileURL isEqual:opened]);
    puts("repeated load of an open document does not recopy or allocate another socket");
    CODocument *second = [[CODocument alloc] initWithFileURL:original];
    second.floeEngineCopyDirectory = copies;
    assert([second loadFromContents:nil ofType:@"docx" error:nil]);
    assert(![first->copyFileURL isEqual:second->copyFileURL] && [[NSData dataWithContentsOfURL:opened] isEqual:bytes]);
    puts("a second editor generation cannot replace the first generation");
    CODocument *missing = [[CODocument alloc] initWithFileURL:[root URLByAppendingPathComponent:@"missing.docx"]];
    missing.floeEngineCopyDirectory = copies;
    error = nil;
    assert(![missing loadFromContents:nil ofType:@"docx" error:&error]);
    assert(error != nil && socketCalls == 2 && missing->fakeClientFd == -1);
    puts("failed source copy leaves previous files intact and allocates no socket");
    missing.floeEngineCopyDirectory = [NSURL URLWithString:@"https://invalid.example/engine"];
    error = nil;
    assert(![missing loadFromContents:nil ofType:@"docx" error:&error]);
    assert(error.code == NSFileWriteInvalidFileNameError && socketCalls == 2);
    puts("non-file engine directories are rejected before opening");
    CODocument *failedSocket = [[CODocument alloc] initWithFileURL:original];
    failedSocket.floeEngineCopyDirectory = copies;
    socketResult = -1;
    assert(![failedSocket loadFromContents:nil ofType:@"docx" error:nil]);
    assert(failedSocket->fakeClientFd == -1 && [[NSData dataWithContentsOfURL:failedSocket->copyFileURL] isEqual:bytes]);
    puts("failed socket allocation retains its persistent copy and permits a later retry");
    assert([[NSData dataWithContentsOfURL:original] isEqual:bytes]);
    assert([NSFileManager.defaultManager removeItemAtURL:root error:nil]);
    return 0;
} }
'''


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('prepared_root', type=Path)
    print(json.dumps(check(parser.parse_args().prepared_root), indent=2))
