#!/bin/bash
# test_nm_build_plugin.sh <script>: checks tools/nm_build_plugin.sh with fake Xcode tools (no macOS needed): the release
# flags reach the compiler, the output directory rules (system locations reached through ".." or symbolic links, dangling
# links, files, nothing left behind when a check or a mkdir fails), --vk-include made absolute before the compiler's cd,
# every artifact check failing on its own bad input, the reproducibility comparison, and check-installed reading a fake
# installed tree without changing it and exiting 1 for a missing file, an unreadable one or an absent required symbol.
# Run by tools/test_nm_build_plugin.py.
SCRIPT=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS  $1"; }
bad() { fail=$((fail+1)); echo "FAIL  $1"; echo "----- output:"; printf '%s\n' "$2"; echo "-----"; }
has()   { if printf '%s\n' "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1 (missing: $3)" "$2"; fi; }
hasnt() { if printf '%s\n' "$2" | grep -qF -- "$3"; then bad "$1 (must not have: $3)" "$2"; else ok "$1"; fi; }
rcis()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (rc $2, want $3)" "$4"; fi; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
FB=$T/bin; mkdir -p "$FB" "$T/vk/vulkan"
echo '#define VK_HEADER_VERSION 300' > "$T/vk/vulkan/vulkan_core.h"
# the fake binary: every live-feature marker of build/build_plugin.sh, none of the release-excluded diagnostics
awk '/<<.M.$/{on=1; next} on && /^M$/{exit} on' "$(dirname "$SCRIPT")/../build/build_plugin.sh" |
  awk -F'|' '$1!="fps file" && $1!="passtime instrument" {print $2}' > "$T/good.bin"
cat > "$FB/xcrun" <<'EOF'
#!/bin/bash
case "$*" in
  "clang --version") echo "Apple clang version 16.0.0 (fake)"; exit 0 ;;
  --show-sdk-version) echo 15.2; exit 0 ;; --show-sdk-path) echo /fake/sdk; exit 0 ;;
esac
echo "$*" >> "$FAKE_LOG"
[ "${FAKE_CC_FAIL:-0}" = 1 ] && { echo "NVMTLDevice.m:1:1: error: injected" >&2; exit 1; }
out=; while [ $# -gt 0 ]; do [ "$1" = -o ] && out=$2; shift; done
cp "$FAKE_CONTENT" "$out"; [ "${FAKE_RANDOM:-0}" = 1 ] && echo "$RANDOM$RANDOM" >> "$out"
echo "NVMTLDevice.m:2:2: warning: fake" >&2; exit 0
EOF
cat > "$FB/lipo" <<'EOF'
#!/bin/bash
echo "${FAKE_ARCH:-x86_64}"
EOF
cat > "$FB/vtool" <<'EOF'
#!/bin/bash
printf 'Load command 9\n      cmd LC_BUILD_VERSION\n platform MACOS\n    minos %s\n      sdk 15.2\n' "${FAKE_MINOS:-15.0}"
EOF
cat > "$FB/otool" <<'EOF'
#!/bin/bash
case $1 in
  -h) printf '%s:\nMach header\n      magic  cputype cpusubtype  caps    filetype ncmds sizeofcmds      flags\n 0xfeedfacf 16777223          3  0x00           %s    20       2000 0x00200085\n' "$2" "${FAKE_FTYPE:-8}" ;;
  -L) printf '%s:\n\t/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation (compatibility version 300.0.0)\n\t/usr/lib/libobjc.A.dylib (compatibility version 1.0.0)\n' "$2"
      [ -n "${FAKE_EXTRA_LIB:-}" ] && printf '\t%s (compatibility version 1.0.0)\n' "$FAKE_EXTRA_LIB" ;;
  -l) echo "     uuid 11111111-2222-3333-4444-$(sha256sum "$2" | cut -c1-12)" ;;
