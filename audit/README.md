# Audit hiệu năng NullMoth trên fork trancongtu550 — tiến độ

Thư mục này lưu tiến độ audit để các lượt sau không đọc lại hay bỏ sót. Đây là tài liệu làm việc trong fork cá nhân:
**không** phải đóng góp gửi upstream (xem `plan.md` mục 1).

| File | Nội dung |
|---|---|
| `findings.md` | Phát hiện có bằng chứng (file/hàm/dòng), phân loại dữ kiện / giả thuyết / cần đo, xếp hạng |
| `plan.md` | Tối ưu upstream đã có, patch khả thi + kiểm tra, dữ liệu phần cứng còn thiếu, công việc đầu tiên đề xuất |
| `inventory.tsv` | Toàn bộ 663 file Git theo dõi tại base: số dòng, loại, mức đọc, ghi chú/lý do |
| `notes-kernel.md`, `notes-plugin-nvk.md` | Ghi chú đọc mã theo thành phần |
| `test-results.md` | Kết quả từng `tools/test_*.py` trên base và trên từng branch sửa (PASS/FAIL/SKIP/thiếu phụ thuộc) |
| `build-plugin-macos.md` | Quy trình build plugin tái lập trên macOS, kiểm artifact, đối chiếu chỉ đọc với NVK/translator đã cài (chưa chạy trên máy thật) |
| `run_tool_tests.py` | Chạy và phân loại `tools/test_*.py` của một checkout (`python3 -I audit/run_tool_tests.py <checkout> --json <file>`) |

## Branch (fork cá nhân, chưa merge, không gửi upstream)

| Branch | Gốc | Nội dung |
|---|---|---|
| `claude/vigilant-mayer-ptq05r` | `75e2e28` | Script chẩn đoán chỉ đọc + thư mục `audit/` |
| `claude/vigilant-mayer-ptq05r-t6-subwho-race` | `75e2e28` | F12/T6: khóa cho `nvmtl_subwho_note` + `tools/test_subwho_census.py` (`b38e6b3`); test chạy được trên macOS, không che lỗi biên dịch, đo overhead `tools/bench_subwho_census.py` (`ccdf592`) |
| `claude/vigilant-mayer-ptq05r-plugin-build` | `75e2e28` | B1: `tools/nm_build_plugin.sh` + harness, `tools/test_plugin_abi_contract.py` (`a1588ac`) |
| `claude/vigilant-mayer-ptq05r-integration` | `75e2e28` | Gom T2, T6, công cụ build/test và 4 tối ưu CPU (bind index/vertex trùng, khóa tag IOSurface, poll debug trong release), mỗi thay đổi một commit; bàn giao: `audit/handoff.md` trên branch đó (`9cc2138`) |
| `claude/vigilant-mayer-ptq05r-t2-diag-counters` | `3c9c1d3` | T2: script đọc thêm counter có sẵn, allowlist `nvrm610.conf`, cảnh báo boot-arg + harness `tools/test_nm_readonly_diagnostics.{sh,py}` (commit `8adfb3b`) |

## Base

- `75e2e28a55fef0e3c3001235c6d28c8cfae0019a` = upstream `nullmoth/nvidia-macos-driver` main = tag v2.5.3
  (kiểm `git ls-remote` 2026-10-23).
- Mã tham khảo bên ngoài repo: NVIDIA `open-gpu-kernel-modules` tag `615.78.08` (commit `1a82fbf`), chỉ checkout thưa
  các thư mục `nvidia-modeset/src`, `nvidia/src/kernel/{core,gpu/gsp}`, `nvidia/arch/nvalloc/unix/src` để tra
  `nvkms_yield`, `osSchedule`, `osSpinLoop`. Không đưa vào repo.

## Mức đọc trong `inventory.tsv`

| Mức | Nghĩa | Số file | Số dòng |
|---|---|---:|---:|
| `L3-full` | Đọc toàn bộ từng dòng | 35 | 4958 |
| `L2-partial` | Đọc kỹ các khoảng dòng ghi trong cột ghi chú (đường hiệu năng); phần còn lại chỉ lướt cấu trúc | 16 | 43148 |
| `L1-grep` | Chỉ grep / so sánh / parse / chạy test | 110 | 13641 |
| `L0-not-read` | Chưa đọc; cột ghi chú nêu lý do | 503 | 333031 |

Tổng 664 dòng trong `inventory.tsv` (663 file của base + `audit/run_tool_tests.py`). Số dòng `L2-partial` giữ nguyên vì
cột "lines" là cả file; khoảng đã đọc của từng file ghi ở cột ghi chú.

Phần lớn số dòng L0 là translator (~311k dòng Rust, phần lớn là test và mã sinh). **Không tuyên bố đã đọc hết repo.**

## Lượt sau nên đọc tiếp (theo ưu tiên)

1. Mesa `17ca6174` `src/nouveau/vulkan/nvkmd/nvkmd.c` (`nvkmd_mem_map`/`unmap`) để kết luận F16; và runtime Vulkan của Mesa
   (`vk_graphics_state`) để biết dynamic state trùng có bị lọc không — cần nguồn Mesa (không tải được trong cloud này).
2. `kexts/NVRMFB/fb/nvrm-fb.cpp` 136-1490 (kapiInit, hotplug), 2340-2436 (applyMode), 2560-3130 (mode, timing).
3. `plugin/NVMTLObjects.m` 4669-4897 từng dòng (blit encoder: copy, `synchronizeResource`), 5150-5700.
4. `plugin/nvmtl_vk.c` 6380-8010.

## Quy ước

- Không sửa cấu hình máy, EFI/BIOS/SIP/AMFI/firmware; không cài, không merge, không phát hành, không gửi upstream.
  Sửa source driver chỉ khi có bằng chứng và test, mỗi bản sửa trên branch riêng (F12/T6).
- Mọi số liệu "tác động" là giả thuyết cho tới khi đo trên máy thật.
