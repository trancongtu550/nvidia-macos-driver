#!/usr/bin/env python3
"""The submit census (nvmtl_subwho_note) is called by every submission: the execution worker and the encode threads that
upload surfaces and textures reach it before either takes nvmtl_submit_mutex, so the table and its counts need their own
lock. The real function is lifted from nvmtl_vk.c and run on threads.
Arms: 8 threads over 20 callers count every submission exactly and print one census line per 4096; 8 threads over 40
callers fill the table to its 24 entries and no further, each caller once, its count exact; the log line is written with
the lock released, so a log that submits again (re-entry) neither deadlocks nor finds the lock held. Under
ThreadSanitizer (when this machine has its runtime) the threaded arms must be race-free, and under AddressSanitizer the
table must stay in bounds.
Negative controls must fail: the function without its lock (ThreadSanitizer reports the race), one that logs with the lock
held, and one whose bound lets a 25th caller in.
Platforms: the fixture is plain C11 with pthreads (no pthread_barrier, which macOS lacks), so it builds with gcc or clang on
Linux and with Apple clang on macOS; $CC picks the compiler. A sanitizer arm is skipped only when a trivial program built
with that sanitizer does not run here; when the trivial program runs and the fixture does not build, the test fails."""
import os
import pathlib
import subprocess
import tempfile
import unittest

root = pathlib.Path(__file__).resolve().parents[1]
source = (root / 'plugin/nvmtl_vk.c').read_text()

start = source.index('static struct { const char *who; uint64_t n; uint64_t ns; } g_subwho[24];')
end = source.index('\n}\n', source.index('static void nvmtl_subwho_note(')) + 3
helper = source[start:end]
assert 'g_subwho_lock' in helper, 'the census has no lock of its own'
assert source.count('nvmtl_subwho_note(who, 0);') == 1, 'nvmtl_vk_submit_begin_at no longer notes its caller'

UNLOCK_LOG = ('    pthread_mutex_unlock(&g_subwho_lock);\n'
              '    if (census) nvlog("vk: submit census over %llu submissions - %s", (unsigned long long)total, line);\n')
assert UNLOCK_LOG in helper, 'the census line is no longer written after the unlock'
BOUND = 'if (g_subwho_n >= sizeof g_subwho / sizeof g_subwho[0])'
assert BOUND in helper, 'the table bound is no longer the size of the table'

nolock_control = helper.replace('    pthread_mutex_lock(&g_subwho_lock);\n', '').replace(' pthread_mutex_unlock(&g_subwho_lock);', '') \
                       .replace('    pthread_mutex_unlock(&g_subwho_lock);\n', '')
assert 'pthread_mutex_lock(&g_subwho_lock)' not in nolock_control and 'pthread_mutex_unlock(&g_subwho_lock)' not in nolock_control
loglocked_control = helper.replace(UNLOCK_LOG,
    '    if (census) nvlog("vk: submit census over %llu submissions - %s", (unsigned long long)total, line);\n'
    '    pthread_mutex_unlock(&g_subwho_lock);\n')
assert loglocked_control != helper
unbounded_control = helper.replace(BOUND, 'if (g_subwho_n > sizeof g_subwho / sizeof g_subwho[0])')
assert unbounded_control != helper

