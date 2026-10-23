# Quy trình build plugin (NVMTLDriver) tái lập trên macOS — chưa chạy trên máy thật

Mục tiêu: build lại binary `NVMTLDriver` của plugin Metal trên máy Mac của người dùng, kiểm tra artifact và đối chiếu (chỉ
đọc) với bản đang cài. **Không cài, không thay binary hệ thống, không ký, không sudo.** Script và test nằm trên branch
`claude/vigilant-mayer-ptq05r-plugin-build` (commit `a1588ac`). Quy trình này **chưa được chạy trên macOS** (môi trường
cloud không có Xcode); logic script đã được kiểm bằng công cụ Xcode giả lập (`tools/test_nm_build_plugin.sh`, 52-53 ca).

## 1. Thành phần build và nguồn gốc (từ repo)

| Hạng mục | Giá trị trong repo | Nguồn |
|---|---|---|
| Translation unit | Một file: `plugin/NVMTLDevice.m` (nó `#import`/`#include` phần còn lại, gồm `nvmtl_vk.c`) | `build/build_plugin_release.sh:16-18` |
| Kiến trúc / macOS tối thiểu | `-arch x86_64 -mmacosx-version-min=15.0` (bản build cho 26 SDK mà không đặt mức tối thiểu sẽ bị dyld từ chối trên Sequoia) | `build_plugin_release.sh:3-6, 16, 23-24` |
| Cờ | `-bundle -fobjc-arc -O1 -DNVMTL_RELEASE=1 -Wno-protocol -Wno-incomplete-implementation -Werror=unguarded-availability-new` | `build_plugin_release.sh:16-17` |
| Framework | Foundation, Metal, IOSurface, IOKit, CoreFoundation | `build_plugin_release.sh:19` |
| Header Vulkan | Bản release: `include/` của cây Mesa dùng để build NVK (`/Volumes/MiniData/build/gpu-src/mesa/include`); bản dev: Khronos `~/Vulkan-Headers/include` | `build_plugin_release.sh:18`, `build_plugin.sh:11` |
| Mesa cho NVK | commit `17ca6174` + `nvk/nvk-macos.patch` | README dòng 39, 166 |
| Xcode | README ghi "Xcode 16"; phiên bản cụ thể của bản phát hành **không được ghi** | README dòng 155 |
| Ký | Script release **không** ký; `build_plugin.sh` (dev) ký ad-hoc. Bundle `NVMTLDriver.bundle` (Info.plist) **không có trong repo**: chỉ có trong gói phát hành | đọc `build/`, `package/install.sh` |
| Kiểm marker | Danh sách "tính năng phải có / chẩn đoán phải vắng ở release" | `build_plugin.sh:15-33` |

Yếu tố ảnh hưởng tái lập đã kiểm: plugin không dùng `__FILE__`, `__DATE__`, `__TIME__` (grep `plugin/`). Bản release vẫn
giữ `assert()` (không có `-DNDEBUG`; 21 lời gọi). Việc hai lần build cho cùng sha256 hay không phụ thuộc toolchain —
**chưa kiểm được**; script có `--twice` để kiểm.

## 2. Chuẩn bị (trên Mac, người dùng tự làm)

1. Xcode 16 (hoặc Command Line Tools có `xcrun clang`, `vtool`, `lipo`, `otool`, `nm`, `strings`, `shasum`). Ghi lại
   `xcodebuild -version` và `xcrun --show-sdk-version`.
2. Header Vulkan, một trong hai:
   - (khớp bản release) `include/` của Mesa tại commit `17ca6174`, lấy từ kho chính thức `https://gitlab.freedesktop.org/mesa/mesa`;
   - (dev) Khronos `Vulkan-Headers`. Phiên bản header của bản release **không biết**; script ghi `VK_HEADER_VERSION` đã dùng.
3. Bản sao fork (branch `claude/vigilant-mayer-ptq05r-plugin-build`, gốc `75e2e28` = v2.5.3) và revision khớp driver đang cài. Phiên bản đang cài: `cat /Library/NullMoth/driver-version` (chỉ đọc).
   NVK và translator đã cài được build cho bản phát hành đó; build plugin từ tag khác thì `check-installed` sẽ cảnh báo.

## 3. Build (không cần sudo, chỉ ghi vào thư mục output)

