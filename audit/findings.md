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

**Phân tích lượt 2 — điều kiện để xóa VRAM ngoài gate (chưa triển khai):**

| Câu hỏi | Dữ kiện trong mã | Kết luận |
|---|---|---|
| Gate đang bảo vệ gì trong `vramGrant` (3260-3430)? | `gParkedForever`/`gNParkedForever` (3181-3182, ghi ở 3338-3341, 3364-3367) không atomic; `gAllocations.insert` (3414); `advanceFlipEpoch()` (3420) phải xảy ra trước khi bên gọi thấy vùng nhớ; `fVramGrants`, `fVramGrantLogged`. Ngân sách đã dùng `OSAddAtomic64` (3273, 3275, 3342, 3368, 3386, 3410, 3417) | Ba nhóm trên phải giữ trong gate. Bản thân việc xóa thì không: vùng nhớ chưa vào `gAllocations`, chưa trả về ai, chỉ luồng đang cấp phát thấy `kva` |
| Thứ tự khóa | Gate là `IORecursiveLock` (49-55). Bên gọi duy nhất: `NVVidMemory::allocPhysical` (`nvrm-accel.cpp:947-998`) -> `askFramebufferForVram` (541-548) -> `callPlatformFunction`. `allocPhysical` là override do lớp family của Apple gọi; mã nguồn family không có, nên **không xác định được** nó có giữ khóa family khi gọi hay không | Tách thành 3 pha (A: trong gate — ngân sách, `allocateMemory`, `mapMemory`, xử lý park, 3260-3397; B: ngoài gate — `nvu_zero_wide` + kiểm tra ghi/đọc, 3399-3411; C: trong gate — `gAllocations.insert`, `advanceFlipEpoch`, publish) không thêm khóa mới nên không tạo cạnh thứ tự khóa mới. Nếu bên gọi đã giữ gate (đệ quy), unlock ở pha B không thực sự nhả: hành vi giữ nguyên, không có lợi nhưng không hại |
| Vòng đời | `fDev`/`fKms` (khai báo 231-232) chỉ được gán, không thấy chỗ nào đặt lại `nullptr` hay giải phóng (grep `fDev = nullptr`, `freeDevice`: không có) | Thiết bị không bị hủy giữa pha A và C. Vẫn phải kiểm lại `fKms && fDev` ở pha C cho an toàn |
| Nhánh lỗi | Hiện tại: kiểm tra aperture thất bại (3401-3411) -> unmap, free, trả ngân sách; `gAllocations.insert` thất bại (3415-3418) -> như trên | Ở bản tách: lỗi pha B phải lấy lại gate trước `unmapMemory`/`freeMemory` (chưa chứng minh các hàm kapi NVKMS an toàn khi gọi ngoài gate), rồi trả ngân sách; không bao giờ publish vùng chưa xóa xong |
| GPU standby | `callPlatformFunction("NVRMGpuPower")` (3453-3465) không lấy gate | Ghi BAR1 trong lúc GPU đi ngủ có thể xảy ra **ngay cả hiện nay** (xóa trong gate không chặn được thông báo này); việc tách không làm rủi ro này tệ hơn |
| Lợi ích còn lại nếu family giữ khóa riêng | Chú thích 122: "8 MB grant took ~180 ms with WindowServer waiting on it" (byte store), ~20 ms với `rep stosq` | Nếu `allocPhysical` chạy dưới khóa family, WindowServer vẫn chờ việc xóa; chỉ flip/cursor (cần gate) được giải phóng. **Cần đo**: delta `nvrmfb_vram_grants`/`_grant_bytes` (script T2) trong lúc kéo/cuộn — nếu bằng 0 thì F1(b) không áp dụng cho workload đó |