fixture = r'''
#include <pthread.h>
#include <sched.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
static pthread_mutex_t log_lock = PTHREAD_MUTEX_INITIALIZER;
static unsigned long long lines[4096]; static unsigned nlines; static int reenter, single;
static void log_check(void);
static void nvmtl_subwho_note(const char *who, uint64_t ns);
// Stands in for the driver's log: keeps the total each census line reports and, on the single-threaded arm, checks the
// census lock is not held and submits once more from inside the log call.
static void nvlog(const char *fmt, ...) {
    if (strcmp(fmt, "vk: submit census over %llu submissions - %s")) { printf("unexpected log format: %s\n", fmt); exit(4); }
    va_list ap; va_start(ap, fmt); unsigned long long total = va_arg(ap, unsigned long long); va_end(ap);
    if (single) log_check();
    pthread_mutex_lock(&log_lock); if (nlines < 4096) lines[nlines++] = total; pthread_mutex_unlock(&log_lock);
    if (reenter) { reenter = 0; nvmtl_subwho_note("from the log", 0); }
}
HELPER
static void log_check(void) {
    if (pthread_mutex_trylock(&g_subwho_lock)) { puts("the census lock is held while logging"); exit(3); }
    pthread_mutex_unlock(&g_subwho_lock);
}
#define NWHO 40
static char names[NWHO][8]; static const char *who[NWHO];
static unsigned T, N, K, mult; static unsigned ready;
static void *worker(void *arg) {
    const unsigned t = (unsigned)(uintptr_t)arg;
    // start together: every worker spins until all have arrived
    __atomic_add_fetch(&ready, 1, __ATOMIC_ACQ_REL);
    while (__atomic_load_n(&ready, __ATOMIC_ACQUIRE) < T) sched_yield();
    for (unsigned j = 0; j < N; j++) nvmtl_subwho_note(who[(t * mult + j) % K], 1);
    return NULL;
}
static void run(unsigned threads, unsigned calls, unsigned callers, unsigned m) {
    T = threads; N = calls; K = callers; mult = m; nlines = 0;
    memset(g_subwho, 0, sizeof g_subwho); g_subwho_n = 0;
    pthread_t th[16]; ready = 0;
    for (unsigned t = 0; t < T; t++) pthread_create(&th[t], NULL, worker, (void *)(uintptr_t)t);
    for (unsigned t = 0; t < T; t++) pthread_join(th[t], NULL);
}
static unsigned long long expected(const char *w) {
    unsigned long long e = 0;
    for (unsigned t = 0; t < T; t++) for (unsigned j = 0; j < N; j++) if (who[(t * mult + j) % K] == w) e++;
    return e;
}
static int cmp(const void *a, const void *b) {
    const unsigned long long x = *(const unsigned long long *)a, y = *(const unsigned long long *)b; return x < y ? -1 : x > y;
}
#define CHECK(c, msg) do { if (!(c)) { printf("FAILED: %s\n", msg); return 1; } } while (0)
int main(int argc, char **argv) {
    alarm(60);
    for (unsigned i = 0; i < NWHO; i++) { snprintf(names[i], sizeof names[i], "w%02u", i); who[i] = names[i]; }
    const char *arm = argc > 1 ? argv[1] : "";
    if (!strcmp(arm, "totals")) {
        run(8, 40960, 20, 7);
        unsigned long long sum = 0;
        CHECK(g_subwho_n == 20, "20 callers take 20 entries");
        for (unsigned i = 0; i < g_subwho_n; i++) {
            for (unsigned k = 0; k < i; k++) CHECK(g_subwho[k].who != g_subwho[i].who, "a caller has two entries");
            CHECK(g_subwho[i].n == expected(g_subwho[i].who), "a caller's count is off");
            CHECK(g_subwho[i].ns == g_subwho[i].n, "a caller's time is off");
            sum += g_subwho[i].n;
        }
        CHECK(sum == 8ull * 40960, "submissions were lost");
        qsort(lines, nlines, sizeof lines[0], cmp);
        printf("totals: %llu submissions, %u census line(s)\n", sum, nlines);
        CHECK(nlines == sum / 4096, "one census line per 4096 submissions");
        for (unsigned i = 0; i < nlines; i++) CHECK(lines[i] == 4096ull * (i + 1), "each census line reports its own multiple of 4096");
    } else if (!strcmp(arm, "bound")) {
        run(8, 4000, 40, 13);
        printf("bound: %u entries\n", g_subwho_n);
        CHECK(g_subwho_n == 24, "40 callers fill the table to 24 entries and no further");
        for (unsigned i = 0; i < g_subwho_n; i++) {
            for (unsigned k = 0; k < i; k++) CHECK(g_subwho[k].who != g_subwho[i].who, "a caller has two entries");
            CHECK(g_subwho[i].n == expected(g_subwho[i].who), "an admitted caller's count is off");
        }
    } else if (!strcmp(arm, "reenter")) {
        memset(g_subwho, 0, sizeof g_subwho); g_subwho_n = 0; nlines = 0; reenter = single = 1;
        for (unsigned j = 0; j < 4096; j++) nvmtl_subwho_note(who[0], 0);
        printf("reenter: %u census line(s), %u entries\n", nlines, g_subwho_n);
        CHECK(nlines == 1 && lines[0] == 4096, "the 4096th submission prints the census");
        CHECK(g_subwho_n == 2 && !strcmp(g_subwho[1].who, "from the log") && g_subwho[1].n == 1, "the log's own submission is counted");
    } else { puts("arm?"); return 2; }
    puts("ok");
    return 0;
}
'''

SAN_FAIL = ('ThreadSanitizer', 'AddressSanitizer')


def compilers():
    seen = []
    for c in (os.environ.get('CC'), 'cc', 'clang', 'gcc'):
        if c and c not in seen:
            seen.append(c)
    return seen


PROBE = 'int main(void) { return 0; }\n'


