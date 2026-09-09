#!/usr/bin/env python3
"""Compile the actual native save receipt joiner and exercise reordered events."""
import json
from pathlib import Path
import subprocess
import tempfile
from package_office_engine import digest


def check():
    source = Path(__file__).resolve().parent.parent / 'ThirdParty/Collabora/FloeOfficeNative/FloeOfficeNative.mm'
    text = source.read_text()
    fragment = text.split('// FLOE_SAVE_RECEIPTS_BEGIN:', 1)[1].split('\n', 1)[1].split('// FLOE_SAVE_RECEIPTS_END', 1)[0]
    with tempfile.TemporaryDirectory(prefix='floe-save-receipts-') as temporary:
        root = Path(temporary)
        program = root / 'receipts.mm'
        program.write_text('#import <Foundation/Foundation.h>\n#include <cassert>\n#include <cstdio>\n' + fragment + HARNESS)
        subprocess.run(['xcrun', '--sdk', 'macosx', 'clang++', '-std=c++20', '-fobjc-arc', '-fblocks',
            '-Wall', '-Werror', '-framework', 'Foundation', str(program), '-o', str(root / 'receipts')],
            check=True, capture_output=True, text=True)
        result = subprocess.run([str(root / 'receipts')], check=True, capture_output=True, text=True, timeout=20)
    return {'hostImplementationSHA256': digest(source), 'checksPassed': result.stdout.splitlines(),
        'kind': 'compiled actual save joiner with controlled event order',
        'nativeProtocolCompiled': False, 'realEngineSavePassed': False, 'originalFileWritebackPassed': False}


HARNESS = r'''
int main() { @autoreleasepool {
    FloeSaveReceiptJoiner *joiner = [FloeSaveReceiptJoiner new];
    __block int completions = 0;
    __block BOOL last = NO;
    void (^done)(BOOL) = ^(BOOL result) { completions++; last = result; };
    assert([joiner begin:@"new-request" completion:done]);
    assert(![joiner begin:@"duplicate-request" completion:done]);
    [joiner complete:@"old-autosave" success:YES];
    [joiner associate:@"old-autosave" requestID:@""];
    assert(completions == 0 && [joiner.activeRequestID isEqualToString:@"new-request"]);
    puts("older autosave and duplicate admission cannot complete or replace the active save");
    [joiner associate:@"request-result" requestID:@"new-request"];
    assert(completions == 0);
    [joiner complete:@"request-result" success:YES];
    assert(completions == 1 && last && joiner.activeRequestID == nil);
    puts("request identity arriving first waits for its matching native persistence result");
    [joiner associate:@"request-result" requestID:@"new-request"];
    [joiner complete:@"request-result" success:YES];
    assert(completions == 1);
    puts("duplicate matched receipts cannot complete twice");
    assert([joiner begin:@"second-request" completion:done]);
    [joiner complete:@"second-result" success:NO];
    assert(completions == 1);
    [joiner associate:@"second-result" requestID:@"second-request"];
    assert(completions == 2 && !last);
    puts("native persistence arriving first waits for association and preserves failure");
    assert([joiner begin:@"third-request" completion:done]);
    [joiner reject:@"unrelated-request"];
    assert(completions == 2);
    [joiner reject:@"third-request"];
    assert(completions == 3 && !last);
    puts("broker rejection affects only its own active request");
    assert([joiner begin:@"cancelled" completion:done]);
    [joiner cancel];
    assert(completions == 4 && !last);
    assert([joiner begin:@"after-cancel" completion:done]);
    [joiner associate:@"late-cancelled-result" requestID:@"cancelled"];
    [joiner complete:@"late-cancelled-result" success:YES];
    assert(completions == 4 && [joiner.activeRequestID isEqualToString:@"after-cancel"]);
    [joiner associate:@"current" requestID:@"after-cancel"];
    [joiner complete:@"current" success:YES];
    assert(completions == 5 && last);
    puts("late completion after cancellation cannot satisfy a later save");
    assert([joiner begin:@"orphaned" completion:done]);
    for (int i = 0; i < 65; ++i) [joiner complete:[NSString stringWithFormat:@"orphan-%d", i] success:YES];
    assert(completions == 6 && !last && joiner.requests.count + joiner.results.count <= 64);
    puts("missing receipt halves stay bounded and fail instead of assuming success");
    assert([joiner begin:@"ambiguous" completion:done]);
    [joiner associate:@"conflicting" requestID:@"ambiguous"];
    [joiner associate:@"conflicting" requestID:@"another-request"];
    assert(completions == 7 && !last);
    assert([joiner begin:@"ambiguous-result" completion:done]);
    [joiner complete:@"contradiction" success:YES];
    [joiner complete:@"contradiction" success:NO];
    assert(completions == 8 && !last);
    puts("conflicting identity or persistence halves fail instead of replacing evidence");
    return 0;
} }
'''


if __name__ == '__main__':
    print(json.dumps(check(), indent=2))
