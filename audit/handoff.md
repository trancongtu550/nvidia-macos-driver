# Bàn giao đợt tối ưu — branch `claude/vigilant-mayer-ptq05r-integration`

Gốc: `75e2e28` (= upstream v2.5.3). Fork cá nhân; chưa merge, chưa phát hành, không gửi upstream. **Chưa build trên macOS và chưa
đo trên phần cứng**: mọi thay đổi dưới đây chưa được chứng minh làm tăng FPS hay cải thiện frame pacing.

## 1. Các commit (mỗi commit revert được; xem mục 7)

| Commit | Loại | Nội dung |
|---|---|---|
| `af71166`, `7f6ece4`, `0fe017d` | Công cụ đo (T2) | Script chẩn đoán chỉ đọc `tools/nm_readonly_diagnostics.sh` + harness |
| `226f0a1`, `b565d6c` | Sửa correctness (T6) — **không phải tối ưu** | Khóa cho bảng thống kê submit `nvmtl_subwho_note`; test chạy được trên macOS về mặt mã, không che lỗi biên dịch; đo overhead CPU |
| `ba26f85`, `28525ad`, `c8112a8` | Công cụ build | `tools/nm_build_plugin.sh` (build tái lập, kiểm artifact, đối chiếu chỉ đọc), kiểm đường dẫn output, biến thể `--opt O2`; `tools/test_plugin_abi_contract.py` |
| `ba973b2`, `2004c9c` | Công cụ test | `tools/run_tool_tests.py` (phân loại PASS/SKIP/MISSING/DEPFAIL/FAIL); `tools/check_plugin_c_delta.py` (chẩn đoán mới mà một thay đổi thêm vào `nvmtl_vk.c`, không cần macOS) |
| `4f5adf2` và commit cuối | Test, tài liệu | Fixture `test_vram_tag_key` không còn ghi chung giữa các luồng; `tools/test_flip_counter_docs.py`; sửa mục 6-8 của tài liệu này |
| `024bfdc` | Tối ưu CPU | Không bind lại index buffer đang có hiệu lực |
| `d895e59` | Tối ưu CPU | Không bind lại vertex buffer đang có hiệu lực (bản ghi bị xóa mỗi khi pipeline đồ họa đổi) |
| `218533a` | Tối ưu CPU | Khóa `CFString` của tag VRAM IOSurface tạo một lần cho mỗi plane 0-3, thay vì mỗi lần đọc tag |
| `63afab4` | Tối ưu CPU | Bản release không đọc đồng hồ để poll file yêu cầu debug trên đường encode |

## 2. Tối ưu đã làm: bằng chứng và giới hạn

