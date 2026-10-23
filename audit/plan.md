# Kế hoạch triển khai — sau audit lượt 1

Base: `75e2e28` (v2.5.3 = upstream main). Phát hiện chi tiết: `findings.md`. Phạm vi đã đọc: `README.md` +
`inventory.tsv` trong thư mục này.

## 1. Quy định áp dụng

| Nguồn | Nội dung | Áp dụng cho việc này |
|---|---|---|
| `AGENTS.md`, `CONTRIBUTING.md` | PR/issue/review comment do AI viết bị đóng không review; người gửi phải tự viết, hiểu từng dòng, test trên phần cứng thật; thay đổi kext phải boot thử trên card thật | Chỉ ràng buộc việc **gửi lên upstream**. Nghiên cứu, patch và test trong fork cá nhân không bị cấm, nhưng mọi thứ ở đây **không được gửi upstream dưới dạng PR/issue/comment do AI soạn**. Muốn đóng góp, người dùng phải tự viết lại và tự test |
| `LICENSE` (PolyForm Noncommercial 1.0.0) cho `plugin/`, `kexts/`, `build/`, `package/` | Cho phép sửa đổi, phân phối phi thương mại; phải giữ điều khoản và dòng `Required Notice` | Fork cá nhân, phi thương mại: được phép. Không sửa file license |
| `translator/` LGPL-3.0+, `nvk/` MIT (Mesa), firmware GSP theo license NVIDIA | — | Không đụng tới trong kế hoạch này |

## 2. Tối ưu upstream đã có — không làm lại

