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
#                     the deltas, then the kernel log lines of that window, then (separately) the lines logged in the
#                     12 s after it
#
# Run it with bash (macOS's zsh does not split $NM_KEYS into words):
#   bash tools/nm_readonly_diagnostics.sh status
#   bash tools/nm_readonly_diagnostics.sh measure nen-dung-yen
#   bash tools/nm_readonly_diagnostics.sh measure keo-cua-so
#   bash tools/nm_readonly_diagnostics.sh measure cuon
#
# The counter, property and log names are the ones the kexts define at v2.5.3 (75e2e28): NVAccel
# kexts/NVRM/accel/nvrm-accel.cpp, NVRMFB kexts/NVRMFB/fb/nvrm-fb.cpp, NVRM kexts/NVRM/NVRM.cpp. An older driver
# may lack some of them. The filters leave out the fields known to carry serial numbers and the full NVRAM /
# IORegistry, and mask long hex addresses, but the output is not guaranteed anonymous: boot-args and log lines are
# printed as the system has them. Read them before sharing.

nm_say() { printf '\n== %s\n' "$1"; }
nm_or() { if [ -n "$1" ]; then printf '%s\n' "$1"; else echo "THIẾU: $2"; fi; }
nm_share_note() { printf '\n!! Trước khi chia sẻ: tự đọc lại boot-args và các dòng log ở trên. Bộ lọc chỉ bỏ các trường đã biết và che địa chỉ dài; đầu ra KHÔNG được bảo đảm ẩn danh.\n'; }
# Keeps the last <n> lines of stdin and says so when more matched, so a capped log is never mistaken for a complete one.
nm_clip() {
  local n=$1 t c
  t=$(cat)
  [ -n "$t" ] || return 0
  c=$(printf '%s\n' "$t" | wc -l | tr -d ' ')
  printf '%s\n' "$t" | tail -n "$n"
  if [ "$c" -gt "$n" ]; then echo "[ĐÃ CẮT: chỉ hiện $n dòng cuối trong $c dòng khớp]"; fi
}

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
  nm_or "$(log show --last boot --style compact --predicate 'process == "kernel" AND (eventMessage CONTAINS "NVRM-xnu: bar1" OR eventMessage CONTAINS "NVRM-xnu: auto-go" OR eventMessage CONTAINS "NVRM-xnu: gpu profile" OR eventMessage CONTAINS "NVRM-xnu: NVRM kext")' 2>&1 | grep -E 'NVRM-xnu|log:|rror' | sed -E 's/0x[0-9a-fA-F]{7,}/0x<addr>/g' | nm_clip 40)" "log kernel từ lúc boot (log đã xoay vòng, hoặc tài khoản không đọc được log)"
  nm_share_note
}