| Thay đổi | Bằng chứng trong mã nguồn (base) | Vì sao giữ nguyên hành vi | Test | Chưa chứng minh |
|---|---|---|---|---|
| Khử bind index trùng (`plugin/nvmtl_bind_cache.h`, `nvmtl_vk.c` `nvmtl_bind_index`) | `nvmtl_vk_cmd_draw_indexed` và `_indirect` gọi `vkCmdBindIndexBuffer` trước **mọi** draw có index (`nvmtl_vk.c:5510, 6584`) | Binding index tồn tại trong command buffer tới khi bị bind lại (Vulkan). Bản ghi nằm trong `nvk_cmdbuf`, bị `memset` ở `nvmtl_vk_cmd_begin` cho mỗi command buffer mới — cùng vòng đời với cache pipeline/descriptor set upstream đã dùng. Mọi `vkCmdBindIndexBuffer` đi qua bản ghi | `tools/test_bind_cache.py`: mô hình trạng thái binding Vulkan, 200.000 lệnh ngẫu nhiên, mỗi draw phải thấy đúng binding đã yêu cầu; 5 đối chứng âm; kiểm nguồn (một điểm bind, reset khi begin) | Lợi ích (số lệnh NVK tránh được, thời gian CPU) chưa đo. Giả định giống cache pipeline upstream: thao tác nội bộ của NVK (meta) khôi phục binding sau khi dùng — không kiểm được vì thiếu nguồn Mesa trong cloud |
| Khử bind vertex trùng | `nvmtl_vk_cmd_vertex_inputs` bind từng buffer thuộc tính trước mỗi draw (`nvmtl_vk.c:5477, 5486`) | Như trên; stride của `vkCmdBindVertexBuffers2` là dynamic state mà pipeline có stride tĩnh ghi đè, nên bản ghi bị xóa ngay khi `nvmtl_vk_cmd_bind_pipeline` bind pipeline khác (kể cả khi giữa đó không bind vertex) — có ca A→B→A trong test | cùng test + đối chứng "bản ghi giữ qua đổi pipeline", "bỏ qua stride" | như trên; chỉ có lợi khi các draw liên tiếp dùng cùng pipeline |
| Khóa tag IOSurface một lần/plane (`NVMTLDevice.m` `nvmtl_vram_tag_key`) | `CFStringCreateWithFormat` mỗi lần đọc/ghi tag; `nvmtlSurfaceIn` đọc tag (`nvmtl_vram_gen`) trên mỗi lần bind texture IOSurface không ở VRAM chung, **trước** bước bỏ qua upload | Khóa là chuỗi hằng theo plane; giá trị được so bằng nội dung. Cả 4 nơi gọi đều `CFRelease`; hàm trả `CFRetain` của khóa cache nên số tham chiếu cân bằng; công bố bằng compare-and-swap | `tools/test_vram_tag_key.py`: CoreFoundation giả có đếm tham chiếu; đúng chuỗi, đúng 1 khóa sống/plane, 8 luồng (thường + TSAN + ASAN); 2 đối chứng âm | `IOSurfaceCopyValue` (lời gọi tới kernel) vẫn còn và không cache được an toàn (không có bộ đếm thay đổi); lợi ích chưa đo |
| Bỏ poll debug trong release | `nvmtl_surface_cpu_dump` (mỗi bind fragment texture), `nvmtl_pt_armed` (mỗi render pass), `nvmtl_noseed` (mỗi surface-out) đọc đồng hồ mỗi lần gọi | Release định nghĩa lại `access()` thành `nvmtl_rel_access`, luôn từ chối `/tmp/nvmtl-*`, nên các hàm này không bao giờ bật trong release; cùng mẫu với `nvmtl_trace_on` đã có | `tools/test_release_debug_polls.py`: chạy mã thật của 2 hàm C với file yêu cầu "có mặt": release giống nhau có/không early-return, bản dev vẫn bật; 2 đối chứng âm | Chỉ bớt một lần đọc đồng hồ mỗi lần gọi; chưa đo |

## 3. Ứng viên đã kiểm và **không** triển khai

| Ứng viên | Kết luận | Lý do |
|---|---|---|
| Khử `vkCmdSetPrimitiveTopology`/`RestartEnable` trùng mỗi draw | Không làm | Chi phí còn lại cỡ 2 lời gọi hàm/draw; muốn đúng phải vô hiệu hóa khi bind pipeline có topology tĩnh — rủi ro lớn hơn lợi ích |
| `NSString` khóa khi bind sampler (`NVMTLObjects.m:3084, 3095`) | Không làm | Objective-C/Foundation: không test được trong cloud; với chỉ số nhỏ, runtime có thể dùng tagged pointer (không cấp phát heap) — chưa chứng minh có chi phí đáng kể |
| Cache `VkFramebuffer` giữa các render pass | Không làm | Hủy framebuffer phải đợi GPU xong mọi command buffer dùng nó, và phải vô hiệu hóa khi view bị hủy → cần theo dõi hoàn tất GPU; lợi ích chỉ là một lần cấp phát mỗi pass |
| Logging trên đường nóng | Không làm | Release chỉ ghi dòng lỗi; các `nvlog` trên đường draw/bind đều có bộ đếm "chỉ vài lần đầu"; `nvmtl_trace_on` đã trả 0 trong release |
| Cấp phát lặp ở `endEncoding` (`NSMutableDictionary`) | Không làm | Objective-C, nhỏ, không test được trong cloud |
| Đường nhanh cho khóa toàn cục `nvmtl_surface_sync` | Không làm (ứng viên cho đợt có macOS) | Objective-C runtime (associated object): cần test trên macOS |
| Upload/readback bất đồng bộ cho surface (F3) | Không làm | Chưa chứng minh: unlock IOSurface từ luồng hoàn tất, thứ tự khóa `nvmtl_surface_sync` ↔ khóa lớp ↔ `nvmtl_submit_mutex`, ghi seed chỉ sau fence, vòng đời import tới fence. Upstream đã có `NVMTL_ASYNC_TEX_UPLOAD=1` (opt-in, có test) nhưng chỉ cho `replaceRegion`, không cho surface-in |
| VRAM/BAR1, xóa VRAM ngoài display gate (F1), khóa display, fence | Không làm | Mã kernel: repo không build được NVRM/NVRMFB (F11); thứ tự khóa phụ thuộc family của Apple (không có nguồn) |
| Tắt assert NVK (`-Db_ndebug=true`, F18) | Không làm | Yêu cầu: không mặc định tắt assert/kiểm tra an toàn |

