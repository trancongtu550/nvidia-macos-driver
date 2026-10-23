#!/bin/bash
# nm_readonly_diagnostics.sh status | measure <label>
#
# Read-only display/flip diagnostics for a running NullMoth driver on macOS. It changes nothing: no sudo, no sysctl
# writes, no counter resets, no NVRAM or boot-args changes, no files written, nothing uploaded. Output goes to the
# terminal only. Anything the running driver or the account does not provide is printed as "THIẾU: ..." and the rest
# continues.
#
#   status            driver versions (loaded and on disk), display mode, accelerators, nvrm-flip, BAR1, runtime switches
#   measure <label>   reads the NVAccel/NVRMFB counters, waits 30 s while you drag or scroll, reads them again and prints
#                     the deltas, then the kernel log lines of that window
#
# Run it with bash (macOS's zsh does not split $NM_KEYS into words):
#   bash tools/nm_readonly_diagnostics.sh status
#   bash tools/nm_readonly_diagnostics.sh measure nen-dung-yen
#   bash tools/nm_readonly_diagnostics.sh measure keo-cua-so
#   bash tools/nm_readonly_diagnostics.sh measure cuon
#
# The counter, property and log names are the ones the kexts define at v2.5.3 (75e2e28): NVAccel
# kexts/NVRM/accel/nvrm-accel.cpp, NVRMFB kexts/NVRMFB/fb/nvrm-fb.cpp, NVRM kexts/NVRM/NVRM.cpp. An older driver
# may lack some of them. Serial numbers, UUIDs and the full NVRAM / IORegistry are never printed; long hex addresses
# in log lines and BAR apertures are masked.

nm_say() { printf '\n== %s\n' "$1"; }
nm_or() { if [ -n "$1" ]; then printf '%s\n' "$1"; else echo "THIẾU: $2"; fi; }