esac
EOF
cat > "$FB/nm" <<'EOF'
#!/bin/bash
f=${@: -1}
grep -q CORRUPT "$f" 2>/dev/null && { echo "nm: error: $f: truncated or malformed object" >&2; exit 1; }
[ -f "$f.syms" ] && sed 's/^/0000000000001000 T _/' "$f.syms"; exit 0
EOF
# mkdir that fails for one directory name (FAKE_MKDIR_FAIL), to check that a half-made output path is removed again
REAL_MKDIR=$(command -v mkdir); export REAL_MKDIR
cat > "$FB/mkdir" <<'EOF'
#!/bin/bash
for a in "$@"; do [ -n "${FAKE_MKDIR_FAIL:-}" ] && [ "$(basename -- "$a")" = "$FAKE_MKDIR_FAIL" ] && { echo "mkdir: $a: injected" >&2; exit 1; }; done
exec "$REAL_MKDIR" "$@"
EOF
cat > "$FB/shasum" <<'EOF'
#!/bin/bash
sha256sum "${@: -1}"
EOF
printf '#!/bin/bash\necho 15.5\n' > "$FB/sw_vers"
printf '#!/bin/bash\necho /Applications/Xcode.app/Contents/Developer\n' > "$FB/xcode-select"
chmod +x "$FB"/*
export PATH="$FB:$PATH" FAKE_LOG=$T/cc.log FAKE_CONTENT=$T/good.bin
run() { out=$(bash "$SCRIPT" "$@" 2>&1); rc=$?; }

echo "== usage and refusals"
run; rcis "no mode: usage, rc 2" $rc 2 "$out"
run build HEAD /Library/nm-out --vk-include "$T/vk"; has "refuses /Library" "$out" "a system location"
[ ! -e /Library/nm-out ] && ok "nothing created under /Library" || bad "created /Library/nm-out" ""
run build HEAD /usr/local/nm-out --vk-include "$T/vk"; has "refuses /usr" "$out" "a system location"
mkdir -p "$T/full"; touch "$T/full/x"
run build HEAD "$T/full" --vk-include "$T/vk"; has "refuses a non-empty output directory" "$out" "is not empty"
run build HEAD "$T/o0"; has "requires --vk-include" "$out" "--vk-include <dir> is required"
run build HEAD "$T/o0" --vk-include "$T"; has "requires vulkan_core.h" "$out" "no vulkan/vulkan_core.h"
run build no-such-rev-xyz "$T/o0" --vk-include "$T/vk"; has "refuses an unknown revision" "$out" "is not a commit"

echo "== output directory: checked through '..' and symbolic links before anything is created"
gone() { if [ ! -e "$2" ] && [ ! -L "$2" ]; then ok "$1"; else bad "$1 ($2 exists)" "$out"; fi; }
run build HEAD "$T/n1/../x" --vk-include "$T/vk"; has "'..' below the existing part refused" "$out" "'..' in a part of the path that does not exist yet"
rcis "'..' below the existing part: rc 1" $rc 1 "$out"; gone "  and $T/n1 not created" "$T/n1"; gone "  and $T/x not created" "$T/x"
run build HEAD "$T/n2/./x" --vk-include "$T/vk"; has "'.' below the existing part refused" "$out" "'.' in a part of the path"; gone "  and $T/n2 not created" "$T/n2"
up=$(printf '../%.0s' $(seq 1 $(printf '%s' "$T" | tr -cd / | wc -c)))
run build HEAD "$T/${up}Library/nm-dotdot" --vk-include "$T/vk"; has "'..' climbing into /Library refused" "$out" "resolves to /Library/nm-dotdot, a system location"
gone "  and /Library/nm-dotdot not created" /Library/nm-dotdot
ln -s /usr/local "$T/lusr"
run build HEAD "$T/lusr/nm-sym" --vk-include "$T/vk"; has "a parent that links into /usr refused" "$out" "resolves to /usr/local/nm-sym, a system location"
gone "  and /usr/local/nm-sym not created" /usr/local/nm-sym
ln -s /usr/share "$T/lshare"
run build HEAD "$T/lshare" --vk-include "$T/vk"; has "a target that links into /usr refused" "$out" "resolves to /usr/share, a system location"
ln -s /Library/nm-nowhere "$T/dang"
run build HEAD "$T/dang" --vk-include "$T/vk"; has "a dangling link as the target refused" "$out" "is a dangling symbolic link"
run build HEAD "$T/dang/sub" --vk-include "$T/vk"; has "a dangling link as a parent refused" "$out" "is a dangling symbolic link"
gone "  and the link's target not created" /Library/nm-nowhere
touch "$T/afile"
run build HEAD "$T/afile" --vk-include "$T/vk"; has "a file as the target refused" "$out" "exists and is not a directory"
run build HEAD "$T/afile/sub" --vk-include "$T/vk"; has "a file as a parent refused" "$out" "exists and is not a directory"
mkdir -p "$T/real"; ln -s "$T/real" "$T/lreal"; realT=$(cd "$T/real" && pwd -P)
run build HEAD "$T/lreal/viasym" --vk-include "$T/vk"; rcis "a parent that links to a directory of one's own: allowed" $rc 0 "$out"
[ -f "$realT/viasym/NVMTLDriver" ] && ok "  and the build lands in the resolved directory" || bad "build not in $realT/viasym" "$out"
out=$(cd "$T/real" && bash "$SCRIPT" build HEAD ../rel-out --vk-include "$T/vk" 2>&1); rc=$?
rcis "a relative '..' through existing directories: allowed" $rc 0 "$out"
[ -f "$(cd "$T" && pwd -P)/rel-out/NVMTLDriver" ] && ok "  and resolved to the parent" || bad "rel-out misplaced" "$out"
FAKE_MKDIR_FAIL=b run build HEAD "$T/mk/a/b/c" --vk-include "$T/vk"
has "a directory that cannot be made stops the build" "$out" "cannot create"; has "  and says nothing is left" "$out" "nothing left behind"
gone "  and the directories it had made are removed" "$T/mk"

echo "== --vk-include made absolute before the working directory changes"
vkreal=$(cd "$T/vk" && pwd -P); ln -s "$T/vk" "$T/vklink"
: > "$FAKE_LOG"; out=$(cd "$T" && bash "$SCRIPT" build HEAD "$T/v1" --vk-include vk 2>&1); rc=$?
rcis "a relative --vk-include: build passes" $rc 0 "$out"; has "  and the compiler gets the absolute path" "$(cat "$FAKE_LOG")" "-I$vkreal "
: > "$FAKE_LOG"; out=$(cd "$T/real" && bash "$SCRIPT" build HEAD "$T/v2" --vk-include ../vk 2>&1); rc=$?
rcis "a relative --vk-include with '..': build passes" $rc 0 "$out"; has "  and the compiler gets the absolute path" "$(cat "$FAKE_LOG")" "-I$vkreal "
: > "$FAKE_LOG"; run build HEAD "$T/v3" --vk-include "$T/vklink"; has "a linked --vk-include is resolved" "$(cat "$FAKE_LOG")" "-I$vkreal "
hasnt "  and no relative -I reaches the compiler" "$(cat "$FAKE_LOG")" "-Ivk "
run build HEAD "$T/v4" --vk-include "$T/no-such-dir"; has "a missing --vk-include refused" "$out" "is not a directory"
gone "  before the output directory is made" "$T/v4"
run build HEAD "$T/v5" --vk-include "$T/real"; has "a --vk-include without the header refused" "$out" "no vulkan/vulkan_core.h under $realT"
gone "  before the output directory is made" "$T/v5"

echo "== a good build"
: > "$FAKE_LOG"; run build HEAD "$T/o1" --vk-include "$T/vk"
rcis "good build: rc 0" $rc 0 "$out"
log=$(cat "$FAKE_LOG")
for f in "-arch x86_64" "-mmacosx-version-min=15.0" "-bundle" "-fobjc-arc" "-O1" "-DNVMTL_RELEASE=1" "-Werror=unguarded-availability-new" \
         "-I$T/vk" "NVMTLDevice.m" "-framework Foundation -framework Metal -framework IOSurface -framework IOKit -framework CoreFoundation"; do
  has "compiler gets $f" "$log" "$f"
done
has "records the Vulkan header version" "$out" "VK_HEADER_VERSION 300 from $T/vk"
has "records the compiler" "$out" "Apple clang version 16.0.0 (fake)"
has "counts warnings" "$out" "warnings        1"
has "arch check" "$out" "ok    arch x86_64"
has "minos check" "$out" "ok    minos 15.0"
has "bundle check" "$out" "ok    Mach-O bundle"
has "library check" "$out" "ok    links only system libraries (2)"
has "release diagnostics absent" "$out" "ok    release has no 'fps file'"
has "live features present" "$out" "ok    feature 'dirty-only bindings'"
has "says it is not installed" "$out" "built (not installed, not signed)"
[ -f "$T/o1/build-info.txt" ] && [ -f "$T/o1/src/plugin/NVMTLDevice.m" ] && ok "sources and build-info in the output directory" || bad "output layout" "$(ls -R "$T/o1")"

echo "== each artifact check fails on its own"
FAKE_ARCH="x86_64 arm64" run build HEAD "$T/o2" --vk-include "$T/vk"; has "two architectures" "$out" "FAIL  arch 'x86_64 arm64'"; rcis "two architectures: rc 1" $rc 1 "$out"
FAKE_MINOS=26.0 run build HEAD "$T/o3" --vk-include "$T/vk"; has "minos 26.0" "$out" "FAIL  minos '26.0'"
FAKE_FTYPE=6 run build HEAD "$T/o4" --vk-include "$T/vk"; has "a dylib, not a bundle" "$out" "FAIL  not an MH_BUNDLE"
FAKE_EXTRA_LIB=/usr/local/lib/libfoo.dylib run build HEAD "$T/o5" --vk-include "$T/vk"; has "a non-system library" "$out" "FAIL  links outside the system: /usr/local/lib/libfoo.dylib"
cp "$T/good.bin" "$T/leak.bin"; echo "/tmp/nvmtl-fps-%d" >> "$T/leak.bin"
FAKE_CONTENT=$T/leak.bin run build HEAD "$T/o6" --vk-include "$T/vk"; has "a leaked diagnostic" "$out" "FAIL  LEAKED diagnostic 'fps file'"
has "a failed check says not to use it" "$out" "do not use it"
grep -v NVMTL_NO_DIRTYONLY "$T/good.bin" > "$T/miss.bin"
FAKE_CONTENT=$T/miss.bin run build HEAD "$T/o7" --vk-include "$T/vk"; has "a missing feature" "$out" "FAIL  MISSING feature 'dirty-only bindings'"
FAKE_CC_FAIL=1 run build HEAD "$T/o8" --vk-include "$T/vk"; has "compile error shown" "$out" "error: injected"; has "compile failure stops" "$out" "compile failed"

echo "== reproducibility"
run build HEAD "$T/o9" --vk-include "$T/vk" --twice; has "two identical builds" "$out" "reproducible    IDENTICAL"
FAKE_RANDOM=1 run build HEAD "$T/o10" --vk-include "$T/vk" --twice; has "two different builds" "$out" "reproducible    DIFFERENT"

echo "== check-installed (read only)"
R=$T/root; mkdir -p "$R/Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS" "$R/Library/GPUBundles/nvmtl" "$R/Library/NullMoth"
cp "$T/good.bin" "$R/Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS/NVMTLDriver"
echo 2.5.3 > "$R/Library/NullMoth/driver-version"
touch "$R/Library/GPUBundles/nvmtl/libvulkan_nouveau.dylib" "$R/Library/GPUBundles/nvmtl/libnvmtl_translate.dylib"
printf '%s\n' vkGetInstanceProcAddr nvmtl_nvk_stage_import nvmtl_nvk_surface_dirty > "$R/Library/GPUBundles/nvmtl/libvulkan_nouveau.dylib.syms"
printf '%s\n' nvmtl_translate_free > "$R/Library/GPUBundles/nvmtl/libnvmtl_translate.dylib.syms"
before=$(cd "$R" && find . -type f -exec sha256sum {} + | sort)
tag=$(git -C "$(dirname "$SCRIPT")/.." describe --tags --exact-match HEAD 2>/dev/null)
out=$(NM_ROOT=$R bash "$SCRIPT" check-installed "$T/o1/NVMTLDriver" HEAD 2>&1); rc=$?
rcis "a required translator symbol absent: rc 1" $rc 1 "$out"
has "  and it is listed under FAILED" "$out" "required symbol nvmtl_translate absent from $R/Library/GPUBundles/nvmtl/libnvmtl_translate.dylib"
has "  and the optional ones are listed apart" "$out" "optional symbols absent ("
has "says it is a first check, not ABI compatibility" "$out" "It is a first check, not proof of ABI"
has "installed plugin compared" "$out" "installed  sha256"
has "same binary, same hash" "$out" "$(sha256sum "$T/good.bin" | cut -d' ' -f1)"
has "installed version shown" "$out" "installed driver-version: 2.5.3"
has "NVK export present" "$out" "present  nvmtl_nvk_stage_import"
has "optional NVK export absent" "$out" "absent   nvmtl_nvk_dispatch_sass_v3  (optional"
has "required translator export absent" "$out" "ABSENT   nvmtl_translate  (required"
if [ -n "$tag" ]; then
  if [ "${tag#v}" = 2.5.3 ]; then has "source tag matches the installed version" "$out" "source tag $tag"
  else has "source tag differs from the installed version" "$out" "NOTE: source $tag vs installed 2.5.3"; fi
else has "untagged source is flagged" "$out" "is not a release tag"; fi
echo 2.0.0 > "$R/Library/NullMoth/driver-version"; before=$(cd "$R" && find . -type f -exec sha256sum {} + | sort)
out=$(NM_ROOT=$R bash "$SCRIPT" check-installed "$T/o1/NVMTLDriver" HEAD 2>&1)
if [ -n "$tag" ]; then has "version mismatch is flagged" "$out" "vs installed 2.0.0"; fi
after=$(cd "$R" && find . -type f -exec sha256sum {} + | sort)
[ "$before" = "$after" ] && ok "check-installed changed nothing" || bad "check-installed changed files" "$after"
out=$(NM_ROOT=$T/empty bash "$SCRIPT" check-installed "$T/o1/NVMTLDriver" 2>&1); rc=$?
has "missing installed plugin reported" "$out" "MISSING: $T/empty/Library/GPUBundles/NVMTLDriver.bundle"
has "missing NVK reported, run continues" "$out" "MISSING: $T/empty/Library/GPUBundles/nvmtl/libnvmtl_translate.dylib"
rcis "nothing installed: rc 1" $rc 1 "$out"
has "  and each missing file is a failure" "$out" "missing file $T/empty/Library/GPUBundles/nvmtl/libvulkan_nouveau.dylib"

# every required name present, only optional ones absent, no driver-version: passes
printf '%s\n' nvmtl_translate nvmtl_translate_free > "$R/Library/GPUBundles/nvmtl/libnvmtl_translate.dylib.syms"
rm -f "$R/Library/NullMoth/driver-version"
out=$(NM_ROOT=$R bash "$SCRIPT" check-installed "$T/o1/NVMTLDriver" 2>&1); rc=$?
rcis "required present, optional absent: rc 0" $rc 0 "$out"
has "  and says so" "$out" "required files and symbols: all present"
has "  and lists the absent optional symbols apart" "$out" "optional symbols absent (23): nvmtl_nvk_sample_depth_contract_v1"
has "  and a missing driver-version is not a failure" "$out" "installed driver-version: MISSING (not required)"
hasnt "  and nothing is FAILED" "$out" "FAILED"
# each required piece on its own
mv "$R/Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS/NVMTLDriver" "$T/inst.bak"
out=$(NM_ROOT=$R bash "$SCRIPT" check-installed "$T/o1/NVMTLDriver" 2>&1); rc=$?
rcis "installed plugin missing: rc 1" $rc 1 "$out"; has "  and named" "$out" "missing file $R/Library/GPUBundles/NVMTLDriver.bundle"
mv "$T/inst.bak" "$R/Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS/NVMTLDriver"
mv "$R/Library/GPUBundles/nvmtl/libvulkan_nouveau.dylib" "$T/nvk.bak"
out=$(NM_ROOT=$R bash "$SCRIPT" check-installed "$T/o1/NVMTLDriver" 2>&1); rc=$?
rcis "NVK missing: rc 1" $rc 1 "$out"; has "  and named" "$out" "missing file $R/Library/GPUBundles/nvmtl/libvulkan_nouveau.dylib"
mv "$T/nvk.bak" "$R/Library/GPUBundles/nvmtl/libvulkan_nouveau.dylib"
printf '%s\n' nvmtl_nvk_stage_import > "$R/Library/GPUBundles/nvmtl/libvulkan_nouveau.dylib.syms"
out=$(NM_ROOT=$R bash "$SCRIPT" check-installed "$T/o1/NVMTLDriver" 2>&1); rc=$?
rcis "NVK without vkGetInstanceProcAddr: rc 1" $rc 1 "$out"; has "  and named" "$out" "required symbol vkGetInstanceProcAddr absent"
printf '%s\n' vkGetInstanceProcAddr > "$R/Library/GPUBundles/nvmtl/libvulkan_nouveau.dylib.syms"
echo CORRUPT > "$R/Library/GPUBundles/nvmtl/libnvmtl_translate.dylib"
out=$(NM_ROOT=$R bash "$SCRIPT" check-installed "$T/o1/NVMTLDriver" 2>&1); rc=$?
rcis "nm cannot read the translator: rc 1" $rc 1 "$out"
has "  and shows nm's error" "$out" "nm FAILED on $R/Library/GPUBundles/nvmtl/libnvmtl_translate.dylib: nm: error"
has "  and lists it as a failure" "$out" "nm could not read $R/Library/GPUBundles/nvmtl/libnvmtl_translate.dylib"
hasnt "  and does not report its symbols as absent" "$out" "ABSENT   nvmtl_translate"
: > "$R/Library/GPUBundles/nvmtl/libnvmtl_translate.dylib"

echo "== total: $pass PASS, $fail FAIL"
[ $fail = 0 ]