## 4. Test thực sự đã chạy (cloud: Linux x86_64, Python 3.13, gcc 13, clang 18; không macOS)

| Checkout | Tổng | PASS | FAIL | SKIP | MISSING (thiếu môi trường) | DEPFAIL |
|---|---:|---:|---:|---:|---:|---:|
| baseline `75e2e28` | 70 | 51 | 0 | 0 | 18 | 1 |
| integration (đầu nhánh) | 78 | 59 | 0 | 0 | 18 | 1 |

- 70/70 test có sẵn giữ nguyên trạng thái; 8 test mới đều PASS: `test_bind_cache`, `test_vram_tag_key`, `test_release_debug_polls`,
  `test_subwho_census`, `test_nm_build_plugin`, `test_plugin_abi_contract`, `test_nm_readonly_diagnostics`, `test_flip_counter_docs`.
- 18 MISSING: cần `xcrun`/macOS SDK (11), Foundation/Metal (3), `ditto` (1), header macOS (1), bản build translator (1), một
  commit không có trong lịch sử công khai (1). DEPFAIL `test_primary_gpu_install`: mọi case hỏng vì thiếu `ditto`.
- Sanitizer thực sự chạy: **gcc 13** có runtime ThreadSanitizer và AddressSanitizer — các nhánh TSAN/ASAN của `test_vram_tag_key`
  và `test_subwho_census` chạy bằng gcc (`cc`). **clang 18** ở đây không có runtime nào của hai sanitizer: với `CC=clang`, nhánh
  thường chạy bằng clang còn nhánh sanitizer rơi về gcc; khi chỉ có clang 18 trong `PATH`, 2 nhánh sanitizer của
  `test_vram_tag_key` (và 3 của `test_subwho_census`) báo SKIP kèm lý do, nhánh thường vẫn chạy. Chưa chạy trên macOS.
- `test_vram_tag_key`: fixture không còn đối tượng ghi chung giữa các luồng (`CFSTR` là đối tượng hằng riêng, khởi tạo lúc biên
  dịch; build với `-Wall -Werror`); đối chứng âm (không `CFRetain`, ghi thường không CAS) vẫn hỏng như kỳ vọng.
- `tools/check_plugin_c_delta.py 75e2e28`: 438 chẩn đoán ở base, 438 ở integration, **0 mới** (đối chứng: một lỗi cố ý được phát
  hiện). Xem giới hạn ở mục 8.
- Revert từng commit riêng trên `c8112a8`: 9 commit revert sạch, mỗi lần 0 FAIL; 5 commit xung đột vì commit sau sửa tiếp cùng file
  — revert theo nhóm phụ thuộc (mục 7.5) đều sạch, 0 FAIL. Revert 5 commit plugin theo thứ tự ngược đưa `plugin/` về giống hệt
  `75e2e28`.
- Các khối lệnh 7.1-7.3 của tài liệu này đã được chạy thử **trên một cây thư mục giả trong cloud** (công cụ macOS giả lập:
  `stat -f` kiểu BSD, `ditto`, `codesign`, `shasum`; `sudo` và `chflags` chỉ mô phỏng), không phải trên macOS: sao lưu, từ chối sao lưu
  lần hai, cài thử, khôi phục; và dừng đúng khi Terminal mới mất biến `ST`, bản dựng biến mất trước khi đổi chỗ, backup hoặc bảng kê
  gốc bị sửa, thiếu binary biến thể, thiếu `/Library/NullMoth` — bản đang cài không đổi trong mọi ca dừng.
- Tái chạy: `python3 -I tools/run_tool_tests.py . --json kq.json`; delta: `python3 -I tools/check_plugin_c_delta.py 75e2e28 --vulkan-headers <Vulkan-Headers>/include` (header Khronos chính thức).

