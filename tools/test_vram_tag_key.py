#!/usr/bin/env python3
"""The IOSurface tag key (nvmtl_vram_tag_key, plugin/NVMTLDevice.m) is made once per plane 0-3 instead of on every tag
read. The real function is lifted and built against a counting stand-in for the few CoreFoundation calls it makes.
Arms: every plane's key reads "NVMTLVramAt:p<plane>"; callers that CFRelease what they get, as all four in
NVMTLDevice.m do, leave exactly one key alive per cached plane and nothing for planes 4 and up (no leak, no extra
release); 8 threads asking at once publish one key per plane (plain, and under ThreadSanitizer and AddressSanitizer when
this machine runs them). Negative controls must fail: a key handed out without CFRetain (the callers' CFRelease frees
it) and one published with a plain store (two threads both keep theirs: a leak). Needs a C compiler only."""
import os
import pathlib
import re
import shutil
import subprocess
import tempfile
import unittest

root = pathlib.Path(__file__).resolve().parents[1]
source = (root / 'plugin/NVMTLDevice.m').read_text()
start = source.index('#define NVMTL_VRAM_TAG_KEYS 4')
end = source.index('\n}\n', source.index('static CFStringRef nvmtl_vram_tag_key(NSUInteger plane)')) + 3
helper = source[start:end]
callers = re.findall(r'CFStringRef k = nvmtl_vram_tag_key\(plane\);.*?\n\}', source, re.S)   # to the end of each caller
assert len(callers) == 4 and all('CFRelease(k)' in c for c in callers), 'every caller releases the key it gets'
assert source.count('nvmtl_vram_tag_key(') == 5

fixture = r'''
#include <pthread.h>
#include <sched.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
typedef unsigned long NSUInteger;
// As in CoreFoundation, a CFStringRef points at a const object. A CFSTR literal is its own immutable static object,
// initialised at compile time and never written (CFRetain and CFRelease leave immortal objects alone before touching
// anything), so threads share nothing writable through it. Only strings made at run time are counted and freed.
struct S { int refs; int immortal; char text[48]; };
typedef const struct S *CFStringRef;
typedef const void *CFTypeRef;
#define CFSTR(s) ({ static const struct S cfstr_ = { 1, 1, s }; (CFStringRef)&cfstr_; })
static long live, made;
static CFStringRef CFStringCreateWithFormat(void *a, void *o, CFStringRef fmt, ...) {
    (void)a; (void)o; struct S *s = calloc(1, sizeof *s); va_list ap; va_start(ap, fmt);
    vsnprintf(s->text, sizeof s->text, fmt->text, ap); va_end(ap);   // the plugin's own format string
    s->refs = 1; __atomic_add_fetch(&live, 1, __ATOMIC_RELAXED); __atomic_add_fetch(&made, 1, __ATOMIC_RELAXED); return s; }
static CFTypeRef CFRetain(CFTypeRef p) { struct S *s = (struct S *)p; if (s->immortal) return p;
    if (__atomic_fetch_add(&s->refs, 1, __ATOMIC_ACQ_REL) <= 0) { puts("FAILED: retain of a freed key"); exit(3); } return p; }
static void CFRelease(CFTypeRef p) { struct S *s = (struct S *)p; if (s->immortal) return;
    int r = __atomic_sub_fetch(&s->refs, 1, __ATOMIC_ACQ_REL);
    if (r < 0) { puts("FAILED: key released more often than retained"); exit(3); }
    if (r == 0) { __atomic_sub_fetch(&live, 1, __ATOMIC_RELAXED); free(s); } }
HELPER
// a caller as in NVMTLDevice.m: get the key, use it, release it
static int use(NSUInteger plane) { CFStringRef k = nvmtl_vram_tag_key(plane); char want[48]; snprintf(want, sizeof want, "NVMTLVramAt:p%lu", plane);
    int ok = k && !strcmp(k->text, want) && __atomic_load_n(&k->refs, __ATOMIC_ACQUIRE) > 0; CFRelease(k); return ok; }
static unsigned ready;
static void *worker(void *arg) { (void)arg; __atomic_add_fetch(&ready, 1, __ATOMIC_ACQ_REL);
    while (__atomic_load_n(&ready, __ATOMIC_ACQUIRE) < 8) sched_yield();
    for (int j = 0; j < 20000; j++) if (!use((NSUInteger)(j % 7))) { puts("FAILED: wrong key"); exit(3); }
    return NULL; }
int main(int argc, char **argv) {
    if (argc > 1 && !strcmp(argv[1], "threads")) {
        pthread_t th[8]; for (int t = 0; t < 8; t++) pthread_create(&th[t], NULL, worker, NULL);
        for (int t = 0; t < 8; t++) pthread_join(th[t], NULL);
    } else {
        for (int round = 0; round < 1000; round++) for (NSUInteger p = 0; p < 10; p++) if (!use(p)) { printf("FAILED: wrong key for plane %lu\n", p); return 1; }
    }
    printf("keys alive after the callers released theirs: %ld (made %ld)\n", live, made);
    if (live != 4) { puts("FAILED: one key per cached plane must stay, and nothing else"); return 1; }
    puts("ok"); return 0;
}
'''

