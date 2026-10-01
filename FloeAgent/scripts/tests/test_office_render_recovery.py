#!/usr/bin/env python3
"""Compile and execute the shipped render probe with Foundation/dispatch.

Only the engine transport/controller observations are fixtures. The real probe,
readiness functions, timer, cancellation and poll-completion code are extracted
unchanged, except scaling the 60-second recovery timer to 0.5 seconds. This is
component lifecycle evidence, never actual engine/App/device qualification.
"""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[3]
HOST = ROOT / 'FloeAgent/ThirdParty/Collabora/FloeOfficeNative/FloeOfficeNative.mm'

PREFIX = r'''
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#include <cassert>
static NSString *FloeOfficeNativeErrorDomain = @"probe-fixture";
static void FloeOfficeLog(NSString *stage, NSDictionary *facts) {}
@interface FloeOfficeNativeViewController : NSObject
@property (nonatomic) NSUInteger failed, ready, ended, first, unobserved;
@property (nonatomic) NSTimeInterval factDelay;
@property (nonatomic) BOOL noCallback, skeleton, settled, pending, running, closeOnFailure;
@property (nonatomic, weak) id probe;
@property (nonatomic) BOOL renderProbeFinished;
@property (nonatomic, strong) NSDictionary *renderDiagnostics;
@property (nonatomic, copy) void (^onVisibleRenderFailed)(NSError *);
- (void)settlePendingEditEntryWithoutEntry;
@end
'''
STUB = r'''
@implementation FloeOfficeNativeViewController
- (void)evaluateRenderFactsWithCompletion:(void (^)(NSDictionary *, NSError *))completion {
    if (self.noCallback) return;
    NSDictionary *facts = self.skeleton
        ? @{@"stage":@"ready", @"docType":@"presentation", @"docLoaded":@YES,
            @"canvas":@{@"width":@800,@"height":@600}, @"decodedTiles":@0,
            @"editSurfacePainted":@NO, @"fileBasedView":@YES}
        : @{@"stage":@"ready", @"docType":@"presentation", @"docLoaded":@YES,
            @"canvas":@{@"width":@800,@"height":@600}, @"decodedTiles":@1,
            @"editSurfacePainted":@YES, @"fileBasedView":@NO};
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(self.factDelay*NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{ completion(facts, nil); });
}
- (void)renderProbeDidObserveFirstPaint:(NSDictionary *)facts { self.first++; }
- (void)renderProbeDidReachEditEntryReadiness { self.pending=NO; self.running=YES; }
- (void)renderProbeDidProveExtentForEditEntry { self.pending=NO; self.running=YES; }
- (void)renderProbeDidObserveVisibleRender:(NSDictionary *)facts { self.ready++; }
__REAL_FAILURE_CALLBACKS__
- (void)settlePendingEditEntryWithoutEntry { self.pending=NO; }
- (void)renderProbeDidFinishWithoutVisibleRender:(NSDictionary *)facts { self.unobserved++; }
- (BOOL)hasSettledOpenPermission { return self.settled; }
- (BOOL)hasPendingDeferredEditEntry { return self.pending; }
- (BOOL)isDeferredEditEntryRunning { return self.running; }
- (BOOL)hasReportedOpenPermission { return self.settled; }
- (NSTimeInterval)deferredEditEntryParkedSeconds { return 6; }
- (NSString *)renderProbeSessionID { return @"fixture"; }
- (NSUInteger)renderProbeOpenGeneration { return 1; }
- (void)floeStage:(NSString *)stage facts:(NSDictionary *)facts {
    if ([stage isEqual:@"render-recovery-ended"]) self.ended++;
}
@end
static void waitFor(double seconds) {
    NSDate *end = [NSDate dateWithTimeIntervalSinceNow:seconds];
    while (end.timeIntervalSinceNow > 0)
        [[NSRunLoop mainRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.005]];
}
int main(int argc, char **argv) { @autoreleasepool {
    NSString *scenario = @(argv[1]);
    FloeOfficeNativeViewController *host = [FloeOfficeNativeViewController new];
    host.settled=YES; host.factDelay=0.12;
    BOOL readOnly=YES;
    NSString *format=@"pptx";
    if ([scenario isEqual:@"prompt"]) host.factDelay=0.001;
    if ([scenario isEqual:@"skeleton"]) { host.skeleton=YES; host.factDelay=0.001; }
    if ([scenario isEqual:@"silent"]) host.noCallback=YES;
    if ([scenario isEqual:@"pending-silent"]) {
        readOnly=NO; host.noCallback=YES; host.pending=YES; host.settled=NO;
    }
    if ([scenario isEqual:@"cancel-callback"]) host.factDelay=0.2;
    if ([scenario isEqual:@"cancel-notice"]) host.closeOnFailure=YES;
    if ([scenario isEqual:@"open-only"]) { format=@"docx"; host.noCallback=YES; }
    if ([scenario isEqual:@"edit-ack"]) {
        readOnly=NO; host.settled=NO; host.pending=YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 180*NSEC_PER_MSEC),
            dispatch_get_main_queue(), ^{host.settled=YES;});
    }
    FloeOfficeRenderProbe *probe = [[FloeOfficeRenderProbe alloc]
        initWithController:host readOnly:readOnly workingFile:[NSURL fileURLWithPath:
            [@"/fixture." stringByAppendingString:format]]];
    host.probe=probe;
    __weak FloeOfficeNativeViewController *weakHost=host;
    host.onVisibleRenderFailed=^(NSError *error) {
        FloeOfficeNativeViewController *h=weakHost; h.failed++;
        if (h.closeOnFailure) [(FloeOfficeRenderProbe *)h.probe cancel];
    };
    probe.deadline=0.04; [probe start];
    if ([scenario isEqual:@"pending-silent"]) {
        waitFor(0.07); assert(host.failed==1 && host.pending && !host.renderProbeFinished);
    }
    if ([scenario isEqual:@"cancel-callback"]) {
        waitFor(0.06); [probe cancel];
    }
    waitFor(0.65);
    if ([scenario isEqual:@"prompt"]) assert(host.ready==1 && host.failed==0 && host.ended==0);
    else if ([scenario isEqual:@"skeleton"] || [scenario isEqual:@"silent"] || [scenario isEqual:@"pending-silent"])
        assert(host.ready==0 && host.failed==1 && host.ended==1);
    else if ([scenario hasPrefix:@"cancel-"])
        assert(host.ready==0 && host.failed==1 && host.ended==0);
    else if ([scenario isEqual:@"open-only"])
        assert(host.ready==0 && host.failed==0 && host.unobserved==1 && host.ended==0);
    else assert(host.ready==1 && host.failed==1 && host.ended==0);
    printf("%s passed\n", argv[1]);
} }
'''