## 5. Build trên macOS (chưa thực hiện; không tuyên bố artifact đã build thành công)

Chuẩn bị: Xcode 16 (README), header Vulkan (`include/` của Mesa `17ca6174` như bản release, hoặc Khronos Vulkan-Headers;
`build-info.txt` ghi `VK_HEADER_VERSION` đã dùng). Script chỉ ghi vào thư mục output, không cài, không ký, không sudo.

```bash
git clone https://github.com/trancongtu550/nvidia-macos-driver.git && cd nvidia-macos-driver
git checkout claude/vigilant-mayer-ptq05r-integration
VK=~/src/mesa-17ca6174/include          # hoặc ~/Vulkan-Headers/include
# A1: baseline đúng mã v2.5.3, mức tối ưu của bản release
bash tools/nm_build_plugin.sh build 75e2e28a55fef0e3c3001235c6d28c8cfae0019a ~/nm-A1-base-O1 --vk-include "$VK" --twice
# B: bản tùy chỉnh (HEAD của branch tích hợp), -O1
bash tools/nm_build_plugin.sh build HEAD ~/nm-B-custom-O1 --vk-include "$VK" --twice
# C: bản tùy chỉnh, -O2 (chỉ đổi mức tối ưu; assert giữ nguyên)
bash tools/nm_build_plugin.sh build HEAD ~/nm-C-custom-O2 --vk-include "$VK" --opt O2
# đối chiếu chỉ đọc với bản đang cài (NVK và translator v2.5.3 giữ nguyên)
for d in ~/nm-A1-base-O1 ~/nm-B-custom-O1 ~/nm-C-custom-O2; do bash tools/nm_build_plugin.sh check-installed "$d/NVMTLDriver" 75e2e28; echo "rc=$?"; done
```

Mỗi build phải kết thúc bằng các dòng `ok` của bước kiểm artifact và `built (not installed, not signed)`; `check-installed`
phải `rc=0`. Các thay đổi plugin không đổi entry point hay bản ghi dùng chung với NVK/translator
(`tools/test_plugin_abi_contract.py`), nên dùng chung NVK/translator v2.5.3 đang cài.

## 6. Quy trình benchmark A/B thống nhất (người dùng tự làm; bước cài cần duyệt riêng)

**Biến thể:** A0 = plugin gốc đang cài; A1 = baseline tự build; B = tùy chỉnh `-O1`; C = tùy chỉnh `-O2`. So sánh: B với A1
(tác động của mã), C với B (tác động của `-O2`), A1 với A0 (khác biệt do toolchain). Thứ tự chạy A0 → A1 → B → C → A0 (lần A0
cuối để phát hiện trôi điều kiện). Cài/khôi phục từng biến thể theo mục 7.

**Điều kiện cố định:** 4K 144 Hz, cùng mode/HiDPI; không boot-arg debug (`status` không có dòng `CHÚ Ý`); cùng app và cửa sổ
mở; Spotlight không đang index; khởi động lại máy trước mỗi biến thể, chờ 2 phút sau đăng nhập.

**Mỗi biến thể:**
1. `bash tools/nm_readonly_diagnostics.sh status` (một lần).
2. Với mỗi kịch bản `nen-dung-yen`, `keo-cua-so`, `cuon`, lặp 3 lần:
   ```bash
   ps -o cputime= -p "$(pgrep -x WindowServer)"     # trước
   bash tools/nm_readonly_diagnostics.sh measure <kịch-bản>-<biến-thể>-<lần>
   ps -o cputime= -p "$(pgrep -x WindowServer)"     # sau: hiệu = CPU WindowServer trong ~47 s của lượt
   ```
   Thao tác liên tục từ tiếng bíp `>>> BẮT ĐẦU` tới `<<< DỪNG` (kéo một cửa sổ Finder/Safari; cuộn một trang dài trong Safari).

**Số liệu so sánh (trung vị của 3 lần):**
- **flip/s = delta `nvaccel_iop_flips` / T.** Bộ đếm này đã gồm cả flip bất đồng bộ: nhánh async thành công tăng
  `nvaccel_iop_flips` và `nvaccel_iop_async_flips` trong cùng một câu lệnh (`kexts/NVRM/accel/nvrm-accel.cpp:1955`), nhánh đồng
  bộ chỉ tăng `nvaccel_iop_flips` (2085). `nvaccel_iop_async_flips` là **tập con**: chỉ dùng để biết tỉ lệ flip đi đường async,
  **không cộng** vào flip/s (cộng sẽ đếm mỗi flip async hai lần). `tools/test_flip_counter_docs.py` chặn công thức cộng tái xuất
  hiện trong tài liệu/script và báo khi quan hệ tập con trong mã nguồn thay đổi.
