#!/bin/bash
# nm_build_plugin.sh build <git-rev> <out-dir> --vk-include <dir> [--twice] [--opt O1|O2]
# nm_build_plugin.sh check-installed <built NVMTLDriver> [<git-rev>]
#
# A local, repeatable build of the release NVMTLDriver binary on a Mac, with the flags of build/build_plugin_release.sh
# (which builds on the author's "mini" over ssh), and read-only checks of the result. It never installs: it writes only
# into <out-dir> (new or empty; resolved through ".." and symbolic links and refused in /Library, /System, /usr,
# /Applications and other system locations before anything is created), uses no sudo, does not sign, and changes
# nothing under /Library.
#
#   build             git archive of plugin/ at <git-rev> -> one clang call with the release flags -> artifact checks:
#                     x86_64 only, minos 15.0, a bundle (MH_BUNDLE), linked only against /System and /usr/lib, the
#                     release markers of build/build_plugin.sh (live features present, diagnostics absent), compiler
#                     warnings counted. build-info.txt records the tool versions, the Vulkan header version and hashes.
#                     --twice builds a second time in a second directory and says whether the two binaries are identical.
#                     --opt O2 builds the A/B variant at -O2; the default, O1, is the release build's level. Nothing else
#                     changes: assertions and the release checks stay as in the release build (no -DNDEBUG).
#   check-installed   compares the built binary with the installed /Library/GPUBundles/NVMTLDriver.bundle and lists which
#                     private entry points the plugin looks up are exported by the installed NVK and translator. Reads only.
#                     Exits 1 when the installed plugin, NVK or translator is missing, nm cannot read one of them, or a
#                     required symbol is absent; absent optional symbols are listed apart. Exported names are a first
#                     check only, not proof of ABI compatibility.
#
# --vk-include: the directory holding vulkan/vulkan_core.h. The release build used the include/ directory of the Mesa tree
# the NVK in the package was built from (Mesa 17ca6174 with nvk/nvk-macos.patch); build/build_plugin.sh uses
# Khronos Vulkan-Headers. The plugin is one translation unit: plugin/NVMTLDevice.m includes the rest.
#
# NM_ROOT (tests only) prefixes the installed paths that check-installed reads.
set -uo pipefail

nm_die() { echo "STOP: $*" >&2; exit 1; }
nm_need() { local t; for t in "$@"; do command -v "$t" >/dev/null 2>&1 || nm_die "$t is not available (Xcode command line tools?)"; done; }

# The release flags of build/build_plugin_release.sh, apart from the include directory.
NM_FLAGS=(-arch x86_64 -mmacosx-version-min=15.0 -bundle -fobjc-arc -O1 -DNVMTL_RELEASE=1
          -Wno-protocol -Wno-incomplete-implementation -Werror=unguarded-availability-new)
NM_FRAMEWORKS=(-framework Foundation -framework Metal -framework IOSurface -framework IOKit -framework CoreFoundation)

