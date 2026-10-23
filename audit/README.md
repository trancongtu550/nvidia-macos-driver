# Audit hiệu năng NullMoth trên fork trancongtu550 — tiến độ

Thư mục này lưu tiến độ audit để các lượt sau không đọc lại hay bỏ sót. Đây là tài liệu làm việc trong fork cá nhân:
**không** phải đóng góp gửi upstream (xem `plan.md` mục 1).

| File | Nội dung |
|---|---|
| `findings.md` | Phát hiện có bằng chứng (file/hàm/dòng), phân loại dữ kiện / giả thuyết / cần đo, xếp hạng |
| `plan.md` | Tối ưu upstream đã có, patch khả thi + kiểm tra, dữ liệu phần cứng còn thiếu, công việc đầu tiên đề xuất |
| `inventory.tsv` | Toàn bộ 663 file Git theo dõi tại base: số dòng, loại, mức đọc, ghi chú/lý do |
| `notes-kernel.md`, `notes-plugin-nvk.md` | Ghi chú đọc mã theo thành phần |

## Base

- `75e2e28a55fef0e3c3001235c6d28c8cfae0019a` = upstream `nullmoth/nvidia-macos-driver` main = tag v2.5.3
  (kiểm `git ls-remote` 2026-10-23).
- Mã tham khảo bên ngoài repo: NVIDIA `open-gpu-kernel-modules` tag `615.78.08` (commit `1a82fbf`), chỉ checkout thưa
  các thư mục `nvidia-modeset/src`, `nvidia/src/kernel/{core,gpu/gsp}`, `nvidia/arch/nvalloc/unix/src` để tra
  `nvkms_yield`, `osSchedule`, `osSpinLoop`. Không đưa vào repo.

## Mức đọc trong `inventory.tsv`

| Mức | Nghĩa | Số file | Số dòng |
|---|---|---:|---:|
| `L3-full` | Đọc toàn bộ từng dòng | 30 | 4625 |
| `L2-partial` | Đọc kỹ các khoảng dòng ghi trong cột ghi chú (đường hiệu năng); phần còn lại chỉ lướt cấu trúc | 14 | 42408 |
| `L1-grep` | Chỉ grep / so sánh / parse / chạy test | 111 | 13004 |
| `L0-not-read` | Chưa đọc; cột ghi chú nêu lý do | 508 | 334670 |

Phần lớn số dòng L0 là translator (~311k dòng Rust, phần lớn là test và mã sinh). **Không tuyên bố đã đọc hết repo.**

## Lượt sau nên đọc tiếp (theo ưu tiên)

1. `kexts/NVRMFB/fb/nvrm-fb.cpp` 136-1490 (kapiInit, hotplug), 2340-2436 (applyMode), 2560-3130 (mode, timing) — kiểm tra
   thêm đường dùng gate và các lần cấp phát lúc đổi mode.
2. `plugin/NVMTLObjects.m`: render/compute encoder (2600-4900) — binding, barrier, chi phí ghi lệnh mỗi draw.
3. `plugin/nvmtl_vk.c` 1213-1470 (tạo buffer, import host), 1719-1890 (cấp phát ảnh), 2319-3300 (bindless/descriptor),
   4699-5600 (render pass).
4. `nvk/nvk-macos.patch`: `nvkmd_nvrm_mem.c`, `nvkmd_nvrm_va.c`, `nvRmSemSurf.c`, `nvk_cmd_buffer.c`.
5. `kexts/NVRM/os-xnu2.cpp` phần còn lại (cấp phát trang, map) và `nvrm_pageoff.c` (copy engine của page-off).

## Quy ước

- Không sửa source driver, cấu hình máy, EFI/BIOS/SIP/AMFI/firmware; không cài, không merge, không phát hành.
- Mọi số liệu "tác động" là giả thuyết cho tới khi đo trên máy thật.
