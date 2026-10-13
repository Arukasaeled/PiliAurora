# Windows libmpv 临时本地替换

2026-10-13 为 Windows x86_64 的 Debug、Profile、Release 构建接入必需的临时修复包，修复同样存在于正式版的 mpv 问题。等待上游修复进入可验收的固定发行归档后再替换这份临时补丁。

## 修复与来源

- [mpv #18603](https://github.com/mpv-player/mpv/pull/18603)：`video/out/opengl/hwdec_d3d11egl.c` 的 `uninit()` 在移除设备后调用 `av_buffer_unref(&p->hwctx.av_device_ref)`，再释放驱动自身的 D3D11 引用，解决渲染器销毁后设备仍存活的问题。
- [mpv #18604](https://github.com/mpv-player/mpv/pull/18604)：`osdep/language-win.c` 的 `apppend_langs()` 增加 `pos += wcslen(buf + pos) + 1`，正确遍历 Windows 多个首选界面语言。

本机源码位于 `E:/AIGC/allowed/mpv-pr18603/mpv-local`：从 #18603 提交 `8fa4c6877abe110a1c07f696ff3792f56b81ccf4` 的源码副本加入上述语言修复；父基线为 `c3ac7f39514c7f45bc38a18e66887240539ee33c`。未修改原有验证 checkout。

构建使用便携 MSYS2 UCRT64，GCC 16.2.0、Meson 1.12.1、Ninja 1.13.2、FFmpeg 9.0.2、libass 0.17.5、libplacebo 7.360.1、ANGLE 890b5d8f。配置为 `debugoptimized`、`--werror`，开启 libmpv、cplayer、tests、egl-angle、egl-angle-lib、egl-angle-win32、d3d-hwaccel 和 d3d11，关闭 PDF/manpage 生成。

合并修复 DLL SHA-256：`cfc7af7483a509826f5cc4e4b1033a597814d6f14ab97bc4cca57301cc65e536`。

## 本机启用与恢复

临时包位于仓库 `build/local-libmpv/`，包含合并修复的 `libmpv-2.dll`、`libmpv.dll.a`、`include/mpv/*.h` 及之前完整源码验证使用的配套动态 DLL；`SHA256SUMS` 固定每个文件的校验值。整个目录由 Git 忽略，其他机器不会自动获取它。

Windows CMake 要求该目录的 `SHA256SUMS` 存在，校验所有登记文件，将 mpv 头文件和导入库同步到构建目录，并打包该运行库集合。ANGLE 仍使用原有开发头文件与导入库，运行时采用本地包的配套 DLL。缺失或校验失败会终止配置，避免正式版构建回退到仍有泄漏的原归档。其他机器和 CI 需要先准备相同的临时包。

本机重新构建：

```powershell
fvm flutter build windows --debug --no-pub
fvm flutter build windows --release --no-pub
```

恢复固定发行归档前，应先取得包含两处修复的发行版本，更新 `libmpv.cmake` 的固定来源和校验值并移除临时包要求；重新构建时使用空的输出目录，避免临时包的动态 DLL 残留。当前 `20260819` 归档保留为历史来源，禁止自动回退。本次未修改 Dart 包版本、pubspec 或锁文件。

本次临时包的 FFmpeg、ANGLE 等依赖与原固定发行归档不同，临时替换范围包含配套原生运行库，正式版采用相同的修复包。跨机器构建所需的包分发及这些二进制的完整来源与许可证登记仍需补齐。Android 继续使用现有原生库。

## 验证

合并源码使用 `--werror` 完整编译通过；上游现有 Meson 测试以 `GGML_NO_BACKTRACE=1`、`-j8` 执行，37/37 通过。日志在 `E:/AIGC/allowed/mpv-pr18603/logs/{configure,build,tests}-local.log`。

本地包以 AV1 852×480、输出 1280×720、Anime4K 关闭/效率/质量/再次关闭四阶段（各 2 秒）进行六轮创建、播放、销毁：所有阶段使用 `d3d11va`，帧缓冲非均匀；每轮释放后设备引用均为 0，当前私有内存为 428.68、433.42、427.95、434.34、431.35、437.33 MiB。记录位于 `build/local-libmpv-validation/results.jsonl`。

`fvm flutter build windows --debug --no-pub` 通过；打包的 `build/windows/x64/runner/Debug/libmpv-2.dll` 与上述 SHA-256 一致。首次接入检查发现符号链接相对路径未命中临时包，已改为从插件真实路径定位；更换导入库时遇到 MSVC 增量链接器 LNK1000，将生成的 `.ilk` 缓存改名保留后重建成功。构建日志位于 `build/local-libmpv-windows-build.log`。

对最终应用输出目录另跑一轮相同播放探针，硬解、出帧与设备引用归零检查通过；记录在 `build/local-libmpv-packaged-validation-fixed/results.jsonl`，日志在 `build/local-libmpv-packaged-probe-fixed.log`。

正式版 `fvm flutter build windows --release --no-pub` 构建通过，`build/windows/x64/runner/Release/libmpv-2.dll` 与修复包 SHA-256 一致。正式版输出目录的播放探针通过硬解、出帧和设备引用归零检查。构建日志为 `build/local-libmpv-windows-release-build.log`，探针日志为 `build/local-libmpv-release-probe.log`，结果为 `build/local-libmpv-release-validation/results.jsonl`。

长时间播放、实际音频输出、更多 GPU/驱动、应用 UI 中反复开关播放页面与 Android 行为未包含在本次验证中。