# nm_out_ok <dir>: checks the output directory completely, and only then creates it. The deepest part of the path that
# exists is resolved with pwd -P (through every symbolic link and ".."); the parts below it, which do not exist yet, may
# not be "." or "..". A dangling symbolic link, a target that is not a directory or not empty, and a resolved path in a
# system location are refused before anything is created. The missing directories are then made one at a time; if one
# cannot be made, or the result does not resolve to the path that was checked, the ones this call made are removed.
NM_FORBIDDEN="/Library /System /usr /Applications /private/var/db /private/etc /etc /bin /sbin"
nm_forbidden() {
  local f
  [ "$1" = / ] && return 0
  for f in $NM_FORBIDDEN; do case "$1/" in "$f"/*) return 0 ;; esac; done
  return 1
}
nm_undo() { local i; for ((i=${#NM_MADE[@]}-1; i>=0; i--)); do rmdir "${NM_MADE[i]}" 2>/dev/null; done; }
nm_out_ok() {
  local out=$1 base rest= comp resolved d
  [ -n "$out" ] || nm_die "empty output directory"
  case "$out" in /*) ;; *) out="$(pwd -P)/$out" ;; esac
  out=$(printf '%s' "$out" | sed -e 's://*:/:g' -e 's:\(.\)/$:\1:')
  # walk up to the deepest part that exists; a symbolic link counts as existing, dangling or not
  base=$out
  while [ "$base" != / ] && [ ! -e "$base" ] && [ ! -L "$base" ]; do
    comp=$(basename "$base")
    case "$comp" in .|..) nm_die "$1: '$comp' in a part of the path that does not exist yet" ;; esac
    rest="$comp${rest:+/$rest}"; base=$(dirname "$base")
  done
  if [ -L "$base" ] && [ ! -e "$base" ]; then nm_die "$1: $base is a dangling symbolic link"; fi
  [ -d "$base" ] || nm_die "$1: $base exists and is not a directory"
  resolved=$(cd "$base" 2>/dev/null && pwd -P) || nm_die "$1: cannot resolve $base"
  resolved="${resolved%/}${rest:+/$rest}"; [ -n "$resolved" ] || resolved=/
  if nm_forbidden "$resolved"; then nm_die "$1 resolves to $resolved, a system location; build into a directory of your own"; fi
  if [ -z "$rest" ] && [ -n "$(ls -A "$resolved" 2>/dev/null)" ]; then nm_die "$1 ($resolved) is not empty"; fi
  # every check passed: make the missing parts one at a time, remembering what this call made
  NM_MADE=(); d=${resolved%"${rest:+/$rest}"}; d=${d%/}
  local IFS=/
  for comp in $rest; do
    d="$d/$comp"
    mkdir "$d" 2>/dev/null || { nm_undo; nm_die "cannot create $d (nothing left behind)"; }
    NM_MADE+=("$d")
  done
  unset IFS
  if [ "$(cd "$resolved" 2>/dev/null && pwd -P)" != "$resolved" ]; then
    nm_undo; nm_die "$resolved changed while it was being created (nothing left behind)"
  fi
  printf '%s\n' "$resolved"
}

nm_vk_version() { sed -n 's/^#define VK_HEADER_VERSION \([0-9][0-9]*\).*/\1/p' "$1/vulkan/vulkan_core.h" | head -n 1; }

# nm_markers <checkout>: the "feature|pattern" list build/build_plugin.sh checks, read from that script so both stay in step.
nm_markers() { awk '/<<.M.$/{on=1; next} on && /^M$/{exit} on' "$1/build/build_plugin.sh"; }

# nm_check <binary> <checkout>: artifact checks; prints one line per check and returns non-zero when any fails.
nm_check() {
  local bin=$1 co=$2 bad=0 archs minos libs other feat pat n
  archs=$(lipo -archs "$bin" 2>/dev/null)
  if [ "$archs" = x86_64 ]; then echo "ok    arch $archs"; else echo "FAIL  arch '$archs' (want x86_64 only)"; bad=1; fi
  minos=$(vtool -show-build "$bin" 2>/dev/null | awk '/minos/{print $2; exit}')
  if [ "$minos" = 15.0 ]; then echo "ok    minos $minos"; else echo "FAIL  minos '$minos' (want 15.0: dyld refuses a newer one on Sequoia)"; bad=1; fi
  if otool -h "$bin" 2>/dev/null | awk 'NR>2 && $5==8 {f=1} END{exit !f}'; then echo "ok    Mach-O bundle"; else echo "FAIL  not an MH_BUNDLE"; bad=1; fi
  libs=$(otool -L "$bin" 2>/dev/null | awk 'NR>1{print $1}')
  other=$(printf '%s\n' "$libs" | grep -v -E '^(/System/Library/|/usr/lib/)' | grep -v '^$')
  if [ -z "$other" ]; then echo "ok    links only system libraries ($(printf '%s\n' "$libs" | grep -c .))"
  else echo "FAIL  links outside the system: $(printf '%s ' $other)"; bad=1; fi
  while IFS='|' read -r feat pat; do
    [ -n "$feat" ] || continue
    n=$(strings -a "$bin" | grep -c -- "$pat")
    case "$feat" in
      "fps file"|"passtime instrument")
        if [ "$n" -eq 0 ]; then echo "ok    release has no '$feat'"; else echo "FAIL  LEAKED diagnostic '$feat' ($pat)"; bad=1; fi ;;
      *) if [ "$n" -ge 1 ]; then echo "ok    feature '$feat'"; else echo "FAIL  MISSING feature '$feat' ($pat)"; bad=1; fi ;;
    esac
  done < <(nm_markers "$co")
  return $bad
}

