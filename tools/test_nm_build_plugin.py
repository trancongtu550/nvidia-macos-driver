#!/usr/bin/env python3
"""tools/nm_build_plugin.sh builds the release plugin on a Mac; this checks it without one. Its compiler flags and
frameworks must be the ones build/build_plugin_release.sh passes (apart from the include directory), and the harness
tools/test_nm_build_plugin.sh drives it with fake Xcode tools. Needs bash and git only."""
import pathlib
import re
import shlex
import subprocess

root = pathlib.Path(__file__).resolve().parents[1]
release = (root / 'build/build_plugin_release.sh').read_text()
local = (root / 'tools/nm_build_plugin.sh').read_text()

line = re.search(r'xcrun clang (.*?)NVMTLDevice\.m(.*?)2>', release, re.S)
assert line, 'build_plugin_release.sh no longer has its clang line'
rel = shlex.split(line.group(1).replace('\\\n', ' '))
rel_flags = [f for f in rel if not f.startswith('-I') and f not in ('-o', '../out/NVMTLDriver')]
rel_fw = shlex.split(line.group(2).replace('\\\n', ' '))
ours = shlex.split(re.search(r'NM_FLAGS=\((.*?)\)', local, re.S).group(1))
ours_fw = shlex.split(re.search(r'NM_FRAMEWORKS=\((.*?)\)', local, re.S).group(1))
assert ours == rel_flags, 'flags differ from the release build:\n release %s\n ours    %s' % (rel_flags, ours)
assert ours_fw == rel_fw, 'frameworks differ from the release build:\n release %s\n ours    %s' % (rel_fw, ours_fw)
print('flags match build_plugin_release.sh:', ' '.join(ours), ' '.join(ours_fw))

r = subprocess.run(['bash', str(root / 'tools/test_nm_build_plugin.sh'), str(root / 'tools/nm_build_plugin.sh')],
                   capture_output=True, text=True, timeout=300)
print(r.stdout.strip().splitlines()[-1] if r.stdout.strip() else '(no output)')
assert r.returncode == 0 and ' 0 FAIL' in r.stdout, 'the build-script harness failed:\n' + r.stdout + r.stderr
