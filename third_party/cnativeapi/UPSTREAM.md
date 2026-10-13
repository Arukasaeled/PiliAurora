# 来源与本地修改

- 上游 cnativeapi 0.3.0；主仓库 v0.3.0 提交为 `32ab4edc828d51094a3d87e0b04aff6abf815a73`，目录 `packages/cnativeapi`。
- 源码从已锁定的 pub.dev 包复制，其归档 SHA-256 为 `43fce94bdf2f60e15bb7b0ef7b78b60fc0758e5463817fa17c5fb59f149566dd`；内含 nativeapi 源码与许可证一并保留。
- 本地版本 `0.3.0+piliaurora.2`；移除 workspace resolution，设置 publish_to: none。
- Windows x64 默认使用 `../nativeapi/prebuilt/` 中的 C ABI DLL；nativeapi 静态链接在 DLL 内。其他架构及 WinUI3 配置继续使用上游源码构建。
- 按项目支持范围保留 Android/Windows 插件与平台源码；移除 iOS、macOS、Linux 插件目录和内部 iOS、macOS、Linux、OHOS 实现，插件声明同步收窄。共享代码与上游 CMake 中的其他平台分支保留，未修改 C/C++ 接口和 Dart 绑定。示例、上游测试和开发缓存未纳入。
