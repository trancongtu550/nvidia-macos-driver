# Kết quả `tools/test_*.py` — cập nhật lượt 3

Chạy bằng `python3 -I audit/run_tool_tests.py <checkout> --json <file>` trong cloud (Linux x86_64, Python 3.13, gcc 13, clang 18;
không có macOS SDK; clang 18 ở đây không có runtime ASAN/TSAN, gcc 13 có). Lịch sử git đầy đủ. Quy tắc phân loại: docstring của
`audit/run_tool_tests.py`. Mỗi cột là đầu nhánh hiện tại; "—" là test không có trên nhánh đó.

| Checkout | Tổng | PASS | FAIL | SKIP | MISSING (thiếu phụ thuộc) | DEPFAIL (assert hỏng + thiếu phụ thuộc) |
|---|---:|---:|---:|---:|---:|---:|
| base 75e2e28 | 70 | 51 | 0 | 0 | 18 | 1 |
| T6 ccdf592 | 71 | 52 | 0 | 0 | 18 | 1 |
| T2 8adfb3b | 71 | 52 | 0 | 0 | 18 | 1 |
| build a1588ac | 72 | 53 | 0 | 0 | 18 | 1 |

Branch làm việc `claude/vigilant-mayer-ptq05r` chỉ thêm `audit/` và `tools/nm_readonly_diagnostics.sh` (không có test riêng): kết quả trùng base (70 test).
Không test có sẵn nào đổi trạng thái trên bất kỳ branch nào; PASS tăng thêm là test mới của branch đó.

## Từng test

