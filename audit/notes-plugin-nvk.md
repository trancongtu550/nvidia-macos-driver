# Ghi chú đọc mã: plugin Metal và NVK (patch)

Base `75e2e28`. Ghi chú làm việc; bản tổng hợp nằm ở `findings.md`.

## Cấu trúc build plugin

- Chỉ biên dịch một translation unit `plugin/NVMTLDevice.m` (`build/build_plugin_release.sh`). File này `#import`
  `NVMTLObjects.m` (gồm `NVMTLEventSync.m` ở dòng 4900), `NVMTLLibraryLoad.m`, `NVMTLGL*.m`, `NVMTLEmbedded.m`,
  `NVMTLVendorCompiler.m`, `NVMTLSass.m`, và `#include "nvmtl_vk.c"` (2139).
- Bản release: `-DNVMTL_RELEASE=1`. `nvlog` chỉ đẩy ra syslog các dòng khớp mẫu lỗi (`NVMTLDevice.m:84-107`,
  `nvmtl_log_failure.h`). Biến môi trường `NVMTL_*`/`NVK_*`/`NAK_*`/`NVRM_*` thừa kế từ ngoài bị xóa; giá trị lấy từ
  `/Library/GPUBundles/nvmtl/nvrm610.conf` (`NVMTLObjects.m:84-127`).

## Đường thực thi (NVMTLEventSync.m — đọc toàn bộ)

- Commit: `nvmtlSubmitWithEvents` (689-716) -> seal part -> mark GPU của WindowServer ngoài khóa lớp
  (`nvmtl_ws_mark_pending` 193-220) -> `nvmtl_pump_buffers`.
- Worker nối tiếp `nvmtl.execution` (746). Mỗi vòng: pass submit-ahead dưới khóa lớp, rồi `nvmtlAdvancePart` cho từng
  command buffer đứng đầu queue (theo reservation). Part đã submit ahead: `nvmtl_gsub_finish` -> `vkWaitForFences`
  (chặn). Part chưa submit: `nvmtl_vk_submit_wait` (submit + chờ).
- Submit-ahead: tối đa 16 part (`NVMTL_GSUB_INFLIGHT`, 469). Part có buffer host-pointer bị giữ lại (569). Part chờ
  event chỉ được gộp (EVFOLD) khi giá trị signal đã được hứa trong channel.
- Hoàn tất: `nvmtlFinishExecution` (420-462) chạy presentation block, trả mark surface, dọn tài nguyên. Callback được
  dispatch qua hàng đợi thứ tự rồi `dispatch_sync` vào queue đích (376-401).
- Khóa: `@synchronized([NVMTLCommandBuffer class])` (49, 67, 261, 619, 627, 690, 702, 713, 748-786), `nvmtl_ws_lock`
  riêng cho mark WindowServer.

## Surface (NVMTLObjects.m, NVMTLDevice.m)

- `nvmtl_surface_image_create` (`NVMTLDevice.m:921-955`): IOSurface 1 plane, `row % 32 == 0` -> import VRAM của family
  qua escape `nvmtl_vk_surface_vram` (`nvmtl_vk.c:1938-1970`, `pnvk_stage_import`) -> `_vramOn` (chia sẻ giữa tiến
  trình). Ngược lại -> ảnh private, copy vào/ra.
- `nvmtlSurfaceIn` (`NVMTLObjects.m:1227-1256`): bỏ qua nếu seed khớp; nếu không: lock IOSurface, upload bằng import
  trang host (`nvmtl_vk_image_write_host`) hoặc qua staging (`nvmtl_vk_image_write`), đều submit + chờ.
- `nvmtlSurfaceOutDirtied` (1287-1330): `_vramOn` -> escape dirty (blocking hoặc try) + tag VRAM; ảnh private ->
  readback đồng bộ.
- Tag VRAM là giá trị IOSurface `NVMTLVramAt:p<plane>` (`NVMTLDevice.m:887-922`).

## Vulkan (nvmtl_vk.c)

- Một `VkQueue` (`g_queue`) cho mọi submit (1066); `nvmtl_submit_mutex` đệ quy (5633).
- Mỗi submit tạo một `VkFence` mới (5760). Prologue upload/fill đi kèm submit (5649-5695).
- Chờ: `nvmtl_vk_submit_finish` (5804-5840): `vkWaitForFences` theo lát, ngân sách 5000 ms (WindowServer) / 60000 ms.
- Ngân sách VRAM: `VK_EXT_memory_budget`, cache 50 ms (1585-1605); `nvmtl_vk_vram_wall` gọi residency res1/res2.
- Mesa disk cache cho tiến trình không có HOME ghi được (692-703).

## Residency (NVMTLObjects.m 313-575)

- res2 LRU chỉ chạy khi `vram_wall` báo áp lực. Luồng cấp phát có thể chờ pager tới 30 ms (367) và chờ VRAM được trả
  tới 16 ms (389).

## Shader cache (NVMTLLibraryLoad.m)

- aircache/spvcache trong `NVMTL_AIRCACHE_DIR`, hoặc `~/Library/Caches/nvmtl`, hoặc `DARWIN_USER_CACHE_DIR`
  (152-180, 344-372). Cache hit gọi `utimes` lên file (862). Trim chạy bất đồng bộ.

## NVK (nvk/nvk-macos.patch)

