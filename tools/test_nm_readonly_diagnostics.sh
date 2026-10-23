#!/bin/bash
# test_nm_readonly_diagnostics.sh <script>: checks tools/nm_readonly_diagnostics.sh on simulated reads (no macOS needed):
# the delta arithmetic and its refusals (a counter missing on either read, a reset, a zero window), the gauges, log
# clipping and windows, the conf allowlist and the debug boot-arg warnings. Run by tools/test_nm_readonly_diagnostics.py.
SCRIPT=$1
. "$SCRIPT"
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS  $1"; }
bad() { fail=$((fail+1)); echo "FAIL  $1"; echo "----- đầu ra:"; printf '%s\n' "$2"; echo "-----"; }
has()   { if printf '%s\n' "$2" | grep -qF -- "$3"; then ok "$1"; else bad "$1 (thiếu: $3)" "$2"; fi; }
hasnt() { if printf '%s\n' "$2" | grep -qF -- "$3"; then bad "$1 (không được có: $3)" "$2"; else ok "$1"; fi; }

# snap <default> [key=value ...]: one simulated read, every counter and gauge = default except the keys overridden
snap() { local d=$1; shift; for k in $NM_KEYS $NM_GAUGES; do v=$d; for o in "$@"; do [ "${o%%=*}" = "$k" ] && v=${o#*=}; done; echo "$k $v"; done; }
N=debug.nvrmfb_flip_n; U=debug.nvrmfb_flip_us_sum; F=debug.nvaccel_iop_flips; M=debug.nvrmfb_flip_latch_max_us

echo "== nm_delta"
out=$(nm_delta binh-thuong 30 "$(snap 100 $N=900000 $U=3000000000 $M=444)" "$(snap 160 $N=904320 $U=3030240000 $M=494)")
has "bình thường: trung bình flip đúng" "$out" "7000 us trên 4320 flip"
has "bình thường: delta và tốc độ" "$out" "nvaccel_iop_flips                  delta           60        2.0 /s"
has "bình thường: cực đại tăng" "$out" "nvrmfb_flip_latch_max_us           cực đại từ lúc boot: 444 -> 494  (TĂNG trong lượt này)"

out=$(nm_delta thieu-truoc 30 "$(snap 100 $F=THIEU)" "$(snap 160)")
has "thiếu ở lượt đọc trước" "$out" "nvaccel_iop_flips                  THIẾU (driver đang chạy không có counter này ở lượt đọc trước)"
out=$(nm_delta thieu-sau 30 "$(snap 100)" "$(snap 160 $F=THIEU)")
has "thiếu ở lượt đọc sau" "$out" "THIẾU (driver đang chạy không có counter này ở lượt đọc sau)"
out=$(nm_delta thieu-ca-hai 30 "$(snap 100 $F=THIEU)" "$(snap 160 $F=THIEU)")
has "thiếu ở cả hai lượt" "$out" "THIẾU (driver đang chạy không có counter này ở lượt đọc trước và sau)"

for side in B A; do for key in $N $U; do
  if [ $side = B ]; then b="$(snap 100 $key=THIEU)"; a="$(snap 160)"; else b="$(snap 100)"; a="$(snap 160 $key=THIEU)"; fi
  out=$(nm_delta x 30 "$b" "$a")
  has "trung bình flip báo THIẾU khi ${key#debug.} thiếu ở lượt $side" "$out" "Trung bình pure flip: THIẾU"
  hasnt "không tính trung bình khi ${key#debug.} thiếu ở lượt $side" "$out" "us trên"
done; done

out=$(nm_delta khong-phai-so 30 "$(snap 100 $F=abc $N=12x)" "$(snap 160)")
has "giá trị không phải số" "$out" "nvaccel_iop_flips                  KHÔNG HỢP LỆ (giá trị đọc được không phải số nguyên)"
has "flip_n không phải số -> trung bình THIẾU" "$out" "Trung bình pure flip: THIẾU"

out=$(nm_delta reset 30 "$(snap 5000 $N=900000 $U=3000000000 $M=900)" "$(snap 20 $N=150 $U=1050000 $M=120)")
has "reset: delta âm được đánh dấu" "$out" "(ÂM: counter bị reset/wrap, bỏ dòng này)"
has "reset: cực đại giảm được đánh dấu" "$out" "(GIẢM: counter bị reset, bỏ dòng này)"
has "reset: trung bình flip không hợp lệ" "$out" "Trung bình pure flip: KHÔNG HỢP LỆ (delta flip_n = -899850"
hasnt "reset: không in trung bình" "$out" "us trên"

out=$(nm_delta sum-giam 30 "$(snap 100 $N=100 $U=5000)" "$(snap 100 $N=200 $U=4000)")
has "flip_n tăng nhưng flip_us_sum giảm -> không hợp lệ" "$out" "delta flip_n = 100, delta flip_us_sum = -1000"

out=$(nm_delta delta-0 30 "$(snap 100 $M=444)" "$(snap 100 $M=444)")
has "delta 0: counter in 0" "$out" "nvaccel_iop_ok                     delta            0        0.0 /s"
has "delta 0: trung bình flip không hợp lệ" "$out" "Trung bình pure flip: KHÔNG HỢP LỆ (delta flip_n = 0, delta flip_us_sum = 0"
has "delta 0: cực đại không đổi" "$out" "(không đổi)"
hasnt "delta 0: không chia cho 0" "$out" "us trên"

out=$(nm_delta flip-sum-0 30 "$(snap 100 $N=10 $U=500)" "$(snap 100 $N=20 $U=500)")
has "delta_sum = 0 với delta_n > 0 vẫn tính (0 us)" "$out" "0 us trên 10 flip"

out=$(nm_delta T0 0 "$(snap 100)" "$(snap 130)")
has "T = 0: không chia cho 0" "$out" "delta           30        0.0 /s"

echo "== gauges and the counters added for VRAM, surfaces and interrupts"
G=debug.nvrmfb_vram_mapped_bytes; R=debug.nvrmfb_vram_grants
out=$(nm_delta gauge 30 "$(snap 100 $G=1048576 $R=7)" "$(snap 160 $G=2097152 $R=19)")
has "gauge: before -> after" "$out" "nvrmfb_vram_mapped_bytes           giá trị tức thời: 1048576 -> 2097152 (không phải counter: không tính delta)"
hasnt "gauge: no delta" "$out" "nvrmfb_vram_mapped_bytes           delta"
has "grants: delta and rate" "$out" "nvrmfb_vram_grants                 delta           12        0.4 /s"
for k in nvaccel_vm_alloc nvaccel_vm_parked nvaccel_res_new nvaccel_map_commit nvrmfb_vram_grant_bytes nvrm_isr_count nvrm_evt_waits nvrmfb_vram_budget_bytes nvrmfb_vram_display_bytes; do
  has "read and reported: $k" "$out" "$k "
done
out=$(nm_delta gauge-missing 30 "$(snap 100 $G=THIEU)" "$(snap 160)")
has "gauge missing before (registered at the first grant)" "$out" "nvrmfb_vram_mapped_bytes           THIẾU (driver đang chạy không có counter này ở lượt đọc trước)"

echo "== conf allowlist"
D=$(mktemp -d)
cat > "$D/c.conf" <<'CONF'
# comment NVRM_EVENT_WAIT=9
   NVRM_EVENT_WAIT = 1
NVMTL_GSUB_INFLIGHT=8
NVRM_EVENT_WAIT=0
NVMTL_LOG_PATH=/Users/someone/private/SECRETPATH
NVMTL_SURFIN_UPLOAD=/Users/someone/SECRETVALUE/that/is/long
NVMTL_ZPROBE=SECRETTOKEN
OTHERTHING=SECRETOTHER

no equals sign here SECRETLINE
CONF
out=$(nm_conf "$D/c.conf")
has "allowlisted key, value as the plugin takes it" "$out" 'NVRM_EVENT_WAIT              = " 1"'
has "allowlisted key" "$out" 'NVMTL_GSUB_INFLIGHT          = "8"'
has "long value not printed" "$out" "NVMTL_SURFIN_UPLOAD          = <không in: giá trị không phải chuỗi ngắn đơn giản>"
hasnt "nothing secret printed" "$out" "SECRET"
hasnt "keys outside the allowlist not named" "$out" "NVMTL_LOG_PATH"
hasnt "keys outside the allowlist not named (2)" "$out" "NVMTL_ZPROBE"
hasnt "the later duplicate is not taken" "$out" '= "0"'
has "others only counted" "$out" "Khóa plugin khác (không in): 2; dòng plugin bỏ qua vì không có tiền tố NVMTL_/NVK_/NVRM_: 1; khóa allowlist lặp lại (plugin chỉ lấy lần đầu): 1"
printf '# only a comment\nNVMTL_ZPROBE=1\n' > "$D/d.conf"
out=$(nm_conf "$D/d.conf")
has "no allowlisted key: defaults" "$out" "(không có khóa nào trong allowlist"
out=$(nm_conf "$D/none.conf")
has "missing file" "$out" "THIẾU: $D/none.conf không có"
if [ "$(id -u)" != 0 ]; then
  cp "$D/c.conf" "$D/u.conf"; chmod 000 "$D/u.conf"; out=$(nm_conf "$D/u.conf")
  has "unreadable file" "$out" "THIẾU: không đọc được"
fi
rm -rf "$D"

echo "== debug boot-args"
D=$(mktemp -d); touch "$D/GLOBBED_FILE"
out=$(cd "$D" && nm_bootarg_warn 'keepsyms=1 -nvrmnoflip nvfbsample nvhwvbl=0 nvhud=0 nvrmdiag=1 *')
has "flag" "$out" "CHÚ Ý: -nvrmnoflip"
has "bare numeric arg reads as 1" "$out" "CHÚ Ý: nvfbsample=1"
has "nvhwvbl=0" "$out" "CHÚ Ý: nvhwvbl=0"
has "nvrmdiag=1" "$out" "CHÚ Ý: nvrmdiag=1"
hasnt "nvhud=0 is off" "$out" "nvhud"
hasnt "no glob expansion" "$out" "GLOBBED_FILE"
rm -rf "$D"
out=$(nm_bootarg_warn 'keepsyms=1 nvhwvbl=1 nvaccel=1')
has "none of the list" "$out" "(không thấy boot-arg debug nào"
out=$(nm_bootarg_warn '')
has "empty boot-args" "$out" "(không thấy boot-arg debug nào"

echo "== nm_clip"
out=$(printf 'l1\nl2\nl3\nl4\nl5\n' | nm_clip 3)
has "cắt: báo đã cắt" "$out" "[ĐÃ CẮT: chỉ hiện 3 dòng cuối trong 5 dòng khớp]"
has "cắt: giữ dòng cuối" "$out" "l5"
hasnt "cắt: bỏ dòng đầu" "$out" "l1"
out=$(printf 'l1\nl2\nl3\n' | nm_clip 3)
hasnt "đúng giới hạn: không báo cắt" "$out" "ĐÃ CẮT"
out=$(nm_or "$(printf '' | nm_clip 3)" "không có dòng")
has "rỗng: nm_or báo THIẾU" "$out" "THIẾU: không có dòng"

echo "== nm_logs"
NM_T0=; NM_T1=
out=$(nm_logs)
has "chưa đo: nm_logs báo THIẾU" "$out" "THIẾU: chưa có lượt nm_run nào"
NM_T0=1000; NM_T1=1031
date() { if [ "$1" = -r ]; then echo "T$2"; else echo "NOW"; fi; }
log() { local s e; while [ $# -gt 0 ]; do case $1 in --start) s=$2; shift;; --end) e=$2; shift;; esac; shift; done
        echo "x NVRM-fb: present stats from $s to $e 0xffffff8012345678"; }
out=$(nm_logs)
has "cửa sổ đo dùng --start T0 --end T1+1" "$out" "NVRM-fb: present stats from T1000 to T1032"
has "phần sau đo dùng --start T1+1 --end bây giờ" "$out" "NVRM-fb: present stats from T1032 to NOW"
has "nhãn cửa sổ đo" "$out" "-- [CỬA SỔ ĐO] log kernel NullMoth T1000 -> T1032"
has "nhãn sau đo tách riêng" "$out" "-- [SAU KHI DỪNG, không thuộc kết quả 30 s] log kernel NullMoth T1032 -> NOW"
has "che địa chỉ" "$out" "0x<addr>"
has "nhắc kiểm tra trước khi chia sẻ" "$out" "KHÔNG được bảo đảm ẩn danh"
w=$(printf '%s\n' "$out" | grep -n 'CỬA SỔ ĐO\] log kernel' | cut -d: -f1); p=$(printf '%s\n' "$out" | grep -n 'SAU KHI DỪNG, không thuộc kết quả 30 s\] log kernel' | cut -d: -f1)
if [ -n "$w" ] && [ -n "$p" ] && [ "$w" -lt "$p" ]; then ok "cửa sổ đo in trước phần sau đo"; else bad "thứ tự phần log" "$out"; fi
log() { local i; for i in $(seq 1 45); do echo "x NVRM-fb: present stats line $i"; done; }
out=$(nm_logs)
has "log nhiều dòng: báo cắt ở phần kernel (30)" "$out" "[ĐÃ CẮT: chỉ hiện 30 dòng cuối trong 45 dòng khớp]"
log() { echo "log: Cannot run while sandboxed"; }
out=$(nm_logs)
has "thiếu quyền log: in lỗi và chạy tiếp" "$out" "log: Cannot run while sandboxed"
has "thiếu quyền log: vẫn in phần sau đo" "$out" "SAU KHI DỪNG"
unset -f date log

echo "== luồng measure đầy đủ (sysctl/sleep/log giả lập)"
out=$(PH=$(mktemp); echo 0 > "$PH"
  sysctl() { local p; p=$(cat "$PH"); case $2 in debug.nvrmfb_flip_latch_deferred) return 1;; debug.nvrmfb_flip_n) echo $((900000 + p*4320));; debug.nvrmfb_flip_us_sum) echo $((3000000000 + p*30240000));; *) echo $((100 + p*60));; esac; }
  sleep() { [ "$1" = 30 ] && echo 1 > "$PH"; :; }
  log() { :; }
  nm_main measure tich-hop; rm -f "$PH")
