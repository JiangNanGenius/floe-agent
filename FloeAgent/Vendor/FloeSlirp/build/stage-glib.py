#!/usr/bin/env python3
"""Stage a minimal GLib prefix (core lib + headers + pkg-config) from a meson
build tree that only built glib/libglib-2.0.a (+ pcre2 static).

Usage: stage-glib.py <build-dir> <glib-src-dir> <stage-dir>
"""
import json, os, shutil, subprocess, sys, glob

build, src, stage = sys.argv[1], sys.argv[2], sys.argv[3]

targets = json.loads(subprocess.check_output(
    [os.environ.get('MESON', 'meson'), 'introspect', '--targets', build]))

glib_a = pcre_a = None
for t in targets:
    for exe in t.get('filename', t.get('executables', [])):
        fn = exe if os.path.isabs(exe) else os.path.join(build, exe)
        base = os.path.basename(fn)
        if base.endswith('libglib-2.0.a'):
            glib_a = fn
        elif base.endswith('.a') and 'pcre2-8' in base:
            pcre_a = fn
if not glib_a:
    sys.exit('libglib-2.0.a not found in build targets')

os.makedirs(f'{stage}/lib', exist_ok=True)
os.makedirs(f'{stage}/include/glib-2.0/glib', exist_ok=True)
os.makedirs(f'{stage}/lib/glib-2.0/include', exist_ok=True)
os.makedirs(f'{stage}/lib/pkgconfig', exist_ok=True)

shutil.copy(glib_a, f'{stage}/lib/libglib-2.0.a')
if pcre_a:
    shutil.copy(pcre_a, f'{stage}/lib/libpcre2-8.a')

# proxy-libintl static archive (glib.pc's -lintl resolves against it in staging)
for cand in glob.glob(f'{build}/subprojects/proxy-libintl*/libintl.a'):
    shutil.copy(cand, f'{stage}/lib/libintl.a')
    print(f'  intl: {cand}')

# stage the pcre2 pkg-config referenced by glib-2.0.pc Requires:
for cand in ('libpcre2-8.pc', 'proxy-libintl.pc', 'intl.pc'):
    srcpc = f'{build}/meson-private/{cand}'
    if os.path.exists(srcpc):
        import re as _re
        txt = open(srcpc).read()
        txt = _re.sub(r'(?m)^prefix=.*$', f'prefix={stage}', txt)
        txt = _re.sub(r'(?m)^libdir=.*$', 'libdir=${prefix}/lib', txt)
        txt = _re.sub(r'(?m)^includedir=.*$', 'includedir=${prefix}/include', txt)
        open(f'{stage}/lib/pkgconfig/{cand}', 'w').write(txt)

# headers: glib/glib/**/*.h from source (incl. deprecated/) + generated headers
def stage_headers(root, dest):
    if not os.path.isdir(root):
        return
    for dirpath, _, files in os.walk(root):
        for fn in files:
            if fn.endswith('.h'):
                rel = os.path.relpath(os.path.join(dirpath, fn), root)
                d = os.path.join(dest, os.path.dirname(rel))
                os.makedirs(d, exist_ok=True)
                shutil.copy(os.path.join(dirpath, fn), os.path.join(d, fn))

stage_headers(f'{src}/glib', f'{stage}/include/glib-2.0/glib')
stage_headers(f'{build}/glib', f'{stage}/include/glib-2.0/glib')

cfg = None
for cand in (f'{build}/glib/glibconfig.h',):
    if os.path.exists(cand):
        cfg = cand
if not cfg:
    sys.exit('glibconfig.h not generated')
shutil.copy(cfg, f'{stage}/include/glib-2.0/glibconfig.h')
shutil.copy(cfg, f'{stage}/lib/glib-2.0/include/glibconfig.h')

# umbrella header layout used by upstream installs
shutil.copy(f'{stage}/include/glib-2.0/glib/glib.h', f'{stage}/include/glib-2.0/glib.h')

# Prefer meson-generated glib-2.0.pc (authoritative static-link private libs:
# pcre2/iconv/frameworks as detected by the build); rewrite paths to staging.
gen_pc = f'{build}/meson-private/glib-2.0.pc'
if os.path.exists(gen_pc):
    text = open(gen_pc).read()
    import re
    # drop any absolute build/source prefix references, repoint at staging
    text = re.sub(r'(?m)^prefix=.*$', f'prefix={stage}', text)
    text = re.sub(r'(?m)^libdir=.*$', 'libdir=${prefix}/lib', text)
    text = re.sub(r'(?m)^includedir=.*$', 'includedir=${prefix}/include', text)
    # remove exec_prefix lines that point into the build tree if absolute
    text = text.replace('${bindir}', '${prefix}/bin')
    # glib core carries gosxutils.m.o (ObjC special-dirs helper referenced by
    # gutils.o); external C linkers must add the objc runtime explicitly.
    if '-lobjc' not in text:
        text = re.sub(r'(?m)^Libs: (.*)$', r'Libs: \1 -lobjc', text)
    open(f'{stage}/lib/pkgconfig/glib-2.0.pc', 'w').write(text)
    print('glib-2.0.pc sourced from meson-generated file (paths rewritten)')
else:
    with open(f'{stage}/lib/pkgconfig/glib-2.0.pc', 'w') as f:
        f.write(f"""prefix={stage}
libdir=${{prefix}}/lib
includedir=${{prefix}}/include

Name: GLib
Description: Core Application Library, GNU GLib
Version: 2.90.1
Cflags: -I${{includedir}}/glib-2.0 -I${{libdir}}/glib-2.0/include
Libs: -L${{libdir}} -lglib-2.0
Libs.private: -L${{libdir}} -lpcre2-8
""")
    print('glib-2.0.pc hand-written fallback')

print(f"staged glib core -> {stage}")
print(f"  lib: {glib_a}")
print(f"  pcre2: {pcre_a or 'NOT FOUND'}")