- `nvaccel_iop_late`, `nvaccel_iop_async_drop`, `nvrmfb_flip_latch_late`/`_timeouts`, thời gian trung bình mỗi pure flip,
  `nvrmfb_vram_grants`, `nvaccel_surface_gpu_waits`, CPU WindowServer, dòng log `present stats`.

Một biến thể chỉ được coi là tốt hơn khi trung vị cải thiện vượt độ dao động giữa 3 lần và không làm xấu chỉ số khác; chênh
lệch nhỏ hơn độ dao động = **không kết luận**.

Thí nghiệm cấu hình tùy chọn (cần duyệt; đảo ngược được): `NVMTL_ASYNC_TEX_UPLOAD=1` trong `nvrm610.conf` (upstream, chỉ
`replaceRegion`), `debug.nvrmfb_flip_latch=2` (sysctl, mất khi khởi động lại). Chạy riêng, cùng quy trình.

## 7. Cài thử và rollback (chưa thực hiện; người dùng tự chạy, cần sudo và duyệt riêng)

Nguyên tắc: (1) sao lưu bản gốc **một lần**, vào thư mục mới, và **xác minh đầy đủ** trước mọi thay đổi; (2) không bao giờ ghi
đè hay xóa bản sao lưu gốc; (3) không xóa bản đang cài: nó chỉ được **đổi tên sang chỗ khác** sau khi bản thay thế đã được
dựng và kiểm tra đầy đủ; (4) mọi bản trung gian nằm trong `/Library/NullMoth/nm-stage/<thời điểm>/`, cùng volume với
`/Library/GPUBundles` (đổi tên là tức thời); (5) bất kỳ bước kiểm nào không in đúng dòng mong đợi: **dừng**.

**7.0 Định nghĩa dùng chung** (dán vào Terminal trước mỗi bước). Bảng kê ghi mọi mục của bundle: đường dẫn tương đối, quyền,
uid:gid dạng số (để so được cả trong Recovery), đích liên kết, rồi sha256 của mọi file.
```bash
SRC=/Library/GPUBundles/NVMTLDriver.bundle
nm_manifest() { ( cd "$1" || exit 1
    sudo find . -exec stat -f '%N|%Sp|%u:%g|%Y' {} + | LC_ALL=C sort
    sudo find . -type f -exec shasum -a 256 {} + | LC_ALL=C sort -k2 ); }
# khác biệt giữa hai bảng kê, bỏ qua binary plugin và chữ ký (thứ duy nhất một lần cài thử được phép đổi)
nm_other_diffs() { diff <(nm_manifest "$1") <(nm_manifest "$2") | grep '^[<>]' | grep -v -e '/Contents/MacOS/NVMTLDriver' -e '/Contents/_CodeSignature'; }
```

**7.1 Sao lưu bản gốc A0 — một lần, trước mọi thay đổi.** Cả khối chạy trong một subshell `set -e`: một kiểm tra hỏng là dừng,
các lệnh sau không chạy. (Mỗi kiểm tra nằm trên một dòng riêng: trong `a && b`, `set -e` không dừng khi `a` hỏng.)
```bash
( set -e
  [ ! -e ~/nm-backup/A0-PATH ] || { echo "Đã có backup gốc: $(cat ~/nm-backup/A0-PATH) — không làm lại bước này"; exit 1; }
  B=~/nm-backup/A0-$(date +%Y%m%d-%H%M%S)
  mkdir -p ~/nm-backup; mkdir "$B"                       # mkdir không -p: thư mục phải mới, không dùng lại cái cũ
  nm_manifest "$SRC" > "$B/manifest.txt"
  sudo ditto "$SRC" "$B/NVMTLDriver.bundle"
  nm_manifest "$B/NVMTLDriver.bundle" | diff "$B/manifest.txt" -          # khác biệt nào cũng dừng
  r1=$(codesign --verify --strict "$SRC" >/dev/null 2>&1; echo $?)
  r2=$(codesign --verify --strict "$B/NVMTLDriver.bundle" >/dev/null 2>&1; echo $?)
  [ "$r1" = "$r2" ]                                                       # chữ ký của backup như bản cài
  { codesign -dv "$SRC" 2>&1 || true; } | grep -E '^(Signature|TeamIdentifier)|not signed' > "$B/signature.txt" || true
  shasum -a 256 "$B/manifest.txt" > "$B/manifest.txt.sha256"
  echo "$B" > ~/nm-backup/A0-PATH
  sudo chflags -R uchg "$B" ~/nm-backup/A0-PATH          # khóa: cp/ditto/mv/rm thông thường không ghi đè hay xóa được
  echo "BACKUP ĐẦY ĐỦ: $B"; cat "$B/signature.txt" )
```
Chỉ đi tiếp khi thấy `BACKUP ĐẦY ĐỦ`. Ghi lại đường dẫn này ra giấy: cần cho Recovery.

