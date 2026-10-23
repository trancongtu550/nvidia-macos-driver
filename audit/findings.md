# Phát hiện audit hiệu năng — NullMoth NVIDIA driver (fork trancongtu550)

- Base audit: `75e2e28a55fef0e3c3001235c6d28c8cfae0019a` = upstream `nullmoth/nvidia-macos-driver` `main` = tag `v2.5.3`
  (kiểm `git ls-remote` ngày 2026-10-23; upstream không có commit mới hơn).
- Máy mục tiêu: i7-14700K, B760M-E D4, RTX 4070 Ti 12 GB (AD104), macOS Tahoe, 4K 144 Hz DisplayPort.
- **Chưa có số đo runtime nào từ máy này.** Mọi "tác động" dưới đây là giả thuyết cho tới khi đo.
- Ký hiệu: **[DK]** = dữ kiện đọc được trong source, có dẫn dòng; **[GT]** = giả thuyết về tác động; **[ĐO]** = cần số
  đo trên máy thật. Đánh giá: Lợi ích (L), Độ chắc chắn (C), Rủi ro (R), Công sức (E): Cao / Trung bình / Thấp.

## Sơ đồ luồng dữ liệu và điểm đồng bộ

```
App Metal ── encode ──► NVMTLDriver.bundle (trong tiến trình app)
   │  bind texture IOSurface ──► nvmtlSurfaceIn: upload ĐỒNG BỘ (submit+chờ) trên g_queue        [S1]
   │  commit ──► worker nối tiếp "nvmtl.execution" (khóa lớp @synchronized)                       [S2]
   │            └► nvmtl_vk_submit_begin/finish: vkQueueSubmit (submit mutex) / vkWaitForFences     [S3]
   │                  └► NVK nvkmd_nvrm: GPFIFO + doorbell; fence = semaphore release (WFI) + IRQ
   │                       chờ: WindowServer = event; app khác = poll/backoff                          [S4]
   │  hoàn tất ──► nvmtlSurfaceOut: (VRAM chia sẻ) escape SURF_DIRTY -> khóa family NVAccel           [S5]
   │                               (ảnh private) readback ĐỒNG BỘ GPU->CPU                             [S6]
   ▼
WindowServer (cũng dùng plugin trên) ── composite ── commitAndWaitUntilSubmitted (chờ "scheduled")
   │  mark GPU pending/ready cho surface (escape -> NVAccel, IOLock 32 slot)                           [S7]
   ▼ swap
NVAccel performTransaction ─┬─ flip zero-copy: thread call async -> chờ composite xong (<=100 ms)       [S8]
                            │     -> NVRMFB flipToMemory GIỮ GATE TOÀN CỤC -> NVKMS applyModeSetConfig
                            │     -> chờ latch <=1,25 chu kỳ (gFlipLatch=1)                             [S9]
                            │  present kế tiếp chờ worker <=1,25 chu kỳ rồi xếp hàng/bỏ frame           [S10]
                            └─ copy: pageoff (CE->staging->CPU) + CPU copy 32-bit volatile sang BAR1     [S11]
NVRMFB (cùng GATE): vramGrant (alloc+map+XÓA BẰNG CPU qua BAR1), vramRelease, cursorApply, gamma, mode    [S12]
vblank IRQ -> thread call -> VBL proc IOFramebuffer (mốc thời gian lấy lúc thread call chạy)              [S13]
Shader: AIR -> spvcache (SHA-256, file) -> translator -> SPIR-V -> NAK (Mesa disk cache) lúc tạo pipeline [S14]
```

## Phát hiện theo ưu tiên

### F1. Một khóa hiển thị toàn cục giữ suốt thời gian chờ flip latch và xóa VRAM bằng CPU — L: Cao(nếu xảy ra) · C(cơ chế): Cao · C(tác động): Thấp · R: Trung bình · E: Trung bình

