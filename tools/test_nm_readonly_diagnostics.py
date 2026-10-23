#!/usr/bin/env python3
"""tools/nm_readonly_diagnostics.sh changes nothing on the machine it reads, so it is checked here on simulated reads: the
harness tools/test_nm_readonly_diagnostics.sh sources it and drives its functions with fake sysctl, log and date. Needs
bash only (no macOS). The unreadable-conf case is skipped when run as root."""
import pathlib
import subprocess

root = pathlib.Path(__file__).resolve().parents[1]
r = subprocess.run(['bash', str(root / 'tools/test_nm_readonly_diagnostics.sh'), str(root / 'tools/nm_readonly_diagnostics.sh')],
                   capture_output=True, text=True, timeout=120)
print(r.stdout.strip().splitlines()[-1] if r.stdout.strip() else '(no output)')
assert r.returncode == 0 and ' 0 FAIL' in r.stdout, 'the diagnostics harness failed:\n' + r.stdout + r.stderr