**7.2 Cài thử một biến thể** (`V` = thư mục output của biến thể ở mục 5). Dựng bản thay thế từ bản đang cài, chỉ thay binary:
```bash
V=~/nm-B-custom-O1; ST=/Library/NullMoth/nm-stage/$(date +%Y%m%d-%H%M%S)
( set -e
  B=$(cat ~/nm-backup/A0-PATH); [ -d "$B/NVMTLDriver.bundle" ]           # chưa có backup gốc: dừng
  [ -d /Library/NullMoth ]
  [ -f "$V/NVMTLDriver" ]
  case "$(cat "$B/signature.txt")" in
    *adhoc*) MODE=adhoc ;; *"not signed"*) MODE=unsigned ;;
    *) echo "STOP: bundle gốc ký bằng danh tính khác ad hoc; thay binary sẽ làm hỏng chữ ký"; exit 1 ;; esac
  sudo mkdir -p "$ST"; [ ! -e "$ST/new.bundle" ]
  sudo ditto "$SRC" "$ST/new.bundle"
  sudo cp "$V/NVMTLDriver" "$ST/new.bundle/Contents/MacOS/NVMTLDriver"
  if [ "$MODE" = adhoc ]; then sudo codesign --force --sign - "$ST/new.bundle"; codesign --verify --strict "$ST/new.bundle"; fi
  [ -z "$(nm_other_diffs "$SRC" "$ST/new.bundle")" ]                      # chỉ khác binary và chữ ký
  echo "BẢN MỚI ĐÃ KIỂM ($MODE): $ST/new.bundle" )
```
Chỉ khi thấy `BẢN MỚI ĐÃ KIỂM`: đóng bớt ứng dụng rồi đổi chỗ, **trong cùng cửa sổ Terminal** (khối này dùng `ST` và `SRC` của
các khối trên và dừng nếu chúng rỗng hoặc bản mới không có). Bản đang cài được **đổi tên** thành `$ST/prev.bundle`, không bị
xóa; nếu bước thứ hai hỏng thì nó được trả về chỗ cũ:
```bash
( set -e
  : "${SRC:?SRC rỗng: dán khối 7.0}" "${ST:?ST rỗng: chạy khối dựng ở trên trong cùng cửa sổ Terminal}"
  [ -d "$ST/new.bundle" ]
  [ ! -e "$ST/prev.bundle" ]
  [ -d "$SRC" ]
  sudo mv "$SRC" "$ST/prev.bundle"
  sudo mv "$ST/new.bundle" "$SRC" || { sudo mv "$ST/prev.bundle" "$SRC"; echo "STOP: đã trả lại bản cũ"; exit 1; }
  [ -z "$(nm_other_diffs "$ST/prev.bundle" "$SRC")" ]
  echo "ĐÃ CÀI THỬ (bản cũ giữ ở $ST/prev.bundle)" )
```
Rồi khởi động lại máy. `$ST/prev.bundle` và backup gốc giữ nguyên.