Kiểm thử có thể làm không cần phần cứng: tách 3 pha thành hàm thuần, biên dịch với stub gate/kapi kiểu
`tools/test_boot_raster_modes.py`, kiểm tra (1) không publish trước khi xóa xong, (2) mọi nhánh lỗi trả ngân sách và giải
phóng vùng nhớ, (3) `advanceFlipEpoch` trước publish, (4) gate không bị giữ trong lúc xóa. Vẫn **bị chặn bởi F11** khi muốn
chạy thật.

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

**Phân tích lượt 2 — điều kiện tiên quyết cho surface-in bất đồng bộ (không triển khai):**

| Hạng mục | Hiện trạng (`NVMTLObjects.m:1227-1256`) | Điều kiện nếu chuyển sang bất đồng bộ |
|---|---|---|
| Lock IOSurface | `IOSurfaceLock(ReadOnly)` (1240) giữ tới khi upload đã **hoàn tất trên GPU** (submit + chờ fence), rồi `IOSurfaceUnlock` (1250) | Với import trang host (`nvmtl_vk_image_write_host`, GPU đọc thẳng trang của surface), lock phải giữ tới khi fence xong; nếu nhả sớm, CPU ghi tiếp vào surface trong lúc GPU đang copy -> khung hình bị xé. Unlock sẽ diễn ra trên luồng hoàn tất, không phải luồng đã lock: **chưa xác minh** IOSurface cho phép điều này. Giữ lock lâu hơn cũng có thể chuyển phần chờ sang tiến trình đang ghi surface (nó chờ lock) |
| Seed | `_surfSeed`/`_surfSynced` chỉ ghi sau khi upload thành công (1252) | Chỉ được ghi seed khi fence báo thành công; nếu ghi lúc xếp hàng mà submit thất bại thì ảnh cũ bị coi là mới. Trong lúc đang bay, lần surface-in kế tiếp cùng texture phải thấy trạng thái "đang upload", không upload chồng, không bỏ qua |
| Thứ tự GPU | Hiện tại chờ fence nên mọi lệnh sau thấy dữ liệu mới | Prologue (`nvmtl_vk.c:5649-5695`) đặt upload vào cùng submit với command buffer dùng nó, nên thứ tự GPU được giữ trong một queue. Nhưng command buffer khác (của tiến trình khác, hoặc submit trước đó) đọc cùng ảnh thì không được bảo vệ |
| Khóa | `@synchronized(nvmtl_surface_sync(r))` (1230) bao toàn bộ; submit lấy `nvmtl_submit_mutex` bên trong | Chuyển sang prologue thì phần submit chạy trên worker dưới khóa lớp; hoàn tất (unlock IOSurface, ghi seed) phải chạy trên luồng hoàn tất. Cần chứng minh không có đường nào lấy `nvmtl_surface_sync` khi đang giữ khóa lớp hoặc `nvmtl_submit_mutex` (đảo thứ tự) — **chưa kiểm** |
| Vòng đời buffer import | `nvmtl_vk_image_write_host` import trang, submit, chờ, rồi hủy import (6244-6270) | Import phải sống tới fence; texture hoặc IOSurface bị giải phóng trong lúc bay phải được giữ (retain) tới lúc đó |

Kết luận: chưa có cơ sở để sửa. Bước kế tiếp đúng là **đo** (T1, hoặc `NVMTL_PERF_LOG`, xem F13) số lần và thời gian
surface-in trong WindowServer khi cuộn; chỉ khi con số đáng kể mới thiết kế T7 với fixture macOS.

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

### F11. Kernel không build lại được từ repo — chặn mọi patch kext (truy vết đầy đủ ở lượt 2)

Đã đọc mọi điểm vào build trong repo (`build/*.sh`, `kexts/*/build.sh`, `kexts/NVRM/build-completion-archive.py`,
`kexts/NVRM/rmcc.py`), README mục "Build from source" (153-170) và `kexts/NVRM/patches/README.md`.