| Hạng mục | Vị trí | Ghi chú |
|---|---|---|
| Flip zero-copy tự bật sau boot (có điều kiện BAR1 / không có GPU khác) | `NVRM.cpp:817-842` | |
| Swap bất đồng bộ trên thread call, giữ frame mới nhất | `nvrm-accel.cpp:1938-2029` | |
| WindowServer không còn tự chờ composite; việc chờ chuyển xuống kernel (#196) | `nvrm-accel.cpp:1326-1390`, `NVMTLObjects.m:5048-5055` | |
| Chờ flip bằng sự kiện, đọc lại mỗi 250 µs; giới hạn 1,25 chu kỳ | `nvrm-fb.cpp:1531-1560, 1626-1647` | |
| Kiểm tra flip ở present kế tiếp (opt-in) (#300) | `nvrm-fb.cpp:1565-1569, 1721` | `debug.nvrmfb_flip_latch=2` |
| Cache surface flip có epoch; cache IOSurface->resource | `nvrm-fb.cpp:3550-3597`, `nvrm-accel.cpp:1861-1898` | |
| Flip lean (chỉ đổi surface); cursor qua kênh immediate, luồng riêng | `nvrm-fb.cpp:3613-3627, 2045-2097` | |
| Thống kê present trong log | `nvrm-fb.cpp:1573-1621` | |
| Giữ VRAM khi family dealloc (#245); upload bằng copy engine từ trang của chính surface (#296) | `nvrm-accel.cpp:1000-1028`; `nvmtl_vk.c:6227-6270` | |
| Page-off qua staging liền khối | `nvrm-accel.cpp:1730-1820` | |
| IOSurface dùng chung VRAM giữa các tiến trình ("item 7") | `NVMTLDevice.m:921-955`, `nvmtl_vk.c:1938-1970` | |
| Commit bất đồng bộ + submit-ahead (tối đa 16 part), EVFOLD, bỏ part rỗng | `NVMTLEventSync.m:288-300, 540-610` | |
| Prologue trước submit (upload/fill đi kèm submit) | `nvmtl_vk.c:5633-5695` | |
| Event wait cho WindowServer; app opt-in (đã đo) | NVK `nvkmd_nvrm_ctx.c:215-247`; `docs/EVENT-WAIT.md` | |
| spvcache (trim, xóa entry cũ), thư mục Mesa cache cho WindowServer, memo key (#294), #334 | `NVMTLLibraryLoad.m:152-420, 840-894`; `nvmtl_vk.c:692-703` | |
| Residency LRU res2 khi thiếu VRAM | `NVMTLObjects.m:313-575` | |
| Log cấp phát chỉ khi verbose (#242) | `nvrm-accel.cpp:44-48` | |

## 3. Patch khả thi và kiểm tra tương ứng

| ID | Thành phần | Thay đổi | Phát hiện | Build được từ repo? | Kiểm tra độc lập phần cứng | Kiểm tra cần máy thật |
|---|---|---|---|---|---|---|
| T1 | plugin + script | Bộ đếm hiệu năng **opt-in** cho bản release (khóa `NVMTL_PERF_SUMMARY=1` trong `nvrm610.conf`): surface-in/out (số lần, byte, tổng/max µs), chờ submit theo nhãn, sync buffer; in một dòng tóm tắt mỗi 10 s khi có hoạt động. Script đọc dòng đó. Mặc định tắt, không đổi hành vi | F3, F8, F9, F13 | Có (Xcode + Vulkan-Headers, lệnh trong `build/build_plugin_release.sh`) | Test C/Python: bộ tích lũy (cộng dồn, max, tràn số, đa luồng), parse khóa, mặc định tắt; chạy lại toàn bộ `tools/test_*.py` | Build plugin, so hash, cài (cần duyệt riêng), bật khóa, đo 3 lượt |
| T2 | script | Đọc thêm các counter **đã có**: `nvrmfb_vram_grants/_bytes/releases`, `nvaccel_vm_alloc/_parked/_unparked/_refused`, `nvaccel_res_new/_free`, `nvaccel_map_commit`, `nvrm_isr_count`, `nvrm_evt_waits`; in `nvrm610.conf` đã lọc; cảnh báo boot-arg debug (`nvfbsample`, `nvhud`, `-nvaccelverbose`, `-nvrmnoflip`) | F1, F2, F7 | Không cần build | Mở rộng harness giả lập hiện có | Chạy script |
| T3 | NVRMFB | Xóa VRAM ngoài gate; thêm counter: thời gian chờ/giữ gate, thời gian xóa | F1 | **Không** (F11) | Tách hàm, biên dịch bằng clang++ với stub như `tools/test_boot_raster_modes.py`: thứ tự lock, nhánh lỗi giải phóng bộ nhớ, publish chỉ sau khi xóa | Boot trên 4070 Ti, đo grant + flip |
| T4 | NVAccel | Xuất counter dirty/pageoff đã có + thời gian pageoff; `ALOGV` cho log tạo object | F2, F7 | **Không** (cần cây RM build cho Darwin) | Test Python kiểm khai báo/đăng ký sysctl và log bị giới hạn | Boot thử |
| T5 | NVRMFB | Counter độ trễ IRQ->giao VBL | F4 | **Không** | Helper tách rời | Boot thử |
| T6 | plugin | Khóa cho `nvmtl_subwho_note` | F12 | Có | Harness C đa luồng | Không bắt buộc |
| T7 | plugin (nghiên cứu) | Đưa surface-in thành bất đồng bộ qua prologue | F3 | Có | Fixture Objective-C kiểu `tools/test_submission_copies.py` (cần macOS) | Bắt buộc; rủi ro cao |

Thí nghiệm **không cần build** (mỗi cái cần người dùng đồng ý riêng, đều đảo ngược được):
- E1: `sudo sysctl debug.nvrmfb_flip_latch=2` (mất khi reboot) — A/B với script T2. Liên quan F1.
- E2: `NVRM_EVENT_WAIT=1` trong `/Library/GPUBundles/nvmtl/nvrm610.conf` (sao lưu trước) — A/B CPU và độ mượt. Liên quan F5.

## 4. Dữ liệu phần cứng còn thiếu (theo thứ tự cần)

1. Phiên bản driver đang load trên đĩa và trong bộ nhớ (README của EFI ghi 2.0.0). Mọi đề xuất giả định đang chạy 2.5.3;
   rebuild plugin bắt buộc khớp NVK đã cài.
2. Đường present: `nvrm-flip`, `debug.nvaccel_iop_flip`, `bar1-mb`, danh sách accelerator, delta `nvaccel_iop_flips`
   so với `nvaccel_iop_ok`.
3. Mode thật: tần số (`NVRMFlipWaitUs`), "UI Looks like" (HiDPI scaled hay 1:1), DSC.
4. Delta trong 30 s kéo/cuộn: flip, drop/late, latch timeouts/max, gpu waits/timeouts, **VRAM grants/bytes** (T2).
5. Sau T1: số lần và tổng thời gian surface-in/out trong WindowServer khi cuộn Safari / app AppKit.
6. A/B E1 (và E2 nếu muốn) với cùng giao thức đo.
7. Nếu có Xcode: `tools/bench_*` (đã có sẵn) chỉ chạy khi người dùng đồng ý build công cụ.

## 5. Công việc triển khai đầu tiên đề xuất (chờ duyệt): T2 + T1

**Mục tiêu:** có số đo để quyết định giữa F1 (gate/xóa VRAM), F2 (đường copy) và F3 (upload đồng bộ), mà không đổi hành vi
driver khi tính năng đo tắt.

**Phạm vi file:**
- `tools/nm_readonly_diagnostics.sh`: thêm counter có sẵn (T2), đọc dòng tóm tắt T1 từ log.
- `plugin/nvmtl_perf_summary.h` (mới): bộ tích lũy lock-free + định dạng dòng tóm tắt, không phụ thuộc Metal/Vulkan
  (để test được trên Linux).
- `plugin/nvmtl_vk.c`, `plugin/NVMTLObjects.m`: gọi bộ tích lũy tại `nvmtl_vk_image_write_host`, `nvmtl_vk_image_write`,
  `nvmtl_vk_image_read`, `nvmtl_vk_submit_finish`, `nvmtlSurfaceIn`, `nvmtlSurfaceOutDirtied`. Chỉ ghi số khi khóa bật.
- `tools/test_perf_summary.py` + `tools/test_perf_summary.c` (mới).

**Không làm:** không đổi đồng bộ, fence, timeout, xóa bộ nhớ, đường copy; không đụng kext; không cài; không merge; không
gửi upstream.

**Tiêu chí hoàn thành trong cloud:** test mới pass; toàn bộ test hiện có giữ kết quả 48/70 như baseline; `bash -n` script; test
giả lập script pass. **Không** tuyên bố tối ưu được gì.

**Bước trên máy thật (người dùng tự làm, mỗi bước cần duyệt):** build plugin (Xcode), sao lưu
`/Library/GPUBundles/NVMTLDriver.bundle`, thay binary, bật khóa trong `nvrm610.conf`, khởi động lại, chạy script, gửi kết
quả. Hoàn tác: chép lại bản sao lưu, xóa khóa.

## 6. Môi trường cloud (đã kiểm thực tế)

| Hạng mục | Kết quả |
|---|---|
| Công cụ | Linux x86_64, Python 3.13, clang/gcc (Linux), bash 5.2, mawk, cargo; **không** có `xcrun`, macOS SDK, Metal, Foundation, `ditto` |
| Test repo | `tools/test_*.py`: 48/70 pass; 22 không chạy được vì cần công cụ macOS, lịch sử git đầy đủ (clone shallow) hoặc translator đã build |
| Build | Không build được plugin, NVAccel, NVRMFB, NVK cho macOS trong cloud |
| GPU | Không có; mọi kiểm thử hiệu năng phải làm trên máy thật |