**7.3 Khôi phục bản gốc A0** (khi máy còn đăng nhập được). Dựng và kiểm bản khôi phục **trước**, bản đang cài vẫn ở nguyên chỗ:
```bash
ST=/Library/NullMoth/nm-stage/$(date +%Y%m%d-%H%M%S)
( set -e
  B=$(cat ~/nm-backup/A0-PATH)
  shasum -a 256 -c "$B/manifest.txt.sha256"                              # bảng kê gốc chưa bị sửa
  nm_manifest "$B/NVMTLDriver.bundle" | diff "$B/manifest.txt" -          # backup còn nguyên
  sudo mkdir -p "$ST"; [ ! -e "$ST/restore.bundle" ]
  sudo ditto "$B/NVMTLDriver.bundle" "$ST/restore.bundle"               # chỉ đọc từ backup
  sudo chflags -R nouchg "$ST/restore.bundle"                           # bản chép không mang cờ khóa của backup
  nm_manifest "$ST/restore.bundle" | diff "$B/manifest.txt" -            # bản khôi phục giống hệt bản gốc
  echo "BẢN KHÔI PHỤC ĐÃ KIỂM: $ST/restore.bundle" )
```
Chỉ khi thấy `BẢN KHÔI PHỤC ĐÃ KIỂM`: đổi chỗ **trong cùng cửa sổ Terminal** (bản đang cài được đổi tên thành
`$ST/replaced.bundle`, không bị xóa), rồi kiểm lại:
```bash
( set -e
  : "${SRC:?SRC rỗng: dán khối 7.0}" "${ST:?ST rỗng: chạy khối dựng ở trên trong cùng cửa sổ Terminal}"
  [ -d "$ST/restore.bundle" ]
  [ ! -e "$ST/replaced.bundle" ]
  [ -d "$SRC" ]
  sudo mv "$SRC" "$ST/replaced.bundle"
  sudo mv "$ST/restore.bundle" "$SRC" || { sudo mv "$ST/replaced.bundle" "$SRC"; echo "STOP: đã trả lại bản trước đó"; exit 1; }
  nm_manifest "$SRC" | diff "$(cat ~/nm-backup/A0-PATH)/manifest.txt" -
  echo "ĐÃ KHÔI PHỤC ĐÚNG BẢN GỐC (bản trước đó giữ ở $ST/replaced.bundle)" )
```
Rồi khởi động lại. Thư mục `/Library/NullMoth/nm-stage/` chỉ xóa (thủ công) khi máy đã chạy ổn với bản gốc; **không bao giờ**
xóa hay sửa `~/nm-backup/A0-*`.

**7.4 Khôi phục từ macOS Recovery** (khi không vào được desktop; các lệnh chưa được thử trên Recovery của macOS Tahoe)
1. Khởi động vào Recovery (mục Recovery của macOS trong boot picker), mở Utilities → Terminal (đã là root, không cần `sudo`).
2. Xác định đúng volume, **không giả định tên**:
   ```bash
   diskutil apfs list          # các volume, vai trò (System/Data), trạng thái FileVault (khóa hay không)
   ls /Volumes
   ```
   `/Library` và thư mục người dùng nằm trên volume **Data** của bản macOS đang dùng. Nếu volume đó đang khóa (FileVault): Disk
   Utility → chọn volume Data → Mount và nhập mật khẩu (hoặc `diskutil apfs unlockVolume <định danh>`).
3. Tìm bản đang cài và backup trên mọi volume đã mount:
   ```bash
   ls -d /Volumes/*/Library/GPUBundles/NVMTLDriver.bundle
   ls -d /Volumes/*/Users/*/nm-backup/A0-*
   cat /Volumes/*/Users/*/nm-backup/A0-PATH     # đường dẫn ghi lúc sao lưu, dạng /Users/<tên>/nm-backup/A0-<thời điểm>
   ```
   Chọn volume `V` sao cho: bundle đang cài và backup **cùng nằm trên `V`**; thư mục backup trùng với đường dẫn trong `A0-PATH`
   (thêm tiền tố `/Volumes/<tên V>`); `diskutil info "/Volumes/<tên V>"` khớp volume Data của ổ hệ thống (tên, dung lượng). Nếu có
   nhiều hơn một ứng viên hoặc không chắc chắn: **dừng**, không sửa gì.