| Test | base | T6 | T2 | build | Lý do (khi không PASS) |
|---|---|---|---|---|---|
| `test_angle_chrome_family.py` | MISSING | MISSING | MISSING | MISSING | xcrun (macOS SDK) |
| `test_angle_optin.py` | MISSING | MISSING | MISSING | MISSING | macOS headers for the C fixture |
| `test_bar1_budget.py` | PASS | PASS | PASS | PASS |  |
| `test_bar1_resize_choice.py` | PASS | PASS | PASS | PASS |  |
| `test_bindfd_range.py` | MISSING | MISSING | MISSING | MISSING | xcrun (macOS SDK) |
| `test_boot_guard_wait.py` | PASS | PASS | PASS | PASS |  |
| `test_boot_raster_modes.py` | PASS | PASS | PASS | PASS |  |
| `test_boot_raster_pick.py` | PASS | PASS | PASS | PASS |  |
| `test_bytes_dup_seal.py` | PASS | PASS | PASS | PASS |  |
| `test_card_support.py` | MISSING | MISSING | MISSING | MISSING | xcrun (macOS SDK) |
| `test_checksum_strict.py` | PASS | PASS | PASS | PASS |  |
| `test_copy_class_selection.py` | PASS | PASS | PASS | PASS |  |
| `test_display_power_retry.py` | PASS | PASS | PASS | PASS |  |
| `test_eld.py` | PASS | PASS | PASS | PASS |  |
| `test_fb_open_console_copies.py` | PASS | PASS | PASS | PASS |  |
| `test_fbclaim_match.py` | PASS | PASS | PASS | PASS |  |
| `test_fd_pool.py` | PASS | PASS | PASS | PASS |  |
| `test_flip_cache_epoch.py` | PASS | PASS | PASS | PASS |  |
| `test_flip_latch_counters.py` | PASS | PASS | PASS | PASS |  |
| `test_gpu_id_coverage.py` | PASS | PASS | PASS | PASS |  |
| `test_graphics_bindings.py` | MISSING | MISSING | MISSING | MISSING | xcrun (macOS SDK) |
| `test_gtx16_fb_logs.py` | PASS | PASS | PASS | PASS |  |
| `test_gtx16_nvenc_picker.py` | PASS | PASS | PASS | PASS |  |
| `test_headless_early.py` | PASS | PASS | PASS | PASS |  |
| `test_hwvbl_retry.py` | PASS | PASS | PASS | PASS |  |
| `test_icd_fd_token.py` | PASS | PASS | PASS | PASS |  |
| `test_igfx_plan.py` | PASS | PASS | PASS | PASS |  |
| `test_igfx_trace.py` | PASS | PASS | PASS | PASS |  |
| `test_install_keeps_my_settings.py` | PASS | PASS | PASS | PASS |  |
| `test_install_private_copy.py` | MISSING | MISSING | MISSING | MISSING | ditto (macOS) |
| `test_iop_flip_gate.py` | PASS | PASS | PASS | PASS |  |
| `test_iop_flip_outcome.py` | PASS | PASS | PASS | PASS |  |
| `test_iop_present_path.py` | PASS | PASS | PASS | PASS |  |
| `test_kms_copy_and_quota.py` | PASS | PASS | PASS | PASS |  |
| `test_mem_unmap_no_double_free.py` | PASS | PASS | PASS | PASS |  |
| `test_nm_build_plugin.py` | — | — | — | PASS |  |
| `test_nm_readonly_diagnostics.py` | — | — | PASS | — |  |
| `test_nmhda_native_id.py` | PASS | PASS | PASS | PASS |  |
| `test_nv_parms_table.py` | PASS | PASS | PASS | PASS |  |
| `test_nvk_quiet.py` | PASS | PASS | PASS | PASS |  |
| `test_nvrm_map_table.py` | MISSING | MISSING | MISSING | MISSING | a commit absent from the public history |
| `test_nvrmfb_gamma_guard.py` | PASS | PASS | PASS | PASS |  |
| `test_nvrmfb_hotplug_lifecycle.py` | PASS | PASS | PASS | PASS |  |
| `test_opengl_perf.py` | MISSING | MISSING | MISSING | MISSING | xcrun (macOS SDK) |
| `test_plugin_abi_contract.py` | — | — | — | PASS |  |
| `test_present_stats.py` | PASS | PASS | PASS | PASS |  |
| `test_primary_gpu_install.py` | DEPFAIL | DEPFAIL | DEPFAIL | DEPFAIL | assertions failed with missing: ditto (macOS) |
| `test_push_verify_tolerates_empty.py` | PASS | PASS | PASS | PASS |  |
| `test_pv_sentinel_refuses.py` | PASS | PASS | PASS | PASS |  |
| `test_r3_map_owner.py` | MISSING | MISSING | MISSING | MISSING | xcrun (macOS SDK) |
| `test_refusal_reasons.py` | PASS | PASS | PASS | PASS |  |
| `test_render_sampler_cache.py` | MISSING | MISSING | MISSING | MISSING | xcrun (macOS SDK); Foundation/Metal (macOS SDK) |
| `test_resource_phi_fold.py` | MISSING | MISSING | MISSING | MISSING | translator build (cargo + spirv dependency) |
| `test_resset_lifetime.py` | MISSING | MISSING | MISSING | MISSING | xcrun (macOS SDK); Foundation/Metal (macOS SDK) |
| `test_resset_seal.py` | MISSING | MISSING | MISSING | MISSING | xcrun (macOS SDK); Foundation/Metal (macOS SDK) |
| `test_sass_gate.py` | MISSING | MISSING | MISSING | MISSING | xcrun (macOS SDK) |
| `test_scanout_caps.py` | PASS | PASS | PASS | PASS |  |
| `test_security_hardening.py` | PASS | PASS | PASS | PASS |  |
| `test_slot_handle_guard.py` | PASS | PASS | PASS | PASS |  |
| `test_spvcache_dir.py` | MISSING | MISSING | MISSING | MISSING | xcrun (macOS SDK); Foundation/Metal (macOS SDK) |
| `test_submission_copies.py` | MISSING | MISSING | MISSING | MISSING | Foundation/Metal (macOS SDK) |
| `test_subwho_census.py` | — | PASS | — | — |  |
| `test_surface_alloc_bound.py` | PASS | PASS | PASS | PASS |  |
| `test_surface_pending_lifetime.py` | PASS | PASS | PASS | PASS |  |
| `test_surface_publication.py` | MISSING | MISSING | MISSING | MISSING | Foundation/Metal (macOS SDK) |
| `test_surface_queue.py` | MISSING | MISSING | MISSING | MISSING | Foundation/Metal (macOS SDK) |
| `test_surface_stream_copy.py` | PASS | PASS | PASS | PASS |  |
| `test_tex_upload.py` | PASS | PASS | PASS | PASS |  |
| `test_turing_default_settle.py` | PASS | PASS | PASS | PASS |  |
| `test_userclient_type.py` | PASS | PASS | PASS | PASS |  |
| `test_vbl_period_highrefresh.py` | PASS | PASS | PASS | PASS |  |
| `test_vram_display_budget.py` | PASS | PASS | PASS | PASS |  |
| `test_vram_park_hold.py` | PASS | PASS | PASS | PASS |  |
| `test_witness_keeps_backend.py` | PASS | PASS | PASS | PASS |  |

DEPFAIL duy nhất (`test_primary_gpu_install.py`): mọi case hỏng đều có `install.sh: line 175: ditto: command not found` (đã đọc từng case ở lượt 2); `ditto` chỉ có trên macOS.

## Kiểm tra riêng ngoài bộ chạy (lượt 3)

| Kiểm | Kết quả |
|---|---|
| `test_subwho_census.py` với `CC=clang` (clang 18 thiếu runtime sanitizer, rơi về gcc) | 6/6 OK |
| `test_subwho_census.py` khi chỉ có clang 18 trong PATH | OK, 3 SKIP có lý do (TSAN/ASAN không chạy được chương trình rỗng) |
| `test_subwho_census.py` với trình biên dịch giả lập lỗi biên dịch fixture khi có sanitizer | 3 FAIL (đúng kỳ vọng: không bị che thành SKIP) |
| `test_nm_build_plugin.sh` (harness Xcode giả lập) | 53/53 trên commit có tag v2.5.3; 52/52 sau commit (một ca chỉ chạy khi HEAD là tag) |
| `test_plugin_abi_contract.py`: đối chứng chữ ký (đổi `uint32_t`->`uint64_t` trong patch) | sai lệch được phát hiện |