def fragment(text, start, end):
    return text.split(start, 1)[1].split(end, 1)[0]


class NativeRenderRecovery(unittest.TestCase):
    def test_real_probe_timers_late_paint_cancel_and_negative_states(self):
        text = HOST.read_text()
        decision = fragment(text, '// FLOE_RENDER_DECISION_BEGIN', '// FLOE_RENDER_DECISION_END')
        progress = fragment(text, '// FLOE_RENDER_PROGRESS_BEGIN', '// FLOE_RENDER_PROGRESS_END')
        probe = text[text.index('@interface FloeOfficeNativeViewController (FloeRenderProbe)'):
                     text.index('// FLOE_RENDER_PROBE_END')]
        gate = fragment(text, '// FLOE_EDIT_ENTRY_GATE_BEGIN', '// FLOE_EDIT_ENTRY_GATE_END')
        self.assertEqual(probe.count('dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC)'), 1)
        probe = probe.replace('dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC)',
                              'dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC)')
        scratch=ROOT/'Local/Scratch'
        scratch.mkdir(parents=True,exist_ok=True)
        with tempfile.TemporaryDirectory(dir=scratch, prefix='render-recovery-') as temp:
            folder = Path(temp); source=folder/'probe.mm'; exe=folder/'probe'
            start=text.index('- (void)renderProbeDidFail:(NSError *)error diagnostics:(NSDictionary<NSString *, id> *)diagnostics {')
            end=text.index('- (void)renderProbeDidFinishWithoutVisibleRender:',start)
            callbacks=text[start:end]
            source.write_text(PREFIX+decision+progress+gate+probe+
                              STUB.replace('__REAL_FAILURE_CALLBACKS__',callbacks))
            result = subprocess.run(['xcrun','--sdk','macosx','clang++','-std=c++20',
                                     '-fobjc-arc','-framework','Foundation',str(source),'-o',str(exe)],
                                    capture_output=True,text=True,timeout=60)
            self.assertEqual(result.returncode,0,result.stderr)
            for case in ['prompt','late','edit-ack','skeleton','silent',
                         'cancel-callback','cancel-notice','open-only','pending-silent']:
                with self.subTest(case=case):
                    result=subprocess.run([str(exe),case],capture_output=True,text=True,timeout=10)
                    self.assertEqual(result.returncode,0,result.stdout+result.stderr)


if __name__ == '__main__':
    unittest.main()