has "measure: trung bình flip" "$out" "7000 us trên 4320 flip"
has "measure: counter thiếu ở cả hai lượt" "$out" "nvrmfb_flip_latch_deferred         THIẾU (driver đang chạy không có counter này ở lượt đọc trước và sau)"
has "measure: có phần sau đo" "$out" "SAU KHI DỪNG"

echo "== usage / status / source"
out=$(bash "$SCRIPT" 2>&1); rc=$?
has "không tham số: in usage" "$out" "usage:"
[ $rc = 2 ] && ok "không tham số: rc = 2" || bad "rc usage = $rc" "$out"
out=$(bash "$SCRIPT" status 2>&1)
has "status chạy tới cuối trên máy không phải macOS" "$out" "KHÔNG được bảo đảm ẩn danh"
has "status báo thiếu thay vì dừng" "$out" "THIẾU: kmutil"
has "status reaches the conf section" "$out" "A5. Khóa plugin trong nvrm610.conf"
out=$(bash -c ". '$SCRIPT'; echo SOURCED_ONLY" 2>&1)
[ "$out" = SOURCED_ONLY ] && ok "source chỉ định nghĩa hàm, không chạy" || bad "source chạy main" "$out"

echo "== tổng: $pass PASS, $fail FAIL"
[ $fail = 0 ]
