#!/usr/bin/env python3
"""Release builds return early from three debug-request polls on the encode path (nvmtl_surface_cpu_dump on every
fragment texture bind, nvmtl_pt_armed on every render pass, nvmtl_noseed on every surface-out) instead of reading the
clock and asking for a request file. That is the same result: in release builds `access` is nvmtl_rel_access
(plugin/NVMTLDevice.m), which refuses every /tmp/nvmtl- path, so these polls could never turn on.
Checks: every path the three functions poll is one nvmtl_rel_devpath refuses (its real code, compiled); each function
starts with the release return; nvmtl_noseed and nvmtl_pt_armed, compiled from the plugin source with the request files
present, return the same in a release build with and without the early return, and a development build still turns
on. Negative controls: an early return outside #if NVMTL_RELEASE (development builds would lose the polls) and a
refusal that misses one of the paths must each be caught. Needs a C compiler only."""
import os
import pathlib
import re
import shutil
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
dev = (root / 'plugin/NVMTLDevice.m').read_text()
objs = (root / 'plugin/NVMTLObjects.m').read_text()
vk = (root / 'plugin/nvmtl_vk.c').read_text()


def body(text, head, end='\n}\n'):
    i = text.index(head)
    return text[i:text.index(end, i) + len(end)]


rel = dev[dev.index('static inline int nvmtl_rel_devpath('):dev.index('static inline FILE *nvmtl_rel_fopen(')]
assert '#define access(p, m) nvmtl_rel_access(p, m)' in dev, 'release builds no longer route access() through nvmtl_rel_access'
funcs = {
    'nvmtl_surface_cpu_dump': body(objs, 'static void nvmtl_surface_cpu_dump(NVMTLTexture *rt) {'),
    'nvmtl_noseed': body(objs, 'static int nvmtl_noseed(void) {', '    return on; }\n'),
    'nvmtl_pt_armed': body(vk, 'int nvmtl_pt_armed(void)\n{'),
}
EARLY = re.compile(r'^([^{]*\{\n)#if NVMTL_RELEASE\n    [^\n]*return[^\n]*\n#endif\n')
for name, text in funcs.items():
    assert EARLY.match(text), name + ' does not start with the release return'
paths = sorted({p for t in funcs.values() for p in re.findall(r'access\("([^"]+)"', t)})
assert paths, 'no polled paths found'

CHECK = r'''
#include <stdio.h>
#include <string.h>
#include <unistd.h>
@REL@
int main(void) { const char *p[] = { @PATHS@ }; int bad = 0;
    for (unsigned i = 0; i < sizeof p / sizeof p[0]; i++) if (!nvmtl_rel_devpath(p[i])) { printf("NOT refused: %s\n", p[i]); bad = 1; }
    return bad; }
'''

FIXTURE = r'''
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#define CLOCK_MONOTONIC_RAW 4
static uint64_t fake_now;
static uint64_t clock_gettime_nsec_np(int c) { (void)c; return fake_now += 300000000ull; }   // past every 250 ms re-check
static void nvlog(const char *f, ...) { (void)f; }
static int stub_unlink(const char *p) { (void)p; return 0; }
#define unlink stub_unlink
static int stub_access(const char *p, int m) { (void)p; (void)m; return 0; }   // every request file is present
#define access stub_access
@REL@
#undef access
#if NVMTL_RELEASE
#define access(p, m) nvmtl_rel_access(p, m)
#else
#define access(p, m) stub_access(p, m)
#endif
static int g_pt_left;
@FUNCS@
int main(void) { int on = 0;
    for (int i = 0; i < 100; i++) on |= nvmtl_noseed() << 1 | nvmtl_pt_armed();
    printf("%d\n", on); return 0; }
'''


def cc():
    c = os.environ.get('CC') or shutil.which('cc') or shutil.which('clang') or shutil.which('gcc')
    assert c, 'no C compiler'
    return c


def run(src, *flags):
    with tempfile.TemporaryDirectory() as d:
        s = pathlib.Path(d) / 't.c'
        s.write_text(src)
        exe = pathlib.Path(d) / 't'
        c = subprocess.run([cc(), '-std=gnu11', '-w', *flags, '-o', str(exe), str(s)], capture_output=True, text=True)
        assert c.returncode == 0, c.stderr[-2000:]
        r = subprocess.run([str(exe)], capture_output=True, text=True, timeout=60)
        return r.returncode, r.stdout.strip()


def refused(rel_text):
    return run(CHECK.replace('@REL@', rel_text).replace('@PATHS@', ', '.join('"%s"' % p for p in paths)))[0] == 0


def polls(noseed, pt, release):
    return int(run(FIXTURE.replace('@REL@', rel).replace('@FUNCS@', noseed + pt), '-DNVMTL_RELEASE=%d' % release)[1])


def strip_early(t):
    return EARLY.sub(lambda m: m.group(1), t, count=1)


assert refused(rel), 'a polled path is not refused in release builds'
print('release refuses every polled path:', ', '.join(paths))
noseed, pt = funcs['nvmtl_noseed'], funcs['nvmtl_pt_armed']
shipped_rel, polled_rel = polls(noseed, pt, 1), polls(strip_early(noseed), strip_early(pt), 1)
shipped_dev = polls(noseed, pt, 0)
print('request files present: release %d with the early return, %d polling as before; development build %d' % (
    shipped_rel, polled_rel, shipped_dev))
assert shipped_rel == polled_rel == 0, 'the early return changes what a release build answers'
assert shipped_dev == 3, 'a development build must still turn both on'

# negative controls
always = lambda t: t.replace('#if NVMTL_RELEASE\n', '', 1).replace('\n#endif\n', '\n', 1)
assert polls(always(noseed), always(pt), 0) != 3, 'control: an unconditional early return went unseen'
print('control fires (early return outside #if NVMTL_RELEASE)')
narrow = rel.replace('!strncmp(p, "/tmp/nvmtl-", 11)', '!strncmp(p, "/tmp/nvmtl-trace", 16)')
assert narrow != rel and not refused(narrow), 'control: a refusal that misses a path went unseen'
print('control fires (refusal that misses a polled path)')
print('release debug polls: all arms pass')
