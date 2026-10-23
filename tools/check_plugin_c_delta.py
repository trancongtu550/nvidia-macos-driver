#!/usr/bin/env python3
"""Diagnostics a change adds to plugin/nvmtl_vk.c, without macOS.

usage: python3 -I tools/check_plugin_c_delta.py <base-rev> --vulkan-headers <dir> [--file plugin/nvmtl_vk.c]

nvmtl_vk.c is part of an Objective-C translation unit (plugin/NVMTLDevice.m includes it) and needs macOS headers, so it
cannot be compiled on Linux. This parses the file at <base-rev> and in the working tree with clang -fsyntax-only, the
same Khronos Vulkan headers and the same empty stand-ins for the missing macOS headers, and compares the diagnostics by
message and source text (not line number). Any diagnostic the working tree has and the base does not is printed and the
exit status is 1. It is a partial check only: code after an unrecoverable parse error, and anything that depends on the
real macOS declarations, is not checked; the macOS build (tools/nm_build_plugin.sh) is the real one.
"""
import argparse
import collections
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
STUBS = ('mach-o/loader.h', 'mach-o/nlist.h', 'mach/mach.h', 'IOKit/IOKitLib.h', 'sys/sysctl.h')


def diagnostics(plugin_dir, rel, vk, stubs, cc):
    r = subprocess.run([cc, '-fsyntax-only', '-ferror-limit=0', '-std=gnu11', '-I', str(plugin_dir), '-I', stubs, '-I', vk,
                        str(plugin_dir / pathlib.Path(rel).name)], capture_output=True, text=True)
    texts, out = {}, collections.Counter()
    for m in re.finditer(r'^([^\n:]*):(\d+):\d+: (error|warning): ([^\n]*)', r.stderr, re.M):
        path, line = pathlib.Path(m.group(1)), int(m.group(2))
        if path not in texts:
            texts[path] = path.read_text(errors='replace').splitlines() if path.is_file() else []
        text = texts[path]
        src = text[line - 1].strip() if 0 < line <= len(text) else ''
        out[(path.name, m.group(3), m.group(4), src)] += 1
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('base')
    ap.add_argument('--vulkan-headers', required=True, help='the include/ directory of Khronos Vulkan-Headers')
    ap.add_argument('--file', default='plugin/nvmtl_vk.c')
    a = ap.parse_args()
    cc = shutil.which('clang')
    if not cc:
        sys.exit('clang is required')
    with tempfile.TemporaryDirectory() as d:
        d = pathlib.Path(d)
        stubs = d / 'stubs'
        for h in STUBS:
            (stubs / h).parent.mkdir(parents=True, exist_ok=True)
            (stubs / h).write_text('')
        base = d / 'base'
        base.mkdir()
        arc = subprocess.run(['git', '-C', str(root), 'archive', a.base, 'plugin'], capture_output=True)
        if arc.returncode:
            sys.exit('git archive %s failed: %s' % (a.base, arc.stderr.decode()[-300:]))
        subprocess.run(['tar', 'x', '-C', str(base)], input=arc.stdout, check=True)
        before = diagnostics(base / 'plugin', a.file, a.vulkan_headers, str(stubs), cc)
        after = diagnostics(root / 'plugin', a.file, a.vulkan_headers, str(stubs), cc)
    new = after - before
    print('%s: %d diagnostics at %s, %d in the working tree, %d new' % (a.file, sum(before.values()), a.base,
                                                                       sum(after.values()), sum(new.values())))
    for (name, kind, msg, src), n in sorted(new.items()):
        print('NEW %s in %s (%d): %s\n    %s' % (kind, name, n, msg, src))
    sys.exit(1 if new else 0)


if __name__ == '__main__':
    main()
