# Ghi chú đọc mã: kernel (NVAccel, NVRMFB)

Base: `75e2e28a55fef0e3c3001235c6d28c8cfae0019a` (= upstream `nullmoth/nvidia-macos-driver` main = tag v2.5.3, kiểm tra
bằng `git ls-remote` ngày 2026-10-23). Ghi chú làm việc; bản tổng hợp nằm ở `findings.md`.

## kexts/NVRM/accel/nvrm-accel.cpp (2469 dòng) — ĐÃ ĐỌC TOÀN BỘ

- 125-130 `NVEventMachine`: `prepareBarrier`/`completeBarrier`/`writeBarrierElement`/`eventTimeout` gọi `ALOG` không giới hạn.
  Tần suất gọi phụ thuộc runtime (family event barrier). Cần đếm trong log.
- 257-272 các hàm `new*()` của family: `newMemoryMap` (272), `newSurface`, `newGLContext`, `newCLContext`,
  `new2DContext`, `newVideoContext`, `newDisplayPipe` dùng `ALOG` không điều kiện; chỉ `newSysMemory`, `newVidMemory`,
  `newResource` đã chuyển sang `ALOGV` (#242). Tần suất `newMemoryMap` khi kéo/cuộn: cần đo.
- 720-820 nhiệt độ: timer 250 ms trên work loop của accelerator, đọc 1 thanh ghi BAR0, copy cả dict
  PerformanceStatistics và `setProperty`. Chi phí thấp (4 Hz).
- 947-998 `NVVidMemory::allocPhysical` (lời gọi 979): gọi `askFramebufferForVram` -> NVRMFB `vramGrant` (đồng bộ, trên luồng của
  family/WindowServer). Nhánh "already backed" (962) và "scanout" log mỗi lần.
- 1000-1028 `deallocPhysical`: VRAM "parked" (sticky) — không trả về NVRMFB cho tới khi resource bị free hoặc lớn lên.
- 1092-1107 `iopMapSurface`: 4 slot cache prepare/map của nguồn copy.
- 1126-1220 `performTransaction`: nhánh flip (1162) hoặc copy: `nvSurfWaitReady` (1170) -> `nvAccelSurfCopyReady`
  (pageoff readback) -> vòng copy volatile 32-bit sang BAR1 (1196-1202) -> lấy mẫu 64 pixel nguồn (1208-1213).
- 1334-1390 cơ chế mark/wait composite (32 slot, IOLock, timeout 100 ms).
- 1532-1550 `nvFamLock`: khóa lớn của IOGraphicsAccelerator2 (`accel+0x88`) + `lock_busy` + `acceleratorDidLock`.
- 1556-1584 `nvSVPend`: 512 slot quét tuyến tính dưới IOSimpleLock.
- 1645-1720 escape surface: mark GPU của WindowServer (không khóa family); `NVRM_ESC_SURF_DIRTY` lấy family lock
  (blocking, trừ khi TRYLOCK).
- 1757-1855 `NVResource::pageoff`: readback đồng bộ: copy engine -> staging (một staging toàn cục, một IOLock) ->
  CPU `writeBytes` vào trang surface. Log chỉ 8 lần đầu rồi mỗi 1024 lần.
- 1857-2122 flip zero-copy, async worker, home flip. `nvAccelIopAsyncRun` gọi `nvFlipToSurfacePure` (NVRMFB).
- 2147-2178 `nvAccelSurfCopyReady`: thử family lock tối đa 8 lần với `IOSleep(1)`.
- 2180-2276 GPU VA alloc/map/free: mỗi lần là một `callPlatformFunction` sang NVRM.
- 2282-2462 đường swap legacy (`submitSwapCopy`, `nvaccel_stubs.h:105-113`): copy giới hạn 120 lần, lấy mẫu BAR1.

## kexts/NVRM/accel/nvaccel_stubs.h (187 dòng) — ĐÃ ĐỌC TOÀN BỘ

## kexts/NVRMFB/fb/nvrm-fb.cpp (3978 dòng) — ĐỌC CÓ CHỌN LỌC (khoảng dòng: `inventory.tsv`)

Đã đọc kỹ: 1-135, 1490-1760 (trace, chờ flip, present stats, submitConfig), 1754-2340 (sampler, reflip, gamma,
cursor, vblank), 2436-2560 (start: các thread call), 3130-3530 (verifyAperture, vramGrant/Release,
callPlatformFunction), 3530-3680 (flipToMemory).

- 42-56 `NVRMDisplayGate` = MỘT `IORecursiveLock` toàn cục (`startLock`, 1522-1531) cho mọi framebuffer/head.
- Gate được lấy bởi: `reflip` 1794, `nvrmSetGamma` 1920, `cursorApply` 2047, `setCursorImage` 2118, `setHeadActive`
  2290, `applyMode` 2340, `switchMode` 2851, `vramGrant` 3262, `vramRelease` 3435, `flipToMemory` 3533, `headOff`
  3766, `setHeadPower` 3784, `gpuWakeFire` 3926, và stop/start (1353, 2476, 2491, 2509, 2572).
- `flipToMemory` (3530) giữ gate trong suốt `submitConfig` (3629). Với `gFlipLatch == 1` (mặc định, 1565),
  `submitConfig` chờ flip latch tối đa `flipWaitUs()` = 1,25 chu kỳ quét (1722-1729) và chờ flip trước đó qua
  `priorFlipState` (1672-1683), đều trong gate.
- `vramGrant` (3260-3410) giữ gate trong khi: `allocateMemory`, `mapMemory(KERNEL)`, rồi **xóa trắng toàn bộ vùng cấp
  phát bằng CPU qua ánh xạ BAR1** (`nvu_zero_wide`, 3399), rồi kiểm tra đọc/ghi. Chú thích 119-123 đo được: 8 MB mất
  ~20 ms trên RTX 3070 Laptop với `rep stosq`.
- `cursorApply` (2045) lấy gate rồi `submitConfig(cursorOnly)` (trả về ngay, không chờ latch).
- vblank: `hwVblIntr` (2241) -> thread call -> `hwVblDeliver` (2250) gọi VBL proc của IOFramebuffer; mốc thời gian
  được lấy lúc thread call chạy, không phải lúc ngắt (`fHwVblLast` được ghi nhưng không truyền đi). Timer dự phòng
  `vblFire` vẫn chạy mỗi chu kỳ ngay cả khi vblank phần cứng đang sống (2277-2287).
- Mỗi flip cấp phát/giải phóng `NvKmsKapiRequestedModeSetConfig` + reply bằng `IOMalloc` (3599-3603, 3633).
- Sampler / HUD / probe grid chỉ bật bằng boot-arg (`nvfbsample`, `nvhud`), mặc định tắt (2527-2542).

## Bản sao trùng lặp

- `kexts/NVRM/fb/nvrm-fb.cpp` (1656 dòng) là bản cũ của `kexts/NVRMFB/fb/nvrm-fb.cpp` (3978 dòng); test chỉ đọc bản
  NVRMFB. CHANGELOG 2.4.1 ghi một lần ship nhầm framebuffer từ "an outdated copy of its source".
- `kexts/NVRM/agdc/nvrm-agdc.cpp` khác `kexts/NVRMAGDC/nvrm-agdc.cpp`.
- Header ABI trùng nhưng hiện khớp: `nvrm_vram_abi.h` (3 bản giống nhau), `nvrm_gpuva_abi.h` (2 bản giống nhau).
  `nvrm_surfshare_abi.h` khác giữa NVRM và NVRMFB, nhưng NVRMFB không dùng phần khác biệt.

## Lượt 2

- `kexts/NVRM/nvrm_pageoff.c` (đọc toàn bộ): `nvrm_ce_copy_to_pages` 109-135 giữ `rmapiLockAcquire` +
  `rmDeviceGpuLocksAcquire` trong khi `_nvrmCopyLocked` chờ copy engine bằng `osDelayUs(10)` lặp tới 200000 lần
  (80-83, 99-103); `osDelayUs` -> `os_delay_us` -> `IODelay` (`os-xnu.cpp:199`). Xem F14.
- `kexts/NVRM/nvrm_surfshare.cpp` (đọc toàn bộ): sysctl `debug.nvrm_pageoff_runs/_pages/_coalesced/_perpage` (46-49), đăng ký
  ở lần page-off đầu (60-63).
- `kexts/NVRM/os-xnu2.cpp` 1092-1158: `nv_alloc_pages` luôn gọi `nv_watch_init` và `nv_q_init`; `nv_free_pages` -> `nv_q_put`
  (quarantine: giữ 2 s, tối đa 256 MB / 4096 mục, kiểm `nv_pg_still_mapped` từng trang). Work item mỗi lần một kernel
  thread (1295). 332-340: `nvrmdiag` mở sysctl chẩn đoán in địa chỉ vật lý, chỉ root đọc.
- `kexts/NVRMFB/fb/nvrm-fb.cpp` 3260-3431 (`vramGrant`) đọc lại từng dòng cho F1: các biến chỉ gate bảo vệ là bảng park
  (3181-3182), `gAllocations`, `advanceFlipEpoch`, `fVramGrants`; `fDev`/`fKms` không bao giờ bị đặt lại. Bảng phân tích
  trong `findings.md` F1.
- Build (F11): đọc mọi điểm vào build; NVRM.kext và NVRMFB.kext không có script; cây NVIDIA 615.78.08 không xử lý Darwin
  trong makefile (`utils.mk:122-139`).
