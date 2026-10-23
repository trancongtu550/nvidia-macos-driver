#!/usr/bin/env python3
"""Run every tools/test_*.py of a checkout and classify each result.

usage: python3 -I tools/run_tool_tests.py <checkout> [--json out.json]

PASS     the test exited 0 and skipped nothing
SKIP     the test exited 0 but unittest reported skipped cases
MISSING  the test could not run here; the reason names the missing dependency (macOS tools, a commit that is not in
         the public history, a translator build). This is not a verdict on the code.
DEPFAIL  assertions failed AND the output shows a missing dependency: probably a consequence of it, but this has to be
         confirmed by reading the failing cases (the runner cannot tell)
FAIL     anything else; the last output lines are kept

The patterns below are the messages the tests print when a dependency is absent. A test that prints one of them and
also fails an assertion is DEPFAIL, never MISSING: only a person reading the failing cases may decide it was the
dependency alone.
"""
import json, os, re, subprocess, sys

DEPENDENCY = [
    (r"No such file or directory: 'xcrun'|xcrun: command not found", "xcrun (macOS SDK)"),
    (r"ditto: command not found|No such file or directory: 'ditto'", "ditto (macOS)"),
    (r"-framework', '(Foundation|Metal|IOKit|CoreFoundation)'|framework not found|"
     r"(Foundation|Metal)/(Foundation|Metal)\.h' file not found|#import <Foundation", "Foundation/Metal (macOS SDK)"),
    (r"policy\.c', '-o'", "macOS headers for the C fixture"),
    (r"Build the translator first", "translator build (cargo + spirv dependency)"),
    (r"show', '[0-9a-f]{7,}:", "a commit absent from the public history"),
    (r"negative control is UNKNOWN", "an older revision for the negative control"),
]


def classify(rc, out):
    if rc == 0:
        m = re.search(r"OK \(skipped=(\d+)\)", out)
        return ("SKIP", f"{m.group(1)} case(s) skipped") if m else ("PASS", "")
    reasons = [why for pat, why in DEPENDENCY if re.search(pat, out)]
    assertion = re.search(r"AssertionError|^FAIL:", out, re.M)
    if reasons and not assertion:
        return "MISSING", "; ".join(dict.fromkeys(reasons))
    if reasons and assertion:
        return "DEPFAIL", "assertions failed with missing: " + "; ".join(dict.fromkeys(reasons))
    tail = " | ".join(l.strip() for l in out.strip().splitlines()[-2:])
    return "FAIL", tail[:200]


def main():
    root = os.path.abspath(sys.argv[1])
    out_json = sys.argv[sys.argv.index("--json") + 1] if "--json" in sys.argv else None
    tests = sorted(f for f in os.listdir(os.path.join(root, "tools")) if f.startswith("test_") and f.endswith(".py"))
    results = []
    for t in tests:
        try:
            p = subprocess.run([sys.executable, "-I", os.path.join(root, "tools", t)], cwd=root,
                               capture_output=True, text=True, timeout=300)
            rc, out = p.returncode, p.stdout + p.stderr
        except subprocess.TimeoutExpired:
            rc, out = -1, "TIMEOUT after 300 s"
        status, why = classify(rc, out)
        results.append({"test": t, "status": status, "rc": rc, "reason": why})
        print(f"{status:8} {t:45} {why}")
    counts = {}
    for r in results:
        counts[r["status"]] = counts.get(r["status"], 0) + 1
    print("TOTAL", len(results), " ".join(f"{k}={v}" for k, v in sorted(counts.items())))
    if out_json:
        with open(out_json, "w") as f:
            json.dump({"root": root, "results": results, "counts": counts}, f, indent=1)


if __name__ == "__main__":
    main()
