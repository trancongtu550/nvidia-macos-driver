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
| integration `c8112a8` | 77 | 58 | 0 | 0 | 18 | 1 |

- 70/70 test có sẵn giữ nguyên trạng thái; 7 test mới đều PASS: `test_bind_cache`, `test_vram_tag_key`, `test_release_debug_polls`, `test_subwho_census`, `test_nm_build_plugin`, `test_plugin_abi_contract`, `test_nm_readonly_diagnostics`.
- 18 MISSING: cần `xcrun`/macOS SDK (11), Foundation/Metal (3), `ditto` (1), header macOS (1), bản build translator (1), một commit không có trong lịch sử công khai (1). DEPFAIL `test_primary_gpu_install`: mọi case hỏng vì thiếu `ditto`.
- `tools/check_plugin_c_delta.py 75e2e28`: 438 chẩn đoán ở base, 438 ở integration, **0 mới** (đối chứng: một lỗi cố ý được phát hiện).
- Revert từng commit riêng trên HEAD: 9 commit revert sạch, mỗi lần 0 FAIL; 5 commit xung đột vì commit sau sửa tiếp cùng file — revert theo nhóm phụ thuộc (mục 7) đều sạch, 0 FAIL. Revert 5 commit plugin theo thứ tự ngược đưa `plugin/` về giống hệt `75e2e28` (`git diff --stat` rỗng).
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

**Biến thể:** A0 = plugin gốc đang cài (bản sao lưu); A1 = baseline tự build; B = tùy chỉnh `-O1`; C = tùy chỉnh `-O2`.
So sánh: B so với A1 (tác động của mã), C so với B (tác động của `-O2`), A1 so với A0 (khác biệt do toolchain). Thứ tự chạy
A0 → A1 → B → C → A0 (lần A0 cuối để phát hiện trôi điều kiện).

**Điều kiện cố định:** 4K 144 Hz, cùng mode/HiDPI; không boot-arg debug (`status` không có dòng `CHÚ Ý`); cùng app và cửa sổ
mở; Spotlight không đang index; khởi động lại máy trước mỗi biến thể, chờ 2 phút sau đăng nhập.

**Mỗi biến thể:**
1. Cài thử (chỉ khi đã duyệt; cần sudo):
   ```bash
   codesign -dv /Library/GPUBundles/NVMTLDriver.bundle 2>&1 | grep -E '^(Signature|TeamIdentifier|Format)'   # chỉ đọc
   sudo ditto /Library/GPUBundles/NVMTLDriver.bundle ~/nm-backup/NVMTLDriver.bundle.orig     # chỉ lần đầu: bản gốc A0
   sudo cp <thư mục biến thể>/NVMTLDriver /Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS/NVMTLDriver
   sudo codesign --force --sign - /Library/GPUBundles/NVMTLDriver.bundle   # CHỈ khi dòng đầu cho thấy Signature=adhoc; nếu không, dừng
   ```
   rồi khởi động lại máy. A0 = chép lại bản sao lưu (mục 7).
2. `bash tools/nm_readonly_diagnostics.sh status` (một lần).
3. Với mỗi kịch bản `nen-dung-yen`, `keo-cua-so`, `cuon`, lặp 3 lần:
   ```bash
   ps -o cputime= -p "$(pgrep -x WindowServer)"     # trước
   bash tools/nm_readonly_diagnostics.sh measure <kịch-bản>-<biến-thể>-<lần>
   ps -o cputime= -p "$(pgrep -x WindowServer)"     # sau: hiệu = CPU WindowServer trong ~47 s của lượt
   ```
   Thao tác liên tục từ tiếng bíp `>>> BẮT ĐẦU` tới `<<< DỪNG` (kéo một cửa sổ Finder/Safari; cuộn một trang dài trong Safari).

**Số liệu so sánh (trung vị của 3 lần):** flip/s (`nvaccel_iop_flips` + `nvaccel_iop_async_flips`), `nvaccel_iop_late`,
`nvaccel_iop_async_drop`, `nvrmfb_flip_latch_late`/`_timeouts`, thời gian trung bình mỗi pure flip, `nvrmfb_vram_grants`,
`nvaccel_surface_gpu_waits`, CPU WindowServer, dòng log `present stats`. Một biến thể chỉ được coi là tốt hơn khi trung vị cải
thiện vượt độ dao động giữa 3 lần và không làm xấu chỉ số khác; chênh lệch nhỏ hơn độ dao động = **không kết luận**.

Thí nghiệm cấu hình tùy chọn (cần duyệt; đảo ngược được): `NVMTL_ASYNC_TEX_UPLOAD=1` trong `nvrm610.conf` (upstream, chỉ
`replaceRegion`), `debug.nvrmfb_flip_latch=2` (sysctl, mất khi khởi động lại). Chạy riêng, cùng quy trình.

## 7. Rollback

**Bản cài thử về gốc** (cần sudo; rồi khởi động lại máy):
```bash
sudo rm -rf /Library/GPUBundles/NVMTLDriver.bundle
sudo ditto ~/nm-backup/NVMTLDriver.bundle.orig /Library/GPUBundles/NVMTLDriver.bundle
```
Nếu màn hình không lên sau khi cài thử: vào macOS Recovery → Terminal, chép bản sao lưu về
`/Volumes/<ổ hệ thống>/Library/GPUBundles/NVMTLDriver.bundle` (cùng lệnh, đổi đường dẫn), khởi động lại. Chỉ binary plugin
(userland) bị thay; kext, EFI, NVK, translator không đổi.

**Mã nguồn:** revert từng commit trên branch tích hợp (không sửa lịch sử):
- Độc lập (revert riêng được): `63afab4`, `218533a`, `d895e59`, `c8112a8`, `2004c9c`, `ba973b2`, `28525ad`, `b565d6c`, `0fe017d`.
- Theo nhóm, đúng thứ tự: `git revert d895e59 024bfdc` (vertex trước index); `git revert b565d6c 226f0a1`;
  `git revert c8112a8 28525ad ba26f85`; `git revert 0fe017d 7f6ece4 af71166`.
- Đưa `plugin/` về đúng `75e2e28`: `git revert 63afab4 218533a d895e59 024bfdc b565d6c 226f0a1` (đã kiểm: `git diff 75e2e28 -- plugin/` rỗng).
