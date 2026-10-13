# media_kit_libs_windows_video 本地版本

- 本地版本：`1.0.10+piliaurora.2`；来源包版本：`1.0.10`。
- 来源仓库：https://github.com/My-Responsitories/media-kit.git
- 来源提交：`73771ec38176be2d984a3049c28177bce23b54a0`。
- 来源子目录：`libs/windows/media_kit_libs_windows_video`。
- 许可证：LICENSE。
- 保留原因：接入仓库内含 D3D11/EGL 与语言修复的 mpv 预编译包、固定源码及运行库校验。

Windows 各构建模式使用 `third_party/mpv/` 的固定源码，构建含 mpv #18603/#18604 修复的运行库。预编译交付包保存在 `third_party/mpv/prebuilt/`；本地与 CI 构建见[mpv 说明](../mpv/README.md)。原 `20260819` 归档及旧临时 DLL 的验证保留为[历史记录](LOCAL_LIBMPV.md)。

仅收录生产源码、构建配置、资源及许可说明；不复制上游示例、测试、缓存或 Git 元数据。
导入时除包版本、禁止发布声明及必要依赖声明外，不重写来源实现。
这些包不是 pub.dev 同名版本的镜像，不可仅修改根版本号宣称已升级。
更新流程见 `../README.md`，来源登记见 `../dependencies.json`。