# Cumulative counters first, then the three since-boot maxima (named *_max / *_max_us). The maxima cannot be reset, so
# a measurement only says whether they rose during the window; they are never percentiles.
NM_KEYS="debug.nvaccel_iop_ok debug.nvaccel_iop_flips debug.nvaccel_iop_async_flips debug.nvaccel_iop_async_drop debug.nvaccel_iop_async_refused debug.nvaccel_iop_late debug.nvaccel_iop_flip_lock debug.nvaccel_iop_flip_novram debug.nvaccel_iop_flip_stale debug.nvaccel_iop_flip_unwritten debug.nvaccel_iop_flip_refused debug.nvaccel_iop_flip_home debug.nvaccel_iop_copy_skip debug.nvaccel_iop_copy_unwritten debug.nvaccel_iop_blank debug.nvaccel_iop_fail debug.nvaccel_iop_src_surf debug.nvaccel_iop_src_res debug.nvaccel_surface_gpu_marks debug.nvaccel_surface_gpu_waits debug.nvaccel_surface_gpu_timeouts debug.nvaccel_vm_refused debug.nvrmfb_flip_n debug.nvrmfb_flip_us_sum debug.nvrmfb_flip_latch_waits debug.nvrmfb_flip_latch_deferred debug.nvrmfb_flip_latch_late debug.nvrmfb_flip_latch_timeouts debug.nvaccel_surface_gpu_wait_max_us debug.nvrmfb_flip_latch_max_us debug.nvrmfb_flip_us_max"
nm_snap() { for k in $NM_KEYS; do v=$(sysctl -n "$k" 2>/dev/null); [ -n "$v" ] || v=THIEU; echo "$k $v"; done; }
# nm_delta <label> <seconds> <before> <after>: the deltas of one window. Both reads of every counter must be integers;
# a counter the running driver lacks (THIEU) or a garbled read on either side is reported instead of counting as 0.
nm_delta() {
  { printf '%s\n' "$3" | sed 's/^/B /'; printf '%s\n' "$4" | sed 's/^/A /'; } | awk -v T="$2" -v L="$1" '
    function num(x) { return x ~ /^-?[0-9]+$/ }
    function side(x, y) { return (x=="THIEU" && y=="THIEU") ? "trước và sau" : (x=="THIEU" ? "trước" : "sau") }
    function why(x, y) { return (x=="THIEU" || y=="THIEU") ? "THIẾU (driver đang chạy không có counter này ở lượt đọc " side(x, y) ")" : "KHÔNG HỢP LỆ (giá trị đọc được không phải số nguyên)" }
    $1=="B"{b[$2]=$3; o[++n]=$2; next} $1=="A"{a[$2]=$3}
    END{ printf "-- %s: T = %d s (độ phân giải 1 s)\n", L, T
      for(i=1;i<=n;i++){k=o[i]; s=k; sub(/^debug\./,"",s)
        if(!num(b[k]) || !num(a[k])){printf "%-34s %s\n", s, why(b[k], a[k]); continue}
        if(s ~ /_max(_us)?$/){printf "%-34s cực đại từ lúc boot: %s -> %s%s\n", s, b[k], a[k], (a[k]+0>b[k]+0 ? "  (TĂNG trong lượt này)" : (a[k]+0<b[k]+0 ? "  (GIẢM: counter bị reset, bỏ dòng này)" : "  (không đổi)")); continue}
        d=a[k]-b[k]; printf "%-34s delta %12.0f  %9.1f /s%s\n", s, d, (T>0?d/T:0), (d<0?"  (ÂM: counter bị reset/wrap, bỏ dòng này)":"") }
      kn="debug.nvrmfb_flip_n"; ks="debug.nvrmfb_flip_us_sum"
      if(!num(b[kn]) || !num(a[kn]) || !num(b[ks]) || !num(a[ks])) {
        print "Trung bình pure flip: THIẾU (cần nvrmfb_flip_n và nvrmfb_flip_us_sum là số nguyên ở cả lượt đọc trước và sau)"; exit }
      dn=a[kn]-b[kn]; ds=a[ks]-b[ks]
      if(dn<=0 || ds<0) {
        printf "Trung bình pure flip: KHÔNG HỢP LỆ (delta flip_n = %.0f, delta flip_us_sum = %.0f; cần delta flip_n > 0 và delta flip_us_sum >= 0)\n", dn, ds; exit }
      printf "Trung bình thời gian một pure flip (gồm cả chờ latch): %.0f us trên %.0f flip\n", ds/dn, dn }'
}
# NM_T0 is taken before the first read and NM_T1 after the second, so the log window covers both snapshots.
nm_run() {
  echo "== Lượt '$1': chuẩn bị. Bắt đầu sau 5 giây, kéo dài 30 giây."; sleep 5
  NM_T0=$(date +%s); B=$(nm_snap); printf '\a'; echo ">>> BẮT ĐẦU '$1' lúc $(date '+%H:%M:%S')"
  sleep 30
  A=$(nm_snap); NM_T1=$(date +%s); printf '\a'; echo "<<< DỪNG lúc $(date '+%H:%M:%S')"
  nm_delta "$1" $((NM_T1 - NM_T0)) "$B" "$A"
}
nm_log_kernel() {
  log show --style compact --start "$1" --end "$2" --predicate 'process == "kernel" AND (eventMessage CONTAINS "NVRM-fb: present stats" OR eventMessage CONTAINS "NVRM-fb: flip on head" OR eventMessage CONTAINS "NVRM-fb: presentation blocked" OR eventMessage CONTAINS "NVAccel: iop:" OR eventMessage CONTAINS "NVAccel: surfvram pageoff")' 2>&1 | grep -E 'NVRM-fb|NVAccel|log:|rror' | sed -E 's/0x[0-9a-fA-F]{7,}/0x<addr>/g' | nm_clip 30
}
nm_log_plugin() {
  log show --style compact --start "$1" --end "$2" --predicate 'eventMessage BEGINSWITH "NullMoth:"' 2>&1 | grep -E 'NullMoth:|log:' | sed -E 's/0x[0-9a-fA-F]{7,}/0x<addr>/g' | nm_clip 15
}
# The measured window (whole seconds, its end rounded up) and, apart from it, what was logged after it: a present-stats
# window that was still open at the stop closes and prints afterwards, and it can also cover time outside the 30 s.
nm_logs() {
  { [ -n "$NM_T0" ] && [ -n "$NM_T1" ]; } || { echo "THIẾU: chưa có lượt nm_run nào trong shell này"; return 0; }
  local s e now
  s=$(date -r "$NM_T0" '+%Y-%m-%d %H:%M:%S'); e=$(date -r "$((NM_T1 + 1))" '+%Y-%m-%d %H:%M:%S'); now=$(date '+%Y-%m-%d %H:%M:%S')
  echo "-- [CỬA SỔ ĐO] log kernel NullMoth $s -> $e (địa chỉ đã che)"
  nm_or "$(nm_log_kernel "$s" "$e")" "không có dòng log kernel NullMoth nào khớp trong cửa sổ đo"
  echo "-- [CỬA SỔ ĐO] lỗi plugin Metal (tiền tố NullMoth:) $s -> $e"
  nm_or "$(nm_log_plugin "$s" "$e")" "không có dòng NullMoth: nào trong cửa sổ đo"
  echo "-- [SAU KHI DỪNG, không thuộc kết quả 30 s] log kernel NullMoth $e -> $now"
  nm_or "$(nm_log_kernel "$e" "$now")" "không có dòng log kernel NullMoth nào sau khi dừng"
  echo "-- [SAU KHI DỪNG, không thuộc kết quả 30 s] lỗi plugin Metal $e -> $now"
  nm_or "$(nm_log_plugin "$e" "$now")" "không có dòng NullMoth: nào sau khi dừng"
  nm_share_note
}

nm_main() {
  case "${1:-}" in
    status) nm_status ;;
    # The 12 s wait lets the last 10 s present-stats window close and reach the log; nm_logs prints it apart.
    measure) nm_run "${2:-luot}"; sleep 12; nm_logs ;;
    *) echo "usage: bash $0 status | measure <label>"; return 2 ;;
  esac
}
# Sourced (". tools/nm_readonly_diagnostics.sh"): only define the functions, as when the blocks are pasted by hand.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then nm_main "$@"; fi