4. Kiểm tra công cụ: `command -v ditto diff shasum find stat cmp`. Kiểm backup và dựng bản khôi phục:
   ```bash
   V="/Volumes/<tên V>"; B="$V/Users/<tên>/nm-backup/A0-<thời điểm>"; SRC="$V/Library/GPUBundles/NVMTLDriver.bundle"
   ST="$V/Library/NullMoth/nm-stage/recovery-$(date +%Y%m%d-%H%M%S)"; mkdir -p "$ST"
   ditto "$B/NVMTLDriver.bundle" "$ST/restore.bundle" && chflags -R nouchg "$ST/restore.bundle"
   ```
   Nếu có `shasum`, so bảng kê (bản không dùng `sudo`; uid:gid dạng số nên so được trong Recovery):
   ```bash
   nm_manifest() { ( cd "$1" || exit 1; find . -exec stat -f '%N|%Sp|%u:%g|%Y' {} + | LC_ALL=C sort
                     find . -type f -exec shasum -a 256 {} + | LC_ALL=C sort -k2 ); }
   nm_manifest "$ST/restore.bundle" | diff "$B/manifest.txt" - && echo "BẢN KHÔI PHỤC ĐÃ KIỂM"
   ``` Nếu thiếu `shasum`: ít nhất `cmp "$B/NVMTLDriver.bundle/Contents/MacOS/NVMTLDriver" "$ST/restore.bundle/Contents/MacOS/NVMTLDriver"`
   và `diff <(cd "$B/NVMTLDriver.bundle" && find . | sort) <(cd "$ST/restore.bundle" && find . | sort)` đều không in gì.
5. Chỉ khi bước 4 đạt (thấy `BẢN KHÔI PHỤC ĐÃ KIỂM`, hoặc `cmp`/`diff` không in gì): đổi chỗ, bản đang cài được đổi tên chứ không bị xóa:
   ```bash
   ( set -e; : "${SRC:?}" "${ST:?}"; [ -d "$ST/restore.bundle" ]; [ ! -e "$ST/replaced.bundle" ]
     mv "$SRC" "$ST/replaced.bundle"; mv "$ST/restore.bundle" "$SRC" || { mv "$ST/replaced.bundle" "$SRC"; exit 1; }
     echo "ĐÃ ĐỔI CHỖ" )
   ```
   Khởi động lại. Chỉ binary plugin (userland) từng bị thay; kext, EFI, NVK, translator không đổi.

**7.5 Mã nguồn:** revert từng commit trên branch tích hợp (không sửa lịch sử):
- Độc lập (revert riêng được): `63afab4`, `218533a`, `d895e59`, `c8112a8`, `2004c9c`, `ba973b2`, `28525ad`, `b565d6c`, `0fe017d`.
- Theo nhóm, đúng thứ tự: `git revert d895e59 024bfdc` (vertex trước index); `git revert b565d6c 226f0a1`;
  `git revert c8112a8 28525ad ba26f85`; `git revert 0fe017d 7f6ece4 af71166`.
- Đưa `plugin/` về đúng `75e2e28`: `git revert 63afab4 218533a d895e59 024bfdc b565d6c 226f0a1` (đã kiểm: `git diff 75e2e28 -- plugin/` rỗng).
- Các commit sau `9cc2138` chỉ sửa test và tài liệu.

## 8. Giới hạn

- **Test mô hình không chứng minh hành vi của NVK thật.** `tools/test_bind_cache.py` chỉ chứng minh: theo mô hình trạng thái binding
  của Vulkan (spec), mỗi draw vẫn thấy đúng binding đã yêu cầu. Nó không kiểm NVK/Mesa thật; đặc biệt giả định rằng thao tác nội bộ
  của NVK (meta) khôi phục binding — giả định mà cache pipeline của upstream cũng dựa vào — chưa được kiểm vì không có nguồn Mesa
  trong cloud. Chỉ chạy thật trên máy (và Vulkan validation nếu có) mới xác nhận được.
- **`tools/check_plugin_c_delta.py` không thay thế build toàn plugin.** Nó chỉ so chẩn đoán clang của riêng `nvmtl_vk.c` (với header
  macOS rỗng) giữa hai phiên bản; không biên dịch phần Objective-C, không link, không kiểm khai báo thật của macOS. Build thật là
  `tools/nm_build_plugin.sh` trên macOS — chưa chạy.
- Các test tách hàm (`test_vram_tag_key`, `test_release_debug_polls`, `test_subwho_census`) biên dịch một bản trích của hàm với
  stub, không phải plugin; CoreFoundation trong `test_vram_tag_key` là bản giả.
- Lợi ích của mọi tối ưu chưa được đo; không có số FPS hay frame time nào.