| Thành phần | Điểm vào trong repo | Phụ thuộc ngoài repo | Trạng thái |
|---|---|---|---|
| Translator | `build/build_xlate.sh` (bản dev: `~/nvmtl-build/bindless`, `build.lock`, `LIVE/xlate.exports`); `build_xlate_release.sh` (qua `ssh mini`, toolchain `~/nvmtl-build/rustup-home/.../1.98.1`) | cargo, macOS (install_name_tool, codesign) | Script phụ thuộc máy tác giả; build lại được nếu dựng lại đường dẫn. Không chặn |
| Plugin | `build/build_plugin.sh` (`~/nvmtl-build/LIVE/plugin`, `~/Vulkan-Headers`); `build_plugin_release.sh` (`ssh mini`, `/Volumes/MiniData/build/gpu-src/mesa/include`) | Xcode, Vulkan-Headers | Lệnh biên dịch là một dòng `xcrun clang ... NVMTLDevice.m`; build lại được trên macOS có Xcode. Không chặn |
| NVK | `build/build263.sh` (`~/nvmtl-build/rebase263/mesa`, meson/ninja, glslang) | Mesa `17ca6174` + `nvk/nvk-macos.patch` | Build lại được nếu có Mesa đúng commit. Không chặn |
| NVAccel | `build/accel_build.sh`, `accel_build_all.sh` | `$OGKM` (mặc định `~/ogkm610`) chứa `src/nvidia/_out/Darwin_x86_64/compile_cmds.sh` (dòng 15 lấy `-D` từ đó), Kernel.framework | **Thiếu** bản build RM cho Darwin |
| NVRMAGDC, NVPrimarySelector, NMDRM | `build_agdc.sh` (`~/nvmtl-build/nm/agdc`), `build_primary_selector.sh`, `kexts/NMDRM/build.sh` | Kernel.framework | Tự chứa (AGDC cần chép nguồn vào đường dẫn script). Không chặn |
| NMHDA | `kexts/NMHDA/build.sh` | Lilu DEBUG + MacKernelSDK | Tự chứa với 2 phụ thuộc công khai. Không chặn |
| **NVRM.kext** | **Không có.** `rmcc.py:6` nhắc `build-nvrm.sh` (không có trong repo); `rmcc.py` biên dịch một file C với dòng lệnh `osapi.c` lấy từ `compile_cmds.sh` | Cây RM đã build cho Darwin (`libnvkernel.a` theo chú thích `rmcc.py:3`, `compile_cmds.sh`), `libnvkms.a` (patches/README), bước link kext + Info.plist | **Thiếu script** |
| **NVRMFB.kext** | **Không có** (`kexts/NVRMFB/` chỉ có nguồn, header và `fb/Info.plist`) | Header NVKMS kapi từ cây NVIDIA | **Thiếu script** |

Cây NVIDIA: `utils.mk:122-123` đặt `TARGET_OS := $(shell uname)` và `OUTPUTDIR ?= _out/$(TARGET_OS)_$(TARGET_ARCH)` (198),
nên trên Mac thư mục sẽ là `_out/Darwin_x86_64`. Nhưng `utils.mk` chỉ có nhánh cho Linux/FreeBSD/SunOS (126-139, 175) và
`git grep -i darwin` trên toàn bộ tag 615.78.08 không thấy kết quả nào trong makefile.

Mâu thuẫn phiên bản trong tài liệu: README ghi `615.78.08`; `kexts/NVRM/patches/README.md` ghi archive và patch FSP cho
`610.57.04` (cùng một patch `615-viewport-scaling.patch` cho 615); `accel_build.sh:4` và `rmcc.py:6` mặc định
`~/ogkm610`.

Phân loại:
- **Thiếu trong repo (đã chứng minh):** script build NVRM.kext và NVRMFB.kext; quy trình sinh `compile_cmds.sh`,
  `libnvkernel.a`, `libnvkms.a` cho Darwin.
- **Có build được hay không (chưa chứng minh được theo hướng nào):** cây NVIDIA không có xử lý Darwin trong makefile, nên
  nhiều khả năng tác giả dùng thay đổi chưa công bố — đây là **giả thuyết**. Không có bằng chứng là không thể build;
  chỉ có bằng chứng là repo không đủ để build.