nm_status() {
  nm_say "A1. macOS, boot-args đang dùng, SIP, model"
  sw_vers 2>/dev/null || echo "THIẾU: sw_vers"
  sysctl -n hw.model kern.osversion 2>/dev/null
  echo "boot-args (kern.bootargs): $(sysctl -n kern.bootargs 2>/dev/null)"
  echo "boot time: $(sysctl -n kern.boottime 2>/dev/null | sed -E 's/^\{ sec = ([0-9]+).*/\1/' | xargs -I{} date -r {} '+%Y-%m-%d %H:%M:%S')"
  nm_or "$(csrutil status 2>/dev/null | head -n 1)" "csrutil status"

  nm_say "A2a. Kext NullMoth ĐANG LOAD (kmutil; chỉ in bundle ID và phiên bản)"
  nm_or "$(kmutil showloaded --list-only 2>/dev/null | grep -E 'com\.nullmoth\.' | sed -E 's/^.*(com\.nullmoth\.[A-Za-z0-9_]+) \(([^)]*)\).*$/\1  loaded=\2/')" "kmutil không trả về kext com.nullmoth.* nào (hoặc kmutil không chạy được)"
  nm_or "$(ioreg -r -c NVRM -d 1 -w0 2>/dev/null | grep -E '"nvrm-kext-version"' | sed -E 's/^[ |]*//')" "thuộc tính nvrm-kext-version (bản NVRM đang chạy chưa có)"

  nm_say "A2b. Phiên bản TRÊN ĐĨA (chưa chắc là bản đang load)"
  local k p q v
  for k in NVRM NVAccel NVRMFB NVRMAGDC; do
    p=/Library/Extensions/$k.kext/Contents
    if [ -f "$p/Info.plist" ]; then
      printf '%-9s disk: CFBundleVersion=%s  Short=%s  binary mtime=%s\n' "$k" \
        "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$p/Info.plist" 2>/dev/null)" \
        "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$p/Info.plist" 2>/dev/null)" \
        "$(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$p/MacOS/$k" 2>/dev/null)"
    else echo "THIẾU: /Library/Extensions/$k.kext"; fi
  done
  nm_or "$(cat /Library/NullMoth/driver-version 2>/dev/null)" "/Library/NullMoth/driver-version"
  nm_or "$(stat -f 'AuxiliaryKernelExtensions.kc mtime=%Sm' -t '%Y-%m-%d %H:%M' /Library/KernelCollections/AuxiliaryKernelExtensions.kc 2>/dev/null)" "Auxiliary Kernel Collection"
  q=/Library/GPUBundles/NVMTLDriver.bundle/Contents
  nm_or "$( [ -d "$q" ] && printf 'NVMTLDriver.bundle disk: CFBundleVersion=%s  binary mtime=%s' "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$q/Info.plist" 2>/dev/null)" "$(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$q/MacOS/NVMTLDriver" 2>/dev/null)")" "/Library/GPUBundles/NVMTLDriver.bundle"

  nm_say "A3a. Màn hình (system_profiler, đã lọc bỏ serial)"
  nm_or "$(system_profiler SPDisplaysDataType 2>/dev/null | grep -E '^ *(Chipset Model|Bus|VRAM \(Total\)|Vendor|Metal Support|Resolution|UI Looks like|Framebuffer Depth|Main Display|Mirror|Online|Connection Type):' | grep -vi serial)" "system_profiler SPDisplaysDataType"

  # NVRMFB publishes one refresh period and a quarter (flipWaitUs, nvrm-fb.cpp), so the panel rate is 1.25e6 / value.
  nm_say "A3b. NVRMFB: chu kỳ chờ flip do driver công bố -> tần số quét suy ra"
  nm_or "$(ioreg -r -c NVRMNVDAFramebuffer -d 1 -w0 2>/dev/null | grep -E '"NVRMFlipWaitUs"|"NVRMRejectedCommits"|"NVRMModeSwitches"' | sed -E 's/^[ |]*//' | awk '{print} /NVRMFlipWaitUs/ && $NF>0 {printf "   -> tần số suy ra = 1250000 / %s = %.2f Hz\n", $NF, 1250000/$NF}')" "NVRMFlipWaitUs (NVRMFB chưa có mode, hoặc bản đang chạy chưa công bố)"

  # NVRM keeps the copy path when an accelerator whose class does not start with "NV" is registered (NVRM.cpp auto-go).
  nm_say "A3c. Accelerator đang đăng ký (lớp không bắt đầu bằng NV = GPU khác)"
  local acc
  acc=$(ioreg -r -c IOAccelerator -d 1 -w0 2>/dev/null | grep -E '^\+-o ' | sed -E 's/.*<class ([A-Za-z0-9_]+),.*/\1/')
  nm_or "$acc" "không có IOAccelerator nào"
  printf '%s\n' "$acc" | grep -v -E '^(NV|$)' | sed 's/^/   CHÚ Ý: accelerator khác NVIDIA: /'

  nm_say "A3d. Trạng thái do NVRM tự ghi lúc khởi tạo (nvrm-flip, nvrm-display, BAR)"
  nm_or "$(ioreg -r -c NVRM -d 1 -w0 2>/dev/null | grep -E '"nvrm-(flip|display|autogo|boot-hold|bars)"' | sed -E 's/^[ |]*//; s/:0x[0-9a-fA-F]+\+/:<addr>+/g')" "các thuộc tính nvrm-* trên đối tượng NVRM"
  nm_or "$(ioreg -r -k nvrm-gpu-profile -d 1 -w0 2>/dev/null | grep -E '"nvrm-gpu-profile"' | sed -E 's/^[ |]*//')" "nvrm-gpu-profile (có bar1-mb, scanout)"

  nm_say "A3e. Cấu hình runtime đang hiệu lực (chỉ đọc)"
  for k in debug.nvaccel_iop debug.nvaccel_iop_flip debug.nvaccel_iop_async debug.nvaccel_surface_gpu_on debug.nvrmfb_flip_latch debug.nvrmfb_flip_interval debug.nvrmfb_flip_lean debug.nvaccel_headless debug.nvaccel_heads_published debug.nvaccel_heads_piped; do
    v=$(sysctl -n "$k" 2>/dev/null); printf '%-32s %s\n' "$k" "${v:-THIẾU}"
  done

  nm_say "A4. Log kernel từ lúc boot: BAR1, auto-go, phiên bản (địa chỉ đã che)"
  nm_or "$(log show --last boot --style compact --predicate 'process == "kernel" AND (eventMessage CONTAINS "NVRM-xnu: bar1" OR eventMessage CONTAINS "NVRM-xnu: auto-go" OR eventMessage CONTAINS "NVRM-xnu: gpu profile" OR eventMessage CONTAINS "NVRM-xnu: NVRM kext")' 2>&1 | grep -E 'NVRM-xnu|log:|rror' | sed -E 's/0x[0-9a-fA-F]{7,}/0x<addr>/g' | tail -n 40)" "log kernel từ lúc boot (log đã xoay vòng, hoặc tài khoản không đọc được log)"
}

