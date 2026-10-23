#!/usr/bin/env python3
"""debug.nvaccel_iop_async_flips is a subset of debug.nvaccel_iop_flips: the asynchronous swap that reaches the panel
increments both counters in the same statement (kexts/NVRM/accel/nvrm-accel.cpp), and the synchronous zero-copy swap
increments nvaccel_iop_flips alone. Flips per second are the delta of nvaccel_iop_flips; adding nvaccel_iop_async_flips
to it counts every asynchronous flip twice.
This checks the source still has that relation (so the guidance below stays true), and that no document or script in
the repository adds the two counters together. The pattern is tested on known good and bad lines first."""
import pathlib
import re

root = pathlib.Path(__file__).resolve().parents[1]
src = (root / 'kexts/NVRM/accel/nvrm-accel.cpp').read_text()

# 1. the source: every increment of the async counter sits right after an increment of the flip counter
async_incs = [m.start() for m in re.finditer(r'OSAddAtomic64\(1, &gCntIopAsync\)', src)]
both = re.findall(r'OSAddAtomic64\(1, &gCntIopFlip\);\s*OSAddAtomic64\(1, &gCntIopAsync\);', src)
assert async_incs and len(both) == len(async_incs), \
    'nvaccel_iop_async_flips is no longer always counted together with nvaccel_iop_flips: re-read nvrm-accel.cpp'
assert re.search(r'NVACCEL_CNT\(nvaccel_iop_flips,\s*gCntIopFlip,', src) and \
       re.search(r'NVACCEL_CNT\(nvaccel_iop_async_flips,\s*gCntIopAsync,', src), 'the sysctl names moved'
print('source: %d increment(s) of nvaccel_iop_async_flips, each in the same statement as nvaccel_iop_flips' % len(async_incs))

# 2. nothing adds the two together
SUM = re.compile(r'\biop_flips\b[^+\n]{0,12}\+[^+\n]{0,24}\biop_async_flips\b'
                 r'|\biop_async_flips\b[^+\n]{0,12}\+[^+\n]{0,24}\biop_flips\b'
                 r'|nvaccel_iop_flips\b[^+\n]{0,12}\+[^+\n]{0,24}nvaccel_iop_async_flips'
                 r'|nvaccel_iop_async_flips\b[^+\n]{0,12}\+[^+\n]{0,24}nvaccel_iop_flips\b')
bad_lines = ['flip/s (`nvaccel_iop_flips` + `nvaccel_iop_async_flips`)', 'debug.nvaccel_iop_async_flips + debug.nvaccel_iop_flips',
             'd = a["nvaccel_iop_flips"] + a["nvaccel_iop_async_flips"]']
good_lines = ['flip/s = delta `nvaccel_iop_flips` / T', '`nvaccel_iop_async_flips` (a subset of `nvaccel_iop_flips`)',
              'NM_KEYS="debug.nvaccel_iop_flips debug.nvaccel_iop_async_flips"']
assert all(SUM.search(l) for l in bad_lines) and not any(SUM.search(l) for l in good_lines), 'the pattern itself is wrong'

found = []
for p in sorted(root.rglob('*')):
    if not p.is_file() or '.git' in p.parts or 'translator' in p.parts or p.name == pathlib.Path(__file__).name:
        continue
    if p.suffix not in ('.md', '.sh', '.py', '.txt') and p.name != 'README':
        continue
    for n, line in enumerate(p.read_text(errors='replace').splitlines(), 1):
        if SUM.search(line):
            found.append('%s:%d: %s' % (p.relative_to(root), n, line.strip()))
assert not found, 'nvaccel_iop_async_flips is added to nvaccel_iop_flips (counts async flips twice):\n' + '\n'.join(found)
print('no document or script adds nvaccel_iop_async_flips to nvaccel_iop_flips')