def sanitizer_compiler(d, sanitizer):
    """The first compiler whose trivial program builds and runs with this sanitizer, or None with the reasons."""
    src = pathlib.Path(d) / 'probe.c'
    src.write_text(PROBE)
    why = []
    for cc in compilers():
        exe = pathlib.Path(d) / ('probe-' + sanitizer)
        try:
            c = subprocess.run([cc, '-pthread', '-fsanitize=' + sanitizer, '-o', str(exe), str(src)], capture_output=True, text=True)
        except FileNotFoundError:
            continue
        if c.returncode:
            why.append('%s: %s' % (cc, c.stderr.strip()[-200:]))
            continue
        r = subprocess.run([str(exe)], capture_output=True, text=True, timeout=60)
        if r.returncode == 0:
            return cc, why
        why.append('%s: runtime does not start: %s' % (cc, (r.stdout + r.stderr).strip()[-200:]))
    return None, why


def build(d, code, sanitizer=None):
    """Compile the fixture. Returns (executable, compiler), or (None, reasons) only when no compiler here runs a trivial
    program with the sanitizer. A fixture that does not build where the trivial program does is an error, never a skip."""
    src = pathlib.Path(d) / 't.c'
    src.write_text(fixture.replace('HELPER', code))
    exe = pathlib.Path(d) / ('t-' + (sanitizer or 'plain'))
    flags = ['-std=gnu11', '-O1', '-g', '-pthread', '-Werror=implicit-function-declaration']
    if sanitizer:
        cc, why = sanitizer_compiler(d, sanitizer)
        if cc is None:
            return None, why
        candidates = [cc]
        flags.append('-fsanitize=' + sanitizer)
    else:
        candidates = compilers()
    errors = []
    for cc in candidates:
        try:
            c = subprocess.run([cc] + flags + ['-o', str(exe), str(src)], capture_output=True, text=True)
        except FileNotFoundError:
            continue
        if c.returncode:
            errors.append(cc + ': ' + c.stderr[-600:])
            continue
        probe = subprocess.run([str(exe), 'none'], capture_output=True, text=True, timeout=60)
        if probe.returncode == 2 and 'arm?' in probe.stdout:
            return exe, cc
        errors.append(cc + ': the fixture built but does not start: ' + (probe.stdout + probe.stderr)[-300:])
    raise AssertionError('the fixture does not build%s:\n%s' % (' with -fsanitize=' + sanitizer if sanitizer else '',
                                                                  '\n'.join(errors) or 'no C compiler found'))


def run(exe, arm):
    try:
        r = subprocess.run([str(exe), arm], capture_output=True, text=True, timeout=120)
    except subprocess.TimeoutExpired:
        return -1, 'TIMEOUT (deadlock?)'
    return r.returncode, r.stdout + r.stderr


class SubwhoCensus(unittest.TestCase):
    def arms(self, code, sanitizer, arms):
        with tempfile.TemporaryDirectory() as d:
            exe, cc = build(d, code, sanitizer)
            if exe is None:
                self.skipTest('no compiler here runs a trivial %s-sanitized program: %s' % (sanitizer, '; '.join(cc)))
            print('[%s, %s]' % (cc, sanitizer or 'no sanitizer'))
            return {arm: run(exe, arm) for arm in arms}

    def assert_pass(self, results):
        for arm, (rc, out) in results.items():
            print(arm, '->', out.strip().splitlines()[0] if out.strip() else rc)
            self.assertEqual(rc, 0, arm + ' failed:\n' + out[-2000:])
            self.assertTrue(out.rstrip().endswith('ok') and not any(s in out for s in SAN_FAIL), arm + ':\n' + out[-2000:])

    def test_shipped_plain(self):
        self.assert_pass(self.arms(helper, None, ('totals', 'bound', 'reenter')))

    def test_shipped_thread_sanitizer(self):
        self.assert_pass(self.arms(helper, 'thread', ('totals', 'bound', 'reenter')))

    def test_shipped_address_sanitizer(self):
        self.assert_pass(self.arms(helper, 'address', ('totals', 'bound', 'reenter')))

    def test_control_without_lock_races(self):
        rc, out = self.arms(nolock_control, 'thread', ('totals',))['totals']
        self.assertTrue(rc != 0 and 'ThreadSanitizer: data race' in out, 'the unlocked census raced unseen:\n' + out[-2000:])
        print('control fires (no lock: ThreadSanitizer reports the race)')

    def test_control_logging_under_lock(self):
        rc, out = self.arms(loglocked_control, None, ('reenter',))['reenter']
        self.assertTrue(rc != 0 and 'held while logging' in out, 'logging under the lock went unseen:\n' + out[-2000:])
        print('control fires (log written with the lock held)')

    def test_control_unbounded(self):
        rc, out = self.arms(unbounded_control, None, ('bound',))['bound']
        self.assertNotEqual(rc, 0, 'a 25th entry went unseen:\n' + out[-2000:])
        print('control fires (bound admits a 25th caller)')


if __name__ == '__main__':
    unittest.main(verbosity=2)