- [DK] `NVRMDisplayGate` là một `IORecursiveLock` toàn cục duy nhất (`kexts/NVRMFB/fb/nvrm-fb.cpp:42-56`, `startLock`
  1522-1531), dùng chung cho mọi head và mọi thao tác: `flipToMemory` 3533, `vramGrant` 3262, `vramRelease` 3435,
  `cursorApply` 2047, `setCursorImage` 2118, `nvrmSetGamma` 1920, `reflip` 1794, `applyMode` 2340, `switchMode` 2851.
- [DK] `flipToMemory` giữ gate qua `submitConfig` (3629). Với `gFlipLatch == 1` (mặc định, 1565), `submitConfig` chờ
  flip latch tới `flipWaitUs()` = 1,25 chu kỳ (1722-1729) và có thể chờ flip trước (`priorFlipState`, 1672-1683) —
  tất cả trong gate. Ở 144 Hz, 1,25 chu kỳ ≈ 8,68 ms.
- [DK] `vramGrant` trong gate: `allocateMemory`, `mapMemory(KERNEL)`, rồi **xóa toàn bộ vùng cấp phát bằng CPU qua ánh xạ
  BAR1** (`nvu_zero_wide`, 3399) và một lần ghi/đọc kiểm tra. Chú thích tại 119-123 ghi số đo của tác giả: 8 MB ≈ 20 ms
  (RTX 3070 Laptop, `rep stosq`).
- [DK] `NVVidMemory::allocPhysical` gọi `vramGrant` đồng bộ (`kexts/NVRM/accel/nvrm-accel.cpp:947-998`, lời gọi ở 979) trên luồng của
  family/WindowServer.
- [GT] Hệ quả: (a) cursor và mọi cấp phát/giải phóng VRAM của WindowServer phải chờ sau mỗi lần chờ latch của flip;
  (b) một lần cấp phát surface lớn chặn flip trong suốt thời gian xóa. Ngoại suy tuyến tính từ số đo 8 MB/20 ms ra
  33 MB (một surface 3840×2160 BGRA) cho ≈ 80 ms; nhưng băng thông ghi BAR1 trên desktop PCIe 4.0 chưa được đo, nên
  con số này **chỉ là ước lượng**.
- [ĐO] `debug.nvrmfb_vram_grants` / `debug.nvrmfb_vram_grant_bytes` (đã có, `nvrm-fb.cpp:3185-3186`, đăng ký 3247) trong lúc kéo/cuộn:
  nếu delta = 0 thì nhánh (b) không xảy ra trong workload đó. `nvaccel_iop_async_drop`, `nvaccel_iop_late`,
  `nvrmfb_flip_latch_late` cho biết frame bị bỏ/giữ.