```bash
git clone https://github.com/trancongtu550/nvidia-macos-driver.git && cd nvidia-macos-driver
git checkout claude/vigilant-mayer-ptq05r-plugin-build
# fork không có tag; tag phát hành lấy (chỉ đọc) từ upstream, hoặc dùng thẳng SHA: v2.5.3 = 75e2e28a55fef0e3c3001235c6d28c8cfae0019a
git fetch --tags https://github.com/nullmoth/nvidia-macos-driver.git
bash tools/nm_build_plugin.sh build v2.5.3 ~/nm-plugin-out --vk-include ~/src/mesa-17ca6174/include --twice
```

- `v2.5.3`: thay bằng tag khớp `driver-version`. Script `git archive` thư mục `plugin/` và `build/build_plugin.sh` của
  revision đó vào `<out>/src`, nên mã được build không phụ thuộc thư mục làm việc.
- Script dừng nếu output nằm trong `/Library`, `/System`, `/usr`, `/Applications` hoặc thư mục đã có file.
- Kết quả: `<out>/NVMTLDriver`, `<out>/build.err`, `<out>/build-info.txt` (macOS, Xcode, SDK, clang, `VK_HEADER_VERSION`,
  cờ, số warning, sha256, UUID; với `--twice`: `IDENTICAL` hoặc `DIFFERENT`).

## 4. Kiểm tra artifact (script tự chạy; dừng và báo "do not use it" nếu một mục hỏng)

| Kiểm | Lệnh | Đạt khi |
|---|---|---|
| Kiến trúc | `lipo -archs` | đúng `x86_64` |
| macOS tối thiểu | `vtool -show-build` | `minos 15.0` |
| Kiểu file | `otool -h` | filetype 8 (MH_BUNDLE) |
| Thư viện liên kết | `otool -L` | chỉ `/System/Library/...` và `/usr/lib/...` |
| Marker | `strings -a` theo danh sách của `build/build_plugin.sh` | mọi tính năng có mặt; "fps file", "passtime instrument" vắng |
| Warning | `build.err` | được đếm và ghi lại (không làm hỏng build, như script gốc) |

## 5. Đối chiếu với bản đang cài (chỉ đọc)

```bash
bash tools/nm_build_plugin.sh check-installed ~/nm-plugin-out/NVMTLDriver v2.5.3
```

In sha256/minos/UUID của binary vừa build và của `/Library/GPUBundles/NVMTLDriver.bundle/Contents/MacOS/NVMTLDriver`,
`driver-version`, cảnh báo nếu tag nguồn khác bản cài, và với NVK (`/Library/GPUBundles/nvmtl/libvulkan_nouveau.dylib`)
và translator (`libnvmtl_translate.dylib`) đang cài: từng entry point plugin tra bằng `dlsym` có được export (`nm -gU`) hay
không, đánh dấu bắt buộc/tùy chọn. Không ghi gì.

Hợp đồng plugin↔NVK↔translator ở mức mã nguồn được kiểm bởi `tools/test_plugin_abi_contract.py` (cùng branch):
- 10 entry point NVK plugin tra cứu: 7 được patch export; 3 (`nvmtl_nvk_dispatch_sass_v3`,
  `nvmtl_nvk_sass_image_handle_v1`, `nvmtl_nvk_sass_sampler_handle_v1`) **không có trong patch công khai** — chỉ dùng cho
  đường "direct machine code" của RTX 50; plugin tự tắt khi thiếu (`NVMTLSass.m:115-117`). Không ảnh hưởng 4070 Ti.
- 6 chữ ký hàm khớp giữa cast của plugin và định nghĩa trong patch.
- Bản ghi surface `nvmtl_vram_rec` (plugin) và `struct nvmtl_nvk_share` (NVK): cùng layout (kiểm bằng trình biên dịch),
  cùng phiên bản 3.
- 17 entry point translator: đều là `#[no_mangle] extern "C"` trong `translator/wrapper/src/lib.rs`; chỉ
  `nvmtl_translate` là bắt buộc (`NVMTLLibraryLoad.m:112, 140`).

## 6. Ngoài phạm vi (chưa làm, cần duyệt riêng)

- Thay binary trong `/Library/GPUBundles/NVMTLDriver.bundle`: cần sudo, sao lưu bundle, ký lại (thay binary làm hỏng chữ ký
  bundle nếu bundle đang được ký), khởi động lại WindowServer/đăng xuất; có kế hoạch hoàn tác. Không làm ở đây.
- Thí nghiệm cấu hình build (giả thuyết, cần đo trên máy thật): plugin `-O2` thay `-O1` (E4); NVK với `-Db_ndebug=true`
  (E3, xem `findings.md` F18). Cả hai đổi binary đã cài nên cần duyệt riêng.
