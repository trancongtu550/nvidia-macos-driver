#!/bin/bash
# nm_build_plugin.sh build <git-rev> <out-dir> --vk-include <dir> [--twice]
# nm_build_plugin.sh check-installed <built NVMTLDriver> [<git-rev>]
#
# A local, repeatable build of the release NVMTLDriver binary on a Mac, with the flags of build/build_plugin_release.sh
# (which builds on the author's "mini" over ssh), and read-only checks of the result. It never installs: it writes only
# into <out-dir> (which must be new or empty and outside /Library, /System, /usr, /Applications), uses no sudo, does not
# sign, and changes nothing under /Library.
#
#   build             git archive of plugin/ at <git-rev> -> one clang call with the release flags -> artifact checks:
#                     x86_64 only, minos 15.0, a bundle (MH_BUNDLE), linked only against /System and /usr/lib, the
#                     release markers of build/build_plugin.sh (live features present, diagnostics absent), compiler
#                     warnings counted. build-info.txt records the tool versions, the Vulkan header version and hashes.
#                     --twice builds a second time in a second directory and says whether the two binaries are identical.
#   check-installed   compares the built binary with the installed /Library/GPUBundles/NVMTLDriver.bundle and lists which
#                     private entry points the plugin looks up are exported by the installed NVK and translator. Reads only.
#
# --vk-include: the directory holding vulkan/vulkan_core.h. The release build used the include/ directory of the Mesa tree
# the NVK in the package was built from (Mesa 17ca6174 with nvk/nvk-macos.patch); build/build_plugin.sh uses
# Khronos Vulkan-Headers. The plugin is one translation unit: plugin/NVMTLDevice.m includes the rest.
#
# NM_ROOT (tests only) prefixes the installed paths that check-installed reads.
set -uo pipefail

nm_die() { echo "STOP: $*" >&2; exit 1; }
nm_need() { local t; for t in "$@"; do command -v "$t" >/dev/null 2>&1 || nm_die "$t is not available (Xcode command line tools?)"; done; }
nm_abs() { (cd "$1" 2>/dev/null && pwd -P); }

# The release flags of build/build_plugin_release.sh, apart from the include directory.
NM_FLAGS=(-arch x86_64 -mmacosx-version-min=15.0 -bundle -fobjc-arc -O1 -DNVMTL_RELEASE=1
          -Wno-protocol -Wno-incomplete-implementation -Werror=unguarded-availability-new)
NM_FRAMEWORKS=(-framework Foundation -framework Metal -framework IOSurface -framework IOKit -framework CoreFoundation)

# Refuses an output directory that is a system location, or one that already holds files.
nm_out_ok() {
  local out=$1 parent abs
  case "$out" in /*) ;; *) out="$PWD/$out" ;; esac
  parent=$(dirname "$out"); mkdir -p "$parent" 2>/dev/null || nm_die "cannot create $parent"
  abs="$(nm_abs "$parent")/$(basename "$out")"
  case "$abs/" in /Library/*|/System/*|/usr/*|/Applications/*|/private/var/db/*|/bin/*|/sbin/*)
    nm_die "$abs is a system location; build into a directory of your own" ;; esac
  if [ -e "$abs" ] && [ -n "$(ls -A "$abs" 2>/dev/null)" ]; then nm_die "$abs is not empty"; fi
  mkdir -p "$abs" || nm_die "cannot create $abs"
  printf '%s\n' "$abs"
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
  (cd "$1" && xcrun clang "${NM_FLAGS[@]}" -I"$3" -o "$2" NVMTLDevice.m "${NM_FRAMEWORKS[@]}" 2>"$4")
}

nm_build() {
  local rev=${1:-} out=${2:-} vk= twice=0 here sha src a b
  [ -n "$rev" ] && [ -n "$out" ] || nm_die "usage: build <git-rev> <out-dir> --vk-include <dir> [--twice]"
  shift 2
  while [ $# -gt 0 ]; do case $1 in --vk-include) vk=${2:-}; shift ;; --twice) twice=1 ;; *) nm_die "unknown option $1" ;; esac; shift; done
  [ -n "$vk" ] || nm_die "--vk-include <dir> is required (the directory holding vulkan/vulkan_core.h)"
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
    echo "flags           ${NM_FLAGS[*]} ${NM_FRAMEWORKS[*]}"
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

# nm_exports <dylib> <symbols>: one line per symbol, present or absent in the dylib's exports.
nm_exports() {
  local lib=$1 s name ex
  [ -r "$lib" ] || { echo "  MISSING: $lib"; return 0; }
  ex=$(nm -gU "$lib" 2>/dev/null | awk '{print $NF}' | sed 's/^_//')
  for s in $2; do
    name=${s#!}
    if printf '%s\n' "$ex" | grep -qx -- "$name"; then echo "  present  $name"
    elif [ "$s" != "$name" ]; then echo "  ABSENT   $name  (required: the plugin cannot run without it)"
    else echo "  absent   $name  (optional: its feature is off)"; fi
  done
}

nm_installed() {
  local built=${1:-} rev=${2:-} R=${NM_ROOT:-} inst ver tag here
  [ -n "$built" ] && [ -r "$built" ] || nm_die "usage: check-installed <built NVMTLDriver> [<git-rev>]"
  nm_need shasum otool vtool nm
  inst="$R/Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS/NVMTLDriver"
  echo "== plugin: built vs installed (read only)"
  printf '%-10s sha256 %s  minos %s  uuid %s\n' built "$(shasum -a 256 "$built" | cut -d' ' -f1)" \
    "$(vtool -show-build "$built" 2>/dev/null | awk '/minos/{print $2; exit}')" "$(otool -l "$built" | awk '/uuid/{print $2; exit}')"
  if [ -r "$inst" ]; then
    printf '%-10s sha256 %s  minos %s  uuid %s\n' installed "$(shasum -a 256 "$inst" | cut -d' ' -f1)" \
      "$(vtool -show-build "$inst" 2>/dev/null | awk '/minos/{print $2; exit}')" "$(otool -l "$inst" | awk '/uuid/{print $2; exit}')"
  else echo "MISSING: $inst"; fi
  ver=$(cat "$R/Library/NullMoth/driver-version" 2>/dev/null)
  echo "installed driver-version: ${ver:-MISSING}"
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
}

nm_main() {
  case "${1:-}" in
    build) shift; nm_build "$@" ;;
    check-installed) shift; nm_installed "$@" ;;
    *) echo "usage: bash $0 build <git-rev> <out-dir> --vk-include <dir> [--twice] | check-installed <built NVMTLDriver> [<git-rev>]"; return 2 ;;
  esac
}
if [ "${BASH_SOURCE[0]}" = "$0" ]; then nm_main "$@"; fi