- Giảm thiểu đã có sẵn upstream (opt-in): `debug.nvrmfb_flip_latch=2` bỏ phần chờ latch khỏi đường present (#300),
  tức là cũng bỏ nó khỏi gate. Cần `sudo` và quyết định của người dùng.
- Hướng sửa mã: xóa vùng nhớ ngoài gate (cấp phát và map vẫn trong gate, nhả gate, xóa, lấy lại gate để publish), hoặc
  xóa bằng copy engine. **Không bỏ việc xóa** (bảo mật giữa các tiến trình).
- **Chặn bởi build**: repo không có script build NVRMFB.kext (xem F11).

### F2. Đường copy (khi flip zero-copy tắt) tốn băng thông CPU rất lớn — L: Rất cao(nếu đang dùng) · C(cơ chế): Cao · C(máy đang dùng): Chưa biết · R: Thấp(đo) · E: Thấp

- [DK] `performTransaction` (`nvrm-accel.cpp:1126-1220`): nhánh copy chờ GPU (1170), có thể readback qua pageoff
  (`nvAccelSurfCopyReady` 2147-2178 -> `NVResource::pageoff` 1757-1855: copy engine -> staging toàn cục -> CPU
  `writeBytes`), rồi copy từng word 32-bit `volatile` sang BAR1 (1196-1202).
- [DK] Flip zero-copy chỉ bật bởi auto-go khi BAR1 đã được đặt lại và không có accelerator khác NVIDIA
  (`kexts/NVRM/NVRM.cpp:817-842`); `-nvrmnoflip` giữ đường copy. Mặc định trong mã là `gIopFlip = 0`
  (`nvrm-accel.cpp:1295`).
- [GT] Mô hình lý thuyết: 33,2 MB/frame × 144 ≈ 4,8 GB/s cho mỗi chiều copy (giả định: BGRA, pitch = 4×W, copy toàn
  frame mỗi present, mọi present đi đường copy). Chưa tính readback. Không suy ra FPS.
- [ĐO] Script A3d/A3e (`nvrm-flip`, `debug.nvaccel_iop_flip`, `bar1-mb`) và delta `nvaccel_iop_flips`/`nvaccel_iop_ok`.
- Ghi chú HiDPI: chế độ scaled (ví dụ "looks like 2560×1440") cho surface 5120×2880 = 59 MB/frame, rồi head scaler thu nhỏ
  (#273). Kích thước composite tăng 1,78 lần so với 4K gốc. [ĐO] A3a "UI Looks like".

### F3. Upload/readback surface đồng bộ trên queue duy nhất của tiến trình — L: Cao(cuộn nội dung vẽ bằng CPU) · C(cơ chế): Cao · C(tác động): Trung bình · R: Cao(nếu sửa) · E: Cao

- [DK] Mỗi tiến trình có một `VkQueue` (`g_queue`, `plugin/nvmtl_vk.c:121, 1066`). Mọi submit, kể cả upload/readback
  surface, đi qua `pvkQueueSubmit(g_queue)` dưới `nvmtl_submit_mutex` (5764-5793).
- [DK] `nvmtlSurfaceIn` (`plugin/NVMTLObjects.m:1227-1256`) được gọi lúc bind texture (ví dụ 3072, 3106, 4495) trên
  luồng encode. Nó lock IOSurface rồi `nvmtl_vk_image_write_host` (`nvmtl_vk.c:6244-6270`): import trang host,
  submit và **chờ fence** (`nvmtl_vk_submit_wait_at`) toàn bộ surface. Chú thích ghi ~8 ms ở 4K sau #296.
- [DK] `nvmtlSurfaceOutDirtied` (`NVMTLObjects.m:1287-1330`) với ảnh private (không `_vramOn`) readback đồng bộ
  (`nvmtl_vk_image_read`, `nvmtl_vk.c:6316-6347`) trên worker hoàn tất.
- [GT] Vì một channel thực thi theo thứ tự, lần chờ này gồm cả công việc GPU đã xếp hàng trước nó, nên luồng encode của
  WindowServer bị tuần tự hóa với GPU mỗi khi một surface vẽ bằng CPU đổi nội dung. Tần suất phụ thuộc ứng dụng.
- [ĐO] Bản release không xuất số liệu nào của đường này (nvlog chỉ ghi lỗi, xem F13). Cần instrumentation (đề xuất T1).
- [DK] Upstream đã có cơ chế "pre-submit prologue" (`nvmtl_vk_pre_copy`/`pre_hold`, `nvmtl_vk.c:5649-5695`) để upload
  đi kèm submit thay vì submit riêng. Đây là hướng tiềm năng để đưa surface-in thành bất đồng bộ, nhưng cần chứng minh
  ngữ nghĩa lock IOSurface trước khi thử.

### F4. Mốc thời gian VBL lấy ở thread call, không phải lúc ngắt — L: Trung bình · C(cơ chế): Cao · C(tác động): Thấp · R: Trung bình · E: Thấp-Trung bình

- [DK] `hwVblIntr` ghi `fHwVblLast` rồi `scheduleCall` (`nvrm-fb.cpp:2241-2248`); `hwVblDeliver` gọi `fVbl.proc` sau
  đó (2250-2257). IOFramebuffer đóng dấu thời gian lúc proc chạy. Timer dự phòng `vblFire` vẫn được lên lịch mỗi chu kỳ
  ngay cả khi vblank phần cứng sống (2277-2287); nó không giao VBL hai lần nhưng tạo thêm wakeup.
- [GT] Độ trễ thread call làm mốc vsync của WindowServer dao động, ảnh hưởng nhịp frame.
- [ĐO] Cần counter độ trễ IRQ->giao (kernel, chặn bởi build).

### F5. Chờ fence của ứng dụng là polling/backoff — L: Thấp-Trung bình · C: Cao · R: Thấp · E: Thấp (cấu hình)

- [DK] `nvkmd_nvrm_wait_block` (patch NVK, `nvkmd_nvrm_ctx.c` 215-247): event wait mặc định chỉ cho WindowServer; tiến
  trình khác dùng `nvkmd_nvrm_wait_backoff` (179-190): pause dưới 50 µs, `sched_yield` dưới 1 ms, `usleep(50)` dưới
  20 ms, sau đó `usleep(200)`. Context chỉ có copy engine luôn poll (208).
- [DK] Upstream đã đo và để opt-in (`docs/EVENT-WAIT.md`): ít CPU hơn, độ trễ thay đổi theo workload. Không làm lại.
- Thí nghiệm (cần đồng ý): `NVRM_EVENT_WAIT=1` trong `/Library/GPUBundles/nvmtl/nvrm610.conf`, đảo ngược được.

### F6. `nvkms_yield()` = `IOSleep(1)` trong các nhánh chờ chậm của NVKMS — L: Thấp-Trung bình · C(cơ chế): Cao · C(tần suất): Thấp · R: Trung bình · E: Thấp

- [DK] `kexts/NVRM/os-nvkms-xnu.cpp:314`. Trong NVKMS 615.78.08 (mã NVIDIA, không có trong repo), `nvkms_yield` nằm
  trong `nvEvoMakeRoom` (nvkms-dma.c:162), `nvIdleMainLayerChannels` (nvkms-hw-flip.c:3348), `PollForChannelIdle`
  (nvkms-evo3.c:6728), `WaitForFreeSpace` cho cursor (nvkms-cursor3.c:55), v.v. Trên Linux hàm này chỉ gọi `schedule()`;
  ở đây mỗi lần là ít nhất 1 ms ngủ.
- [GT] Chỉ tốn khi các nhánh đó xảy ra (pushbuffer đầy, chờ kênh rảnh). [ĐO] cần counter.
- [DK] `os_schedule()` = `IOSleep(1)` (`os-xnu2.cpp:1407`), nhưng RM chỉ gọi khi hủy lock/yield theo chu kỳ giây
  (locks.c:352, thread_state.c:267), nên không phải đường nóng.

### F7. Log không giới hạn trên đường tạo object của family — L: Thấp · C(cơ chế): Cao · C(tần suất): Chưa biết · R: Thấp · E: Thấp

- [DK] `newMemoryMap`, `newSurface`, `newGLContext`, `newCLContext`, `new2DContext`, `newVideoContext`, `newDisplayPipe`
  dùng `ALOG` (kprintf + IOLog) không điều kiện (`nvrm-accel.cpp:257-272`). `NVEventMachine::prepareBarrier/
  completeBarrier/writeBarrierElement/eventTimeout` cũng vậy (125-130). #242 chỉ chuyển `newSysMemory`/`newVidMemory`/
  `newResource` sang `ALOGV`.
- [ĐO] Đếm số dòng `NVAccel: newMemoryMap` trong `log show` khi kéo/cuộn.

### F8. Tag VRAM qua `IOSurfaceCopyValue`/`IOSurfaceSetValue` trên mỗi lần ghi surface — L: Thấp-Trung bình · C(cơ chế): Cao · R: Trung bình · E: Trung bình

- [DK] `nvmtl_vram_tag_*` (`plugin/NVMTLDevice.m:887-922`) mỗi lần gọi tạo CFString, CFData và một lời gọi IOSurface vào
  kernel. `nvmtl_vram_tag_bump` (2 lời gọi) chạy ở mỗi `nvmtlSurfaceOutDirtied` với `_vramOn`
  (`NVMTLObjects.m:1299`); `nvmtl_vram_tag_current` ở `nvmtlSurfaceIn` khi seed thay đổi (1235).
- [ĐO] Cần profiler (Instruments trên WindowServer cần quyền root) hoặc counter plugin.

### F9. Khóa lớp toàn tiến trình dùng chung giữa encode và worker — L: Thấp-Trung bình · C(cơ chế): Cao · R: Cao(nếu đổi) · E: Cao

- [DK] `@synchronized([NVMTLCommandBuffer class])` được lấy ở `nvmtl_surface_pending_write` (`NVMTLEventSync.m:49-60`;
  lặp mọi queue, dựng key bằng `stringWithFormat`), lúc commit (690-713) và ở worker (748-786). Pass submit-ahead
  (`nvmtl_gsub_ahead_pass`) chạy dưới khóa này và gọi `vkQueueSubmit` (575-582).
- [GT] Luồng encode bị chặn trong lúc worker submit. Chưa có số đo.

### F10. Bản sao source cũ trong repo — rủi ro bảo trì (không phải hiệu năng)

- [DK] `kexts/NVRM/fb/nvrm-fb.cpp` (1656 dòng) là bản cũ của `kexts/NVRMFB/fb/nvrm-fb.cpp` (3978 dòng); test chỉ đọc
  bản NVRMFB. `kexts/NVRM/agdc/nvrm-agdc.cpp` khác `kexts/NVRMAGDC/nvrm-agdc.cpp`. CHANGELOG 2.4.1 ghi một lần phát hành
  nhầm framebuffer "built from an outdated copy of its source".

### F11. Kernel không build lại được từ repo — chặn mọi patch kext

- [DK] `build/` không có script cho NVRM.kext hay NVRMFB.kext. `kexts/NVRM/rmcc.py:6` nhắc `build-nvrm.sh`, file này
  không có trong repo. `build/accel_build.sh:4-13` cần `$OGKM/src/nvidia/_out/Darwin_x86_64/compile_cmds.sh` (một bản
  build RM cho Darwin nằm ngoài repo). README mục "Build from source" mô tả `accel_build_all.sh` như build "the kexts"
  nhưng script này chỉ build NVAccel.
- Hệ quả: patch F1/F4/F6/F7 hiện chỉ chuẩn bị được kèm test tách rời; người dùng không build và cài được nếu không dựng
  lại quy trình build kernel.

### F12. Race dữ liệu trong `nvmtl_subwho_note` — L: Thấp · C: Cao · R: Thấp · E: Thấp

- [DK] `plugin/nvmtl_vk.c:5708-5730` cập nhật mảng tĩnh `g_subwho`/`g_subwho_n` từ nhiều luồng, không có khóa. Số nhãn
  khác nhau hiện khoảng 19 (dưới mức 24) nên chưa ghi vượt biên, nhưng đây vẫn là UB.

### F13. Bản release không có kênh số đo hiệu năng — chặn chẩn đoán F3/F8/F9

- [DK] `nvlog` ở bản release chỉ ghi các dòng khớp mẫu lỗi (`plugin/NVMTLDevice.m:84-107`, `nvmtl_log_failure.h`);
  file fps và đo passtime bị loại khỏi bản release (`build/build_plugin.sh` dòng kiểm "LEAKED diagnostic").
  `nvmtl_perf_*` chỉ bật bằng `NVMTL_PERF_LOG`; nó được nạp từ `nvrm610.conf` (`NVMTLObjects.m:84-127`), nhưng đầu ra
  lại đi qua `nvlog`.

## Không phải vấn đề (đã kiểm)

- `nv_pv_thread` (quét cấu trúc trang XNU, `os-xnu2.cpp:709-723`) chỉ chạy ở build `NVRM_PANIC_HUNT=1` và khi bật chẩn
  đoán; bản release trả về "REFUSED" (797).
- Sampler pixel / HUD / probe grid của NVRMFB chỉ bật bằng boot-arg `nvfbsample`/`nvhud` (2527-2542).
- `osSpinLoop` của RM là spin rỗng như trên Linux.
- `nvmtl_noseed`/`nvmtl_trace_on` gọi `access()` chỉ ở bản không phải release (`NVMTLDevice.m:29-37` chặn đường dẫn
  `/tmp/nvmtl-`).