- Không tải SDK, cây build hay binary nào từ nguồn không rõ để thử.
- Hệ quả không đổi: patch F1/F4/F6/F7/F14 chỉ chuẩn bị được kèm test tách rời.

### F12. Race dữ liệu trong `nvmtl_subwho_note` — ĐÃ CHỨNG MINH, ĐÃ SỬA trên branch riêng

- [DK] `plugin/nvmtl_vk.c:5706-5730` (base) cập nhật `g_subwho`/`g_subwho_n` không khóa. Bên gọi duy nhất:
  `nvmtl_vk_submit_begin_at` (5739), **trước** `pthread_mutex_lock(&nvmtl_submit_mutex)` (5764). Các luồng đến đây:
  worker `nvmtl.execution` ngoài khóa lớp (`NVMTLEventSync.m:645`), pass submit-ahead dưới khóa lớp
  (`NVMTLEventSync.m:576`), và luồng encode khi upload surface/texture (`nvmtl_vk.c:6268, 6299, 6486`) — không có khóa
  chung trước dòng 5739.
- [ĐO trong cloud] Hàm gốc chạy trên 8 luồng: ThreadSanitizer báo `data race` trong `nvmtl_subwho_note`; số đếm sai ở
  20/20 lần chạy thường. Ghi vượt biên bảng (cần hai luồng cùng đăng ký nhãn thứ 24) **không tái hiện** trong 200 lần chạy
  dưới AddressSanitizer: vẫn là khả năng lý thuyết.
- Sửa: commit `b38e6b3` trên branch `claude/vigilant-mayer-ptq05r-t6-subwho-race` — mutex riêng (lá, không lấy khóa nào
  khác bên trong), định dạng dòng thống kê trong khóa, gọi `nvlog` **sau** khi nhả khóa, biên = kích thước mảng.
  Test `tools/test_subwho_census.py`: tổng chính xác, 1 dòng/4096 submit, biên 24, tái nhập từ log; chạy thường, TSAN,
  ASAN; 3 đối chứng âm (bỏ khóa, log trong khóa, biên lỏng) đều phải hỏng và đã hỏng.
- Không phải cải thiện hiệu năng; chưa build trên macOS.

### F13. Bản release không có kênh số đo hiệu năng — chặn chẩn đoán F3/F8/F9

- [DK] `nvlog` ở bản release chỉ ghi các dòng khớp mẫu lỗi (`plugin/NVMTLDevice.m:84-107`, `nvmtl_log_failure.h`);
  file fps và đo passtime bị loại khỏi bản release (`build/build_plugin.sh` dòng kiểm "LEAKED diagnostic").
  `nvmtl_perf_*` (`nvmtl_vk.c:2704-2740`) chỉ bật bằng `NVMTL_PERF_LOG`; khóa này **được** nạp từ `nvrm610.conf` ở bản
  release (tiền tố `NVMTL_`, `NVMTLObjects.m:84-127`) và không bị `#if` loại. Đính chính lượt 1: đầu ra không đi qua
  `nvlog` mà là `fprintf(stderr, "PERFSUB ...")` (2733), **mỗi submit một dòng** (gọi ở 5905), gồm thời gian hook/end/
  fence/submit/wait/retire và các nhóm `begin`, `bufnew`, `bufpool`, `bufdel`, `heap`, `syncin`, `syncout`, `copy`.
  Với ứng dụng chạy từ Terminal thì đọc được; với WindowServer **chưa xác định** stderr đi đâu.
- Hệ quả cho T1: không viết lại bộ tích lũy; T1 nên dùng lại `g_perf`/`NVP_*` và chỉ thêm (a) điểm đo surface-in/out
  và (b) một kênh xuất tổng hợp định kỳ đọc được với WindowServer.

### F14. Page-off chờ copy engine bằng vòng bận trong khi giữ khóa API và khóa GPU của RM — L: Trung bình(nếu page-off thường xuyên) · C(cơ chế): Cao · C(tần suất): Chưa biết · R: Cao · E: Trung bình

