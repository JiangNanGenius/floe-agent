#!/usr/bin/env python3
"""Compile the actual native language resolver against Foundation.

Verifies bundled-language matching only; native save/reopen remains a separate
fidelity gate, including regional formats and layout.
"""
import json
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent / 'ThirdParty/Collabora'
CASES = [
    (['zh-Hans-TW'], 'zh-CN'), (['zh-Hans-HK'], 'zh-CN'),
    (['zh-Hans'], 'zh-CN'), (['zh-CN'], 'zh-CN'), (['zh-SG'], 'zh-CN'),
    (['zh-Hant-CN'], 'zh-TW'), (['zh-Hant'], 'zh-TW'),
    (['zh-TW'], 'zh-TW'), (['zh-HK'], 'zh-TW'), (['zh-MO'], 'zh-TW'),
    (['en-US'], 'en-US'), (['en-AU'], 'en-US'), (['en-GB'], 'en-US'),
    (['fr-FR', 'zh-CN'], 'zh-CN'), (['zh-TW', 'zh-CN'], 'zh-TW'),
    (['en-AU', 'zh-TW'], 'en-US'), (['fr-FR'], 'en-US'), ([], 'en-US'),
]


def check():
    host = (ROOT / 'FloeOfficeNative/FloeOfficeNative.mm').read_text()
    helper = host.split('// FLOE_EDITOR_LANGUAGE_BEGIN', 1)[1].split('// FLOE_EDITOR_LANGUAGE_END', 1)[0]
    lock = json.loads((ROOT / 'engine.lock.json').read_text())
    assert '--with-lang=en-US zh-CN zh-TW' in lock['engineConfigureArguments']
    assert 'app_locale = FloeEditorLanguage(NSLocale.preferredLanguages);' in host
    statements = []
    for preferences, expected in CASES:
        array = '@[' + ', '.join('@' + json.dumps(item) for item in preferences) + ']'
        statements.append(f'assert([FloeEditorLanguage({array}) isEqualToString:@"{expected}"]);')
    with tempfile.TemporaryDirectory(prefix='floe-language-') as folder:
        root = Path(folder)
        source = root / 'language.mm'
        source.write_text('#import <Foundation/Foundation.h>\n#include <cassert>\n' + helper +
                          '\nint main() { @autoreleasepool {\n' + '\n'.join(statements) + '\n} }\n')
        subprocess.run(['xcrun', '--sdk', 'macosx', 'clang++', '-std=c++20', '-fobjc-arc',
                        '-Wall', '-Werror', '-framework', 'Foundation', str(source),
                        '-o', str(root / 'language')], check=True, capture_output=True, text=True)
        subprocess.run([str(root / 'language')], check=True, capture_output=True, timeout=20)
    return {'nativeFoundationCasesPassed': len(CASES), 'bundledLanguagesMatchLock': True,
            'nativeSaveReopenPassed': False, 'physicalDevicePassed': False}


if __name__ == '__main__':
    print(json.dumps(check(), indent=2))