assert 'strcpy' not in fixture and '#define CFSTR(s) ({ static const struct S cfstr_' in fixture, \
    'CFSTR must be an immutable object of its own, never written by the threads that share it'


def compilers():
    out = []
    for c in (os.environ.get('CC'), 'cc', 'clang', 'gcc'):
        if c and c not in out and shutil.which(c):
            out.append(c)
    return out


def sanitizer_cc(d, san):
    p = pathlib.Path(d) / 'p.c'
    p.write_text('int main(void) { return 0; }\n')
    for cc in compilers():
        exe = pathlib.Path(d) / ('p-' + san)
        if subprocess.run([cc, '-pthread', '-fsanitize=' + san, '-o', str(exe), str(p)], capture_output=True).returncode == 0 \
           and subprocess.run([str(exe)], capture_output=True).returncode == 0:
            return cc
    return None


def build_run(code, arm, san=None, werror=True):
    with tempfile.TemporaryDirectory() as d:
        cc = sanitizer_cc(d, san) if san else (compilers() or [None])[0]
        if cc is None:
            raise unittest.SkipTest('no compiler here runs a trivial %s-sanitized program' % san if san else 'no C compiler')
        src = pathlib.Path(d) / 't.c'
        src.write_text(fixture.replace('HELPER', code))
        exe = pathlib.Path(d) / 't'
        # -Werror: a write through a const CFStringRef (or any other warning) fails the build with gcc and clang alike
        # (the negative controls are mutated on purpose and may leave unused variables: they build without -Werror)
        flags = ['-std=gnu11', '-O1', '-g', '-pthread', '-Wall', '-Wno-format-nonliteral'] + (['-Werror'] if werror else []) \
                + (['-fsanitize=' + san] if san else [])
        c = subprocess.run([cc] + flags + ['-o', str(exe), str(src)], capture_output=True, text=True)
        if c.returncode:
            raise AssertionError('the fixture does not build with %s: %s' % (cc, c.stderr[-1500:]))
        print('[%s, %s, %s]' % (cc, san or 'no sanitizer', arm))
        r = subprocess.run([str(exe), arm], capture_output=True, text=True, timeout=120)
        return r.returncode, r.stdout + r.stderr


class VramTagKey(unittest.TestCase):
    def ok(self, rc, out):
        print(out.strip().splitlines()[0] if out.strip() else rc)
        self.assertEqual(rc, 0, out[-2000:])
        self.assertTrue(out.rstrip().endswith('ok') and 'Sanitizer' not in out, out[-2000:])

    def test_keys(self):
        self.ok(*build_run(helper, 'single'))

    def test_threads(self):
        self.ok(*build_run(helper, 'threads'))

    def test_threads_thread_sanitizer(self):
        self.ok(*build_run(helper, 'threads', 'thread'))

    def test_threads_address_sanitizer(self):
        self.ok(*build_run(helper, 'threads', 'address'))

    def test_control_no_retain(self):
        bad = helper.replace('return (CFStringRef)CFRetain(k);', 'return k;')
        self.assertNotEqual(bad, helper)
        rc, out = build_run(bad, 'single', werror=False)
        self.assertNotEqual(rc, 0, 'a key handed out without CFRetain went unseen:\n' + out)
        print('control fires (no CFRetain)')

    def test_control_plain_store(self):
        bad = helper.replace('''        if (__atomic_compare_exchange_n(&keys[plane], &seen, made, 0, __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE)) k = made;
        else { CFRelease(made); k = seen; }''', '''        for (volatile int spin = 0; spin < 20000; spin++) {}
        keys[plane] = made; k = made;''')
        self.assertNotEqual(bad, helper)
        rc, out = build_run(bad, 'threads', werror=False)
        self.assertNotEqual(rc, 0, 'a racing plain store went unseen:\n' + out)
        print('control fires (plain store: %s)' % out.strip().splitlines()[0])


if __name__ == '__main__':
    unittest.main(verbosity=2)