- [DK] `nvrm_ce_copy_to_pages` (`kexts/NVRM/nvrm_pageoff.c:120-129`) lấy `rmapiLockAcquire` rồi
  `rmDeviceGpuLocksAcquire`, gọi `_nvrmCopyLocked`, trong đó chờ copy engine bằng
  `while (ceutilsUpdateProgress(...) < workId) { if (++spins > 200000) timeout; osDelayUs(10); }` (80-83, 99-103).
- [DK] `osDelayUs` -> `os_delay_us` (NVIDIA `arch/nvalloc/unix/src/os.c:180-183`) -> `IODelay` (`os-xnu.cpp:199`), tức
  chờ bận; tối đa 200000 × 10 µs ≈ 2 s mỗi vòng chờ, **trong khi mọi lời gọi RM khác (mọi tiến trình) bị chặn**.
- [DK] Bên gọi: `nvrm_surfshare_pageoff` (`nvrm_surfshare.cpp:53-68`), do `NVResource::pageoff` của NVAccel
  (`nvrm-accel.cpp:1757-1855`) dùng khi readback surface.
- [ĐO] Đã có sysctl `debug.nvrm_pageoff_runs/_pages/_coalesced/_perpage` (`nvrm_surfshare.cpp:46-49`, đăng ký lười ở lần
  page-off đầu) và `NVResource::pageoff` log thời gian 8 lần đầu rồi mỗi 1024 lần. Cần đo tần suất trước khi sửa.
- Hướng sửa (chưa làm, bị chặn bởi F11): chờ bằng ngắt/semaphore của RM hoặc nhả khóa trong lúc chờ — thay đổi ngữ nghĩa
  khóa RM, rủi ro cao.

### F15. Bộ đếm cấp phát của plugin cập nhật không khóa — L: Thấp · C(cơ chế): Cao · R: Thấp · E: Thấp

- [DK] `g_alloc_bytes` (`nvmtl_vk.c:153`), `g_vram_bytes`/`g_sys_bytes` (164), `g_buf_made/gone`, `g_img_made/gone`,
  `g_bar1_bytes` được `+=`/`-=` không khóa ở ~25 chỗ (ví dụ 1280, 1336, 1373, 1447, 1790-1792, 5925, 5958, 6000-6004,
  6024, 6101-6103, 6149, 7400, 7407, 7623). Các khóa gần đó (`g_bpark_lock`, `g_pool_lock`, `g_heap_lock`) không bao các
  dòng này.
- [DK] `nvmtl_vk_buffer_create` được gọi từ `newBufferWithLength` (`NVMTLDevice.m:658-667`) trên luồng của ứng dụng;
  MTLDevice cho phép tạo tài nguyên đồng thời từ nhiều luồng, còn giải phóng có thể chạy trên worker -> hai luồng cập nhật
  cùng biến là đường đi thực.
- Hệ quả: lệch số liệu kế toán. Người đọc: `currentAllocatedSize` (`NVMTLDevice.m:2030`), ngân sách dự phòng khi không có
  `VK_EXT_memory_budget` (1594) và ước lượng working set (1692). Không ảnh hưởng fence/ownership.
- Hướng sửa: `__atomic_add_fetch`/`__atomic_sub_fetch` (đã dùng ở chỗ khác trong file). Chưa làm ở lượt này: nhiều chỗ
  sửa, lợi ích thấp; nên làm cùng T1 nếu T1 đọc các bộ đếm này.

### F16. [GT] NVK: bảng `dev->mappings` dùng chung khi map/unmap mà patch không thêm khóa — cần kiểm Mesa gốc

- [DK] `nvk/nvk-macos.patch`: `nvkmd_nvrm_mem_map` chèn vào `dev->mappings` (`_mesa_hash_table_insert`, dòng 10012 của
  file patch), `nvkmd_nvrm_mem_unmap` tìm và xóa (10037, 10053). Bảng tạo ở dòng 9495 (`nvkmd_nvrm_dev.c`). Không có khóa
  nào quanh các lời gọi này trong patch; hash table của Mesa không an toàn đa luồng.