# nm_compile <src-dir> <out-binary> <vk-include> <err-file>
nm_compile() {
  (cd "$1" && xcrun clang "${NM_BUILD_FLAGS[@]}" -I"$3" -o "$2" NVMTLDevice.m "${NM_FRAMEWORKS[@]}" 2>"$4")
}

nm_build() {
  local rev=${1:-} out=${2:-} vk= twice=0 opt=O1 here sha src a b f
  [ -n "$rev" ] && [ -n "$out" ] || nm_die "usage: build <git-rev> <out-dir> --vk-include <dir> [--twice] [--opt O1|O2]"
  shift 2
  while [ $# -gt 0 ]; do case $1 in --vk-include) vk=${2:-}; shift ;; --twice) twice=1 ;; --opt) opt=${2:-}; shift ;; *) nm_die "unknown option $1" ;; esac; shift; done
  case "$opt" in O1|O2) ;; *) nm_die "--opt takes O1 (the release build's level) or O2 (the A/B variant)" ;; esac
  # the release flags with only the optimisation level swapped
  NM_BUILD_FLAGS=(); for f in "${NM_FLAGS[@]}"; do [ "$f" = -O1 ] && f=-$opt; NM_BUILD_FLAGS+=("$f"); done
  [ -n "$vk" ] || nm_die "--vk-include <dir> is required (the directory holding vulkan/vulkan_core.h)"
  # made absolute here, before anything changes the working directory: the compiler runs inside src/plugin
  [ -d "$vk" ] || nm_die "--vk-include $vk is not a directory"
  vk=$(cd "$vk" 2>/dev/null && pwd -P) || nm_die "cannot resolve --vk-include $vk"
  [ -f "$vk/vulkan/vulkan_core.h" ] || nm_die "no vulkan/vulkan_core.h under $vk"
  nm_need git xcrun lipo vtool otool strings shasum
  here=$(cd "$(dirname "$0")/.." && pwd)
  sha=$(git -C "$here" rev-parse --verify "$rev^{commit}" 2>/dev/null) || nm_die "$rev is not a commit of $here"
  out=$(nm_out_ok "$out") || exit 1
  src="$out/src"; mkdir -p "$src"
  git -C "$here" archive "$sha" plugin | tar x -C "$src" || nm_die "git archive failed"
  git -C "$here" archive "$sha" build/build_plugin.sh | tar x -C "$src" || nm_die "git archive failed"
  {
    echo "plugin source   $sha ($(git -C "$here" describe --tags --always "$sha" 2>/dev/null))"
    echo "macOS           $(sw_vers -productVersion 2>/dev/null) $(sw_vers -buildVersion 2>/dev/null)"
    echo "developer dir   $(xcode-select -p 2>/dev/null)"
    echo "SDK             $(xcrun --show-sdk-version 2>/dev/null) $(xcrun --show-sdk-path 2>/dev/null)"
    echo "compiler        $(xcrun clang --version 2>/dev/null | head -n 1)"
    echo "Vulkan headers  VK_HEADER_VERSION $(nm_vk_version "$vk") from $vk$(git -C "$vk" rev-parse --short HEAD 2>/dev/null | sed 's/^/ (git /; s/$/)/')"
    if [ "$opt" = O1 ]; then echo "variant         O1 (the release build's level)"
    else echo "variant         $opt (A/B variant; the release build is -O1)"; fi
    echo "flags           ${NM_BUILD_FLAGS[*]} ${NM_FRAMEWORKS[*]}"
  } > "$out/build-info.txt"
  cat "$out/build-info.txt"
  nm_compile "$src/plugin" "$out/NVMTLDriver" "$vk" "$out/build.err" || { grep ' error:' "$out/build.err" | head -20; nm_die "compile failed ($out/build.err)"; }
  echo "warnings        $(grep -c ': warning:' "$out/build.err")" | tee -a "$out/build-info.txt"
  echo "sha256          $(shasum -a 256 "$out/NVMTLDriver" | cut -d' ' -f1)" | tee -a "$out/build-info.txt"
  echo "uuid            $(otool -l "$out/NVMTLDriver" | awk '/uuid/{print $2; exit}')" | tee -a "$out/build-info.txt"
  echo "== artifact checks"
  nm_check "$out/NVMTLDriver" "$src" || nm_die "the artifact failed a check above; do not use it"
  if [ $twice = 1 ]; then
    mkdir -p "$out/second"
    nm_compile "$src/plugin" "$out/second/NVMTLDriver" "$vk" "$out/second/build.err" || nm_die "second compile failed"
    a=$(shasum -a 256 "$out/NVMTLDriver" | cut -d' ' -f1); b=$(shasum -a 256 "$out/second/NVMTLDriver" | cut -d' ' -f1)
    if [ "$a" = "$b" ]; then echo "reproducible    IDENTICAL (two builds, same sha256)" | tee -a "$out/build-info.txt"
    else echo "reproducible    DIFFERENT ($a vs $b); compare 'otool -l' and 'strings' of the two" | tee -a "$out/build-info.txt"; fi
  fi
  echo "built (not installed, not signed): $out/NVMTLDriver"
}