- `nvkmd_nvrm_sync.c` (file mới, đọc toàn bộ): sync dựa trên semaphore theo slot; `nvrm_gsub_wait` lặp: reap, kiểm tra
  sức khỏe slot, phát hiện treo theo ngân sách, `nvkmd_nvrm_wait_block`.
- `nvkmd_nvrm_ctx.c`: `nvkmd_nvrm_wait_backoff` (179-190); `nvkmd_nvrm_wait_block` (215-247): event cho WindowServer
  hoặc khi `NVRM_EVENT_WAIT=1`, ngược lại backoff; context CE-only luôn backoff. Submit (`nvrm_gsub_submit` 902-948):
  semaphore release có WFI + NON_STALL_INTERRUPT, rồi doorbell. 64 slot lệnh / ring 64 KB; chờ slot nếu vòng đầy
  (935-941). Đường không async (`exec_ctx_flush` 1063-1159) chờ đồng bộ với backoff.
- `nvmtl_cfg.h`: đọc `nvrm610.conf` một lần (8 KB).
- Không đọc: NAK compiler, ray tracing, BVH, `nvk_cmd_buffer.c` (ngoài đường compositor).

## Lượt 2

- `nvmtl_subwho_note` (5706-5730): bên gọi duy nhất `nvmtl_vk_submit_begin_at` 5739, trước `nvmtl_submit_mutex` (5764).
  Race đã chứng minh và sửa trên branch T6 (F12).
- Bộ đo có sẵn: `nvmtl_perf_now`/`nvmtl_perf_note`/`nvmtl_perf_submit` (2704-2740), bật bằng `NVMTL_PERF_LOG` (đọc được từ
  conf ở bản release), in `PERFSUB` ra stderr mỗi submit (gọi ở 5905). Điểm đo: `begin` (4703-4729), `bufnew/bufpool`
  (1291-1303), `bufdel`, `heap`, `syncin`, `syncout`, `copy`.
- Bộ đếm cấp phát không khóa (F15): `g_alloc_bytes` 153, `g_vram_bytes/g_sys_bytes` 164; người đọc `nvmtl_vk_allocated_bytes`
  6164, ngân sách dự phòng 1594, working set 1692.
- Render pass (4699-5300): `nvmtl_vk_cmd_begin_pass` 4804-4986 tạo `VkFramebuffer` mỗi pass (4937), giữ trong `c->fbs`;
  biến thể render pass theo load action tạo một lần dưới `g_rpv_lock` (4733-4777); render pass "shape" cho resolve
  (5107-5208).
- Bindless (2319-2580): heap descriptor tạo lúc khởi động (2343-2400); `nvmtl_bl_slot` hash view->slot dưới `g_bl_lock`;
  `nvmtl_heap_write_locked` -> `vkUpdateDescriptorSets` một lần cho mỗi view mới.
- NVK `nvkmd_nvrm_mem.c` (trong patch, đọc toàn bộ): mỗi `vkAllocateMemory` = `nvRmApiAlloc` (bộ nhớ vật lý) +
  `NV50_MEMORY_VIRTUAL` (`nvkmd_nvrm_va.c`) + `nvRmApiMapMemoryDma` -> ít nhất 3 lời gọi kernel, lý do plugin dùng pool.
  VRAM dùng trang lớn 64 KB và `ALLOW_NONCONTIGUOUS` (tắt bằng `NVK_NO_BIGPAGE`/`NVK_NO_NONCONTIG`). Bộ nhớ LOCAL có
  map CPU mặc định chuyển sang RAM hệ thống trừ khi `NVK_LOCAL_MAP_SYSMEM=0` và BAR1 phủ hết VRAM (F17). Bảng
  `dev->mappings` không khóa trong patch (F16, chưa kết luận).

## Lượt 3

- Đường mỗi draw (render): `nvmtlBindSamplerPipeline` (`NVMTLObjects.m:2776-2790`) -> thêm pipeline vào tập tài nguyên
  (MRU), `nvmtl_vk_cmd_bind_pipeline` (bỏ trùng), `nvmtl_bind_embedded` × 2, `nvmtl_vk_cmd_bind_set` (snapshot/reuse set, bỏ
  bind trùng) -> `nvmtl_vk_cmd_set_topology` (luôn gọi 2 lệnh dynamic state) -> `nvmtlVertexInputs` (bind vertex buffer
  từng thuộc tính) -> `vkCmdDraw`/`vkCmdDrawIndexed` (index buffer bind mỗi lần).
- Compute: barrier giữa các dispatch qua `nvmtlE78Barrier` (`NVMTLObjects.m:4503-4523`), mặc định thu hẹp/gộp.
- Plugin nạp NVK trực tiếp từ `/Library/GPUBundles/nvmtl/libvulkan_nouveau.dylib` (`nvmtl_vk.c:109-117, 705`), rơi về
  loader nếu không có `vkGetInstanceProcAddr`; tra 10 entry point riêng; translator nạp từ cạnh plugin hoặc
  `/Library/GPUBundles/nvmtl/libnvmtl_translate.dylib` (`NVMTLLibraryLoad.m:104-140`), chỉ `nvmtl_translate` bắt buộc.
- NVK build `debugoptimized` (assert bật, F18); plugin `-O1` (F19). Patch NVK sửa `nvk_cmd_buffer.c` cho chuỗi dispatch
  compute (GDQ), không đụng đường draw ngoài hai assert bị hạ thành cảnh báo.