- [CHƯA KIỂM] Lớp chung `nvkmd_mem_map` trong Mesa `17ca6174` (`src/nouveau/vulkan/nvkmd/nvkmd.c`, phần thân không nằm
  trong patch) có khóa cấp thiết bị hay chỉ cấp từng vùng nhớ. Không tải được nguồn Mesa trong môi trường này
  (gitlab.freedesktop.org bị proxy từ chối; mirror GitHub không được cấp quyền). Nếu chỉ khóa từng vùng nhớ thì hai luồng
  map hai buffer khác nhau (plugin gọi `pvkMapMemory` không khóa ở `nvmtl_vk.c:1333, 1369, 7397, 7615`) là race thật.
- Kiểm chứng: đọc thân `nvkmd_mem_map`/`nvkmd_mem_unmap` ở Mesa `17ca6174`. Không sửa trước khi có bằng chứng.

### F17. [GT] Bộ nhớ LOCAL có map CPU mặc định nằm ở RAM hệ thống — núm chỉnh cần đo

- [DK] `nvkmd_nvrm_alloc_tiled_mem` (file tách `nvkmd_nvrm_mem.c`): bộ nhớ `CAN_MAP` mà không có `BAR` bị chuyển sang GART
  (RAM hệ thống). `NVKMD_MEM_BAR` chỉ được thêm khi `NVK_LOCAL_MAP_SYSMEM=0` **và** BAR1 phủ hết VRAM
  (`nvrm_local_map_stays_vram`). Với 4070 Ti có Resizable BAR, mặc định vẫn là RAM hệ thống.
- [GT] Buffer HOST_VISIBLE|DEVICE_LOCAL mà GPU đọc nhiều lần sẽ đi qua PCIe. Ảnh hưởng tới kéo/cuộn chưa biết; có thể
  thử A/B bằng `NVK_LOCAL_MAP_SYSMEM=0` trong `nvrm610.conf` (tiền tố `NVK_` được nạp). **Cần đo trên máy thật**; khóa
  này không nằm trong allowlist T2 hiện tại.

## Không phải vấn đề (đã kiểm)

- Quarantine trang (`nv_q_*`, `os-xnu2.cpp:1092-1158`) luôn bật: giữ trang đã giải phóng tới 2 s / 256 MB / 4096 mục để
  chặn dùng lại khi GPU còn map. Có chi phí bộ nhớ và kiểm tra mỗi trang, nhưng là tính năng an toàn có chủ đích; không đề
  xuất tắt.
- Render pass (`nvmtl_vk.c:4804-4986`) tạo một `VkFramebuffer` mới cho mỗi pass (4937) và giữ tới khi command buffer
  retire; `g_rpv_lock` chỉ lấy khi tìm/tạo biến thể render pass. Chi phí CPU theo pass, không theo draw; không đủ bằng chứng
  để coi là vấn đề.
- Bindless (`nvmtl_vk.c:2319-2580`): hash view->slot dưới `g_bl_lock`, `vkUpdateDescriptorSets` chỉ khi view mới vào heap.

- `nv_pv_thread` (quét cấu trúc trang XNU, `os-xnu2.cpp:709-723`) chỉ chạy ở build `NVRM_PANIC_HUNT=1` và khi bật chẩn
  đoán; bản release trả về "REFUSED" (797).
- Sampler pixel / HUD / probe grid của NVRMFB chỉ bật bằng boot-arg `nvfbsample`/`nvhud` (2527-2542).
- `osSpinLoop` của RM là spin rỗng như trên Linux.
- `nvmtl_noseed`/`nvmtl_trace_on` gọi `access()` chỉ ở bản không phải release (`NVMTLDevice.m:29-37` chặn đường dẫn
  `/tmp/nvmtl-`).
