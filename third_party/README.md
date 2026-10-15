# 本地定制依赖

Dart/Flutter 依赖已停止跟踪远端 Git 分支。普通依赖固定到 pub.dev 的发布版本，解析结果保存在 `pubspec.lock` 中；需要定制的实现放在本目录，随应用源码维护。

## 本地实现与包登记

按标签节流、尾沿防抖、UUID v4、应用日志和设置 WebDAV 传输由项目维护；图片缓存接口包已合并回主包。当前本地包登记为 19 个；合并来源继续登记和保留许可证。范围、真实依赖减少量及验证见 [SIMPLIFICATION.md](SIMPLIFICATION.md)。

## 版本与来源

- `dependencies.json` 是本地包的登记表，记录本地版本、来源版本、仓库、完整提交 SHA、来源子目录、许可证和保留原因。
- 根 `pubspec.yaml` 的直接定制依赖使用精确版本（例如 `1.1.11+piliaurora.1`），`dependency_overrides` 将实际源码指向本目录。传递定制包也必须登记和 override。
- 每个本地包的 `pubspec.yaml` 使用独立的 `+piliaurora.N` 修订号，并设置 `publish_to: none`。这些包包含本地修改，与同名 pub.dev 版本有所区别。
- 根版本声明本身不能约束 path override；`fvm dart run tool/check_dependencies.dart` 会检查登记、本地声明和锁文件的一致性，并拒绝任何 Git 来源。
- 每个包保留原许可证和来源版权信息。新导入包收录生产源码、构建配置和必要资源，不收录上游示例、测试、开发缓存及 Git 元数据。本地补丁和修订记录保存在各包的 `UPSTREAM.md`；包内上游 README、CHANGELOG 和许可证保留原始用途。

## 更新流程

### 普通发布依赖

根 `dependencies` 和 `dev_dependencies` 的 hosted 包统一使用精确版本号，不使用 `^`、区间或 `any`；根 hosted override 也遵循相同规则。版本以已验收的 `pubspec.lock` 为准，不会自动跟随最新发布版。SDK 包由 `.fvmrc` 管理，第三方包传递解析结果由锁文件和 `--enforce-lockfile` 固定。

1. 修改目标包的精确版本号，再执行 `fvm flutter pub get` 解析目标版本。
2. 审核 `pubspec.lock`，避免无关依赖更新；依赖校验必须确认根声明和锁定版本逐字一致，包括预发布与 build 后缀。
3. 执行依赖检查、相关测试和对应平台构建后，一起提交声明与锁文件。

### 本地定制包

1. 核对登记中的上游仓库、提交和子目录，在独立临时目录取新源码；不要直接从浮动分支覆盖本目录。
2. 审查上游差异并移植仍需要的本地修改。保留所有许可及版权说明，核对资源和原生库校验值。
3. 递增 `+piliaurora.N`（有上游升级时同时更改基础版本），同步根直接依赖版本、登记和包的 `UPSTREAM.md`。不要只改根版本号而保留旧源码。
4. 如该包仅为传递依赖，仍需更新本地版本和登记；根 override 不得遗漏。
5. `fvm flutter pub get`，然后按改动平台运行：

   ```powershell
   fvm dart run tool/check_dependencies.dart
   fvm flutter analyze --no-pub lib test tool
   fvm flutter test --no-pub
   fvm flutter build windows --debug --no-pub
   fvm flutter build apk --debug --no-pub
   ```

6. 将单个更新及其适配、测试作为可独立回滚的提交。新版本若可以去掉定制，则切回已验证的发布版，并同时移除 override、本地源码和登记。

平台构建覆盖编译和打包，后台通知、GPU/MediaCodec、窗口主题和 WebView 退出由人工实机回归覆盖。`third_party` 的上游检查告警如实记录，不靠关闭检查或削弱测试来清零。

## 原生二进制与 SDK

Windows 各构建模式使用 [mpv 预编译包](mpv/README.md)。源码、重建脚本、许可与 `prebuilt/` 中的归档和摘要均纳入 Git；工具链、编译缓存与解压目录保存在 `build/`。应用 CI 直接校验并使用预编译包，独立原生库工作流负责从固定源码重建。打包收集 libmpv、ANGLE 的 DLL 依赖闭包，并随应用交付许可与包来源记录。

Android 原生库继续使用版本化下载地址与 SHA-256 校验。mpv 属于原生构建材料；`dependencies.json` 仍登记 19 个本地 Dart/Flutter 包。

Windows x64 的 cnativeapi 使用 [预编译入口](nativeapi/README.md)，内部 nativeapi 已静态链接。固定的 cnativeapi 0.3.0 源码保留在本地包中，重建产物位于 `nativeapi/prebuilt/`，许可随应用分发。

Flutter SDK 与 `material_ui` 补丁由 `lib/scripts/patch.ps1` 管理，构建脚本按实际依赖解析路径应用补丁，详见[工具入口](../tool/README.md#平台构建)。

## 历史记录

- [首次迁移验收](VALIDATION.md)：2026-10-07 的来源迁移与验证。
- [依赖精简与内化](SIMPLIFICATION.md)：随后各阶段的实现取舍、数量变化和验证。

记录中的包数、版本和测试结果对应各阶段基线；当前版本以登记、包清单与锁文件为准。