# Cumulative counters first, then the three since-boot maxima (named *_max / *_max_us). The maxima cannot be reset, so
# a measurement only says whether they rose during the window; they are never percentiles.
NM_KEYS="debug.nvaccel_iop_ok debug.nvaccel_iop_flips debug.nvaccel_iop_async_flips debug.nvaccel_iop_async_drop debug.nvaccel_iop_async_refused debug.nvaccel_iop_late debug.nvaccel_iop_flip_lock debug.nvaccel_iop_flip_novram debug.nvaccel_iop_flip_stale debug.nvaccel_iop_flip_unwritten debug.nvaccel_iop_flip_refused debug.nvaccel_iop_flip_home debug.nvaccel_iop_copy_skip debug.nvaccel_iop_copy_unwritten debug.nvaccel_iop_blank debug.nvaccel_iop_fail debug.nvaccel_iop_src_surf debug.nvaccel_iop_src_res debug.nvaccel_surface_gpu_marks debug.nvaccel_surface_gpu_waits debug.nvaccel_surface_gpu_timeouts debug.nvaccel_vm_refused debug.nvrmfb_flip_n debug.nvrmfb_flip_us_sum debug.nvrmfb_flip_latch_waits debug.nvrmfb_flip_latch_deferred debug.nvrmfb_flip_latch_late debug.nvrmfb_flip_latch_timeouts debug.nvaccel_surface_gpu_wait_max_us debug.nvrmfb_flip_latch_max_us debug.nvrmfb_flip_us_max"
nm_snap() { for k in $NM_KEYS; do v=$(sysctl -n "$k" 2>/dev/null); [ -n "$v" ] || v=THIEU; echo "$k $v"; done; }
nm_run() {
  echo "== Lượt '$1': chuẩn bị. Bắt đầu sau 5 giây, kéo dài 30 giây."; sleep 5
  B=$(nm_snap); T0=$(date +%s); printf '\a'; echo ">>> BẮT ĐẦU '$1' lúc $(date '+%H:%M:%S')"
  sleep 30
  A=$(nm_snap); T1=$(date +%s); printf '\a'; echo "<<< DỪNG lúc $(date '+%H:%M:%S')"
  NM_T0=$T0
  { printf '%s\n' "$B" | sed 's/^/B /'; printf '%s\n' "$A" | sed 's/^/A /'; } | awk -v T=$((T1-T0)) -v L="$1" '
    $1=="B"{b[$2]=$3; o[++n]=$2; next} $1=="A"{a[$2]=$3}
    END{ printf "-- %s: T = %d s (độ phân giải 1 s)\n", L, T
      for(i=1;i<=n;i++){k=o[i]; s=k; sub(/^debug\./,"",s)
        if(b[k]=="THIEU"||a[k]=="THIEU"){printf "%-34s THIẾU (driver đang chạy không có counter này)\n", s; continue}
        if(s ~ /_max(_us)?$/){printf "%-34s cực đại từ lúc boot: %s -> %s%s\n", s, b[k], a[k], (a[k]>b[k]?"  (TĂNG trong lượt này)":"  (không đổi)"); continue}
        d=a[k]-b[k]; printf "%-34s delta %12.0f  %9.1f /s%s\n", s, d, (T>0?d/T:0), (d<0?"  (ÂM: counter bị reset/wrap, bỏ dòng này)":"") }
      dn=a["debug.nvrmfb_flip_n"]-b["debug.nvrmfb_flip_n"]; ds=a["debug.nvrmfb_flip_us_sum"]-b["debug.nvrmfb_flip_us_sum"]
      if(dn>0 && a["debug.nvrmfb_flip_n"]!="THIEU") printf "Trung bình thời gian một pure flip (gồm cả chờ latch): %.0f us trên %.0f flip\n", ds/dn, dn }'
}
nm_logs() {
  [ -n "$NM_T0" ] || { echo "THIẾU: chưa có lượt nm_run nào trong shell này"; return 0; }
  s=$(date -r "$NM_T0" '+%Y-%m-%d %H:%M:%S')
  echo "-- log kernel NullMoth từ $s (địa chỉ đã che)"
  nm_or "$(log show --style compact --start "$s" --predicate 'process == "kernel" AND (eventMessage CONTAINS "NVRM-fb: present stats" OR eventMessage CONTAINS "NVRM-fb: flip on head" OR eventMessage CONTAINS "NVRM-fb: presentation blocked" OR eventMessage CONTAINS "NVAccel: iop:" OR eventMessage CONTAINS "NVAccel: surfvram pageoff")' 2>&1 | grep -E 'NVRM-fb|NVAccel|log:|rror' | sed -E 's/0x[0-9a-fA-F]{7,}/0x<addr>/g' | tail -n 30)" "không có dòng log kernel NullMoth nào khớp trong lượt này"
  echo "-- lỗi plugin Metal (tiền tố NullMoth:) từ $s"
  nm_or "$(log show --style compact --start "$s" --predicate 'eventMessage BEGINSWITH "NullMoth:"' 2>&1 | grep -E 'NullMoth:|log:' | sed -E 's/0x[0-9a-fA-F]{7,}/0x<addr>/g' | tail -n 15)" "không có dòng NullMoth: nào trong lượt này"
}

nm_main() {
  case "${1:-}" in
    status) nm_status ;;
    # The 12 s wait lets the last 10 s present-stats window close and reach the log before it is read.
    measure) nm_run "${2:-luot}"; sleep 12; nm_logs ;;
    *) echo "usage: bash $0 status | measure <label>"; return 2 ;;
  esac
}
# Sourced (". tools/nm_readonly_diagnostics.sh"): only define the functions, as when the blocks are pasted by hand.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then nm_main "$@"; fi