# Entry points the plugin looks up by name in NVK and in the translator; "!" marks one without which the plugin stops.
NM_NVK_SYMS="nvmtl_nvk_stage_import nvmtl_nvk_surface_dirty nvmtl_nvk_sample_depth_contract_v1 nvmtl_nvk_sample_depth_image_v1 nvmtl_nvk_sparse_bind_v1 nvmtl_nvk_dispatch_sass_v1 nvmtl_nvk_dispatch_sass_v3 nvmtl_nvk_sass_image_handle_v1 nvmtl_nvk_sass_sampler_handle_v1 nvkmd_nvrm_gsub_stats !vkGetInstanceProcAddr"
NM_XLATE_SYMS="!nvmtl_translate nvmtl_translate_free nvmtl_translate_fc nvmtl_translate_samplers nvmtl_translate_set_caps nvmtl_translate_set_threadgroup_lengths nvmtl_lower_buffer_addresses nvmtl_lower_buffer_addresses_ex nvmtl_table_to_uniform nvmtl_visible_refs nvmtl_link_visible nvmtl_link_runtime nvmtl_link_externs nvmtl_lower_mesh nvmtl_lower_mesh2 nvmtl_reflect nvmtl_reflect_fc"

# nm_exports <dylib> <symbols>: one line per symbol, present or absent in the dylib's exports. A missing file, nm
# failing on it and an absent required symbol go to NM_BAD; absent optional symbols go to NM_OPT.
nm_exports() {
  local lib=$1 s name ex err
  if [ ! -r "$lib" ]; then echo "  MISSING: $lib"; NM_BAD+=("missing file $lib"); return 0; fi
  err=$(mktemp) || nm_die "mktemp failed"
  if ! ex=$(nm -gU "$lib" 2>"$err"); then
    echo "  nm FAILED on $lib: $(head -c 300 "$err")"; rm -f "$err"; NM_BAD+=("nm could not read $lib"); return 0
  fi
  rm -f "$err"
  ex=$(printf '%s\n' "$ex" | awk 'NF{print $NF}' | sed 's/^_//')
  for s in $2; do
    name=${s#!}
    if printf '%s\n' "$ex" | grep -qx -- "$name"; then echo "  present  $name"
    elif [ "$s" != "$name" ]; then echo "  ABSENT   $name  (required: the plugin cannot run without it)"; NM_BAD+=("required symbol $name absent from $lib")
    else echo "  absent   $name  (optional: its feature is off)"; NM_OPT+=("$name"); fi
  done
}

# Returns 1 when the installed plugin, NVK or translator is missing, nm cannot read one of them, or a required symbol is
# absent. Absent optional symbols are listed apart and do not fail it.
nm_installed() {
  local built=${1:-} rev=${2:-} R=${NM_ROOT:-} inst ver tag here b
  [ -n "$built" ] && [ -r "$built" ] || nm_die "usage: check-installed <built NVMTLDriver> [<git-rev>]"
  nm_need shasum otool vtool nm
  NM_BAD=(); NM_OPT=()
  inst="$R/Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS/NVMTLDriver"
  echo "== plugin: built vs installed (read only)"
  printf '%-10s sha256 %s  minos %s  uuid %s\n' built "$(shasum -a 256 "$built" | cut -d' ' -f1)" \
    "$(vtool -show-build "$built" 2>/dev/null | awk '/minos/{print $2; exit}')" "$(otool -l "$built" | awk '/uuid/{print $2; exit}')"
  if [ -r "$inst" ]; then
    printf '%-10s sha256 %s  minos %s  uuid %s\n' installed "$(shasum -a 256 "$inst" | cut -d' ' -f1)" \
      "$(vtool -show-build "$inst" 2>/dev/null | awk '/minos/{print $2; exit}')" "$(otool -l "$inst" | awk '/uuid/{print $2; exit}')"
  else echo "MISSING: $inst"; NM_BAD+=("missing file $inst"); fi
  ver=$(cat "$R/Library/NullMoth/driver-version" 2>/dev/null)
  echo "installed driver-version: ${ver:-MISSING (not required)}"
  if [ -n "$rev" ]; then
    here=$(cd "$(dirname "$0")/.." && pwd)
    tag=$(git -C "$here" describe --tags --exact-match "$rev" 2>/dev/null)
    if [ -z "$tag" ]; then echo "NOTE: $rev is not a release tag; the installed NVK and translator were built for a release"
    elif [ -n "$ver" ] && [ "${tag#v}" != "$ver" ]; then echo "NOTE: source $tag vs installed $ver: build from the installed release's tag"
    else echo "source tag $tag"; fi
  fi
  echo "== installed NVK exports the plugin looks up"
  nm_exports "$R/Library/GPUBundles/nvmtl/libvulkan_nouveau.dylib" "$NM_NVK_SYMS"
  echo "== installed translator exports the plugin looks up"
  nm_exports "$R/Library/GPUBundles/nvmtl/libnvmtl_translate.dylib" "$NM_XLATE_SYMS"
  echo "== result"
  echo "NOTE: this only checks that the names the plugin looks up are exported. It is a first check, not proof of ABI"
  echo "      compatibility: signatures, structure layouts and behaviour are not checked here (the source-level contract"
  echo "      is tools/test_plugin_abi_contract.py)."
  if [ ${#NM_OPT[@]} -gt 0 ]; then echo "optional symbols absent (${#NM_OPT[@]}): ${NM_OPT[*]}"
  else echo "optional symbols absent: none"; fi
  if [ ${#NM_BAD[@]} -gt 0 ]; then
    echo "FAILED (${#NM_BAD[@]}):"; for b in "${NM_BAD[@]}"; do echo "  - $b"; done
    return 1
  fi
  echo "required files and symbols: all present"
}

nm_main() {
  case "${1:-}" in
    build) shift; nm_build "$@" ;;
    check-installed) shift; nm_installed "$@" ;;
    *) echo "usage: bash $0 build <git-rev> <out-dir> --vk-include <dir> [--twice] [--opt O1|O2] | check-installed <built NVMTLDriver> [<git-rev>]"; return 2 ;;
  esac
}
if [ "${BASH_SOURCE[0]}" = "$0" ]; then nm_main "$@"; fi
