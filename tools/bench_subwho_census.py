#!/usr/bin/env python3
"""CPU cost of the submit census (nvmtl_subwho_note) with and without its lock, in a host process.

This is a micro-benchmark of one bookkeeping function on the CPU. It says nothing about GPU time, frame time or FPS.

The locked function is lifted from plugin/nvmtl_vk.c; the unlocked one is the same function at 75e2e28 (from git), or,
when that revision is not in the history, the locked one with its lock calls removed. Both are built with the release
plugin's optimisation level (-O1) and run on 1 thread and on several threads, with 19 distinct callers (the number of
`who` labels the plugin passes) and with one caller. Each figure is wall time / calls, the median of the runs.
The unlocked function is a data race when threads share it: its threaded figures are given for comparison only, and the
"lost" column counts the submissions it dropped.

usage: python3 -I tools/bench_subwho_census.py [--calls N] [--runs R] [--threads 1,2,4] [--json out.json]
"""
import argparse
import json
import os
import pathlib
import platform
import re
import statistics
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
START = 'static struct { const char *who; uint64_t n; uint64_t ns; } g_subwho[24];'


def lift(text):
    start = text.index(START)
    return text[start:text.index('\n}\n', text.index('static void nvmtl_subwho_note(')) + 3]


locked = lift((root / 'plugin/nvmtl_vk.c').read_text())
assert 'g_subwho_lock' in locked, 'plugin/nvmtl_vk.c has no locked census'
try:
    old = subprocess.run(['git', '-C', str(root), 'show', '75e2e28:plugin/nvmtl_vk.c'], capture_output=True, text=True)
    unlocked, unlocked_from = (lift(old.stdout), '75e2e28') if old.returncode == 0 else (None, None)
except (FileNotFoundError, ValueError):
    unlocked, unlocked_from = None, None
if unlocked is None or 'g_subwho_lock' in unlocked:
    unlocked = re.sub(r'\n *pthread_mutex_(un)?lock\(&g_subwho_lock\);', '', locked).replace(' pthread_mutex_unlock(&g_subwho_lock);', '')
    unlocked_from = 'the locked function with its lock calls removed'
assert 'pthread_mutex_lock(&g_subwho_lock)' not in unlocked

fixture = r'''
#include <pthread.h>
#include <sched.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
static unsigned long long lines;
static void nvlog(const char *fmt, ...) { (void)fmt; __atomic_add_fetch(&lines, 1, __ATOMIC_RELAXED); }
static pthread_mutex_t g_subwho_lock_unused = PTHREAD_MUTEX_INITIALIZER;
HELPER
static char names[19][8]; static const char *who[19];
static unsigned T, K; static unsigned long long N; static unsigned ready;
static void *worker(void *arg) {
    const unsigned t = (unsigned)(uintptr_t)arg;
    __atomic_add_fetch(&ready, 1, __ATOMIC_ACQ_REL);
    while (__atomic_load_n(&ready, __ATOMIC_ACQUIRE) < T) sched_yield();
    for (unsigned long long j = 0; j < N; j++) nvmtl_subwho_note(who[(t + j) % K], 0);
    return NULL;
}
static double now(void) { struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts); return ts.tv_sec + ts.tv_nsec * 1e-9; }
int main(int argc, char **argv) {
    (void)g_subwho_lock_unused;
    if (argc != 4) return 2;
    T = (unsigned)atoi(argv[1]); K = (unsigned)atoi(argv[2]); N = strtoull(argv[3], NULL, 10) / T;
    for (unsigned i = 0; i < 19; i++) { snprintf(names[i], sizeof names[i], "w%02u", i); who[i] = names[i]; }
    pthread_t th[64]; if (T < 1 || T > 64 || K < 1 || K > 19) return 2;
    const double t0 = now();
    for (unsigned t = 0; t < T; t++) pthread_create(&th[t], NULL, worker, (void *)(uintptr_t)t);
    for (unsigned t = 0; t < T; t++) pthread_join(th[t], NULL);
    const double dt = now() - t0;
    unsigned long long counted = 0; for (unsigned i = 0; i < g_subwho_n; i++) counted += g_subwho[i].n;
    printf("%.3f %llu %llu\n", dt * 1e9 / ((double)N * T), (unsigned long long)N * T - counted, lines);
    return 0;
}
'''


def build(d, name, code):
    src = pathlib.Path(d) / (name + '.c')
    src.write_text(fixture.replace('HELPER', code))
    exe = pathlib.Path(d) / name
    cc = os.environ.get('CC', 'cc')
    c = subprocess.run([cc, '-std=gnu11', '-O1', '-pthread', '-o', str(exe), str(src)], capture_output=True, text=True)
    if c.returncode:
        raise SystemExit('%s does not build the %s variant:\n%s' % (cc, name, c.stderr[-1500:]))
    return exe


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--calls', type=int, default=4_000_000)
    ap.add_argument('--runs', type=int, default=7)
    ap.add_argument('--threads', default='1,2,4')
    ap.add_argument('--json')
    a = ap.parse_args()
    threads = [int(x) for x in a.threads.split(',')]
    cc = os.environ.get('CC', 'cc')
    ver = subprocess.run([cc, '--version'], capture_output=True, text=True).stdout.splitlines()[:1]
    print('CPU micro-benchmark of nvmtl_subwho_note only - NOT a GPU, frame-time or FPS benchmark.')
    print('host: %s %s, %d logical CPUs, compiler: %s' % (platform.system(), platform.machine(), os.cpu_count() or 0,
                                                          ver[0] if ver else cc))
    print('unlocked variant: %s; %d calls per figure, median of %d runs, -O1' % (unlocked_from, a.calls, a.runs))
    rows = []
    with tempfile.TemporaryDirectory() as d:
        exes = {'unlocked': build(d, 'unlocked', unlocked), 'locked': build(d, 'locked', locked)}
        print('%-9s %7s %7s %12s %12s %10s' % ('variant', 'threads', 'callers', 'ns/call med', 'ns/call min', 'lost'))
        for t in threads:
            for k in (19, 1):
                for name, exe in exes.items():
                    ns, lost = [], []
                    for _ in range(a.runs):
                        out = subprocess.run([str(exe), str(t), str(k), str(a.calls)], capture_output=True, text=True,
                                             timeout=600).stdout.split()
                        ns.append(float(out[0])); lost.append(int(out[1]))
                    row = {'variant': name, 'threads': t, 'callers': k, 'ns_median': statistics.median(ns),
                           'ns_min': min(ns), 'lost_max': max(lost)}
                    rows.append(row)
                    print('%-9s %7d %7d %12.2f %12.2f %10d' % (name, t, k, row['ns_median'], row['ns_min'], row['lost_max']))
    if a.json:
        pathlib.Path(a.json).write_text(json.dumps({'rows': rows, 'unlocked_from': unlocked_from, 'calls': a.calls,
                                                    'runs': a.runs}, indent=1))


if __name__ == '__main__':
    main()
