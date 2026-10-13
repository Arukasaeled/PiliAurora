# 工具入口

从仓库根目录运行各命令。工具按用途分组：

| 位置 | 用途 |
| --- | --- |
| `build.ps1`、`jnigen.dart` | 平台构建与 JNI 生成，保留稳定入口。 |
| `run-ci-tests.ps1` | 本地运行 GitHub Actions 选择的测试文件。 |
| `check_dependencies.dart` | 依赖版本、来源和许可证验收。 |
| [`probes/`](probes/README.md) | Android、Windows、播放链路和事件循环的隔离回归探针。 |
| [`experiments/`](experiments/README.md) | 按业务领域组织的按需对照与性能测量。 |

默认自动化测试位于 [`test/`](../test/README.md)，测试选择方式见[构建与测试说明](../doc/build-and-test.md)。

## 本地 CI 测试

依赖已准备后，在仓库根目录运行与 GitHub Actions 相同的测试文件：

```powershell
pwsh -NoProfile -File tool/run-ci-tests.ps1
```

`run-ci-tests.ps1` 默认使用 FVM，只通过 `flutter test --no-pub` 执行 GitHub Actions 选择的测试文件，覆盖依赖政策、诊断、消息、设置、弹幕及播放恢复等模块；文件清单以脚本中的 `$ciTests` 为准。依赖需预先准备；脚本不解析或安装依赖、不修改 Flutter SDK、不应用补丁，也不构建应用。GitHub Actions 由补丁步骤统一解析一次依赖，随后直接运行依赖验收工具并调用同一测试脚本；测试和构建阶段均使用 `--no-pub`。

## 平台构建

Windows 构建使用[仓库内的 mpv 预编译包](../third_party/mpv/README.md)，构建脚本自动校验和解压。工具链要求见[构建与测试](../doc/build-and-test.md)。

项目使用 `.fvmrc` 指定的 Flutter 版本。安装 Android SDK 或 Visual Studio 后，在仓库根目录运行：

```powershell
pwsh -File tool/build.ps1 -Platform windows -Mode debug
pwsh -File tool/build.ps1 -Platform android -Mode debug
```

Android 默认构建包含所有受支持的 ABI。可通过 `-Abi` 只构建一种架构，减少 APK 中的原生库体积：

```powershell
pwsh -File tool/build.ps1 -Platform android -Mode release -Abi arm64-v8a
```

支持 `armeabi-v7a`、`arm64-v8a` 和 `x86_64`。省略 `-Abi` 时保持通用 APK；指定 Windows 平台和 `-Abi` 会报错。

构建脚本统一执行一次 `pub get --enforce-lockfile`，随后检查并补齐补丁、验收依赖来源，最后通过 `--no-pub` 构建。已应用的补丁会复用；切换到 Windows 时会移除项目的 Android 专用补丁。补丁目标按 `.dart_tool/package_config.json` 的实际解析结果定位。

常规输出显示准备步骤的汇总和构建进度。使用 `-Verbose` 可查看完整依赖解析输出和逐项补丁状态；步骤失败时会显示错误详情。依赖声明和锁文件未改动、依赖已准备时，可传入 `-SkipPubGet`；补丁已准备时，可再传入 `-SkipPatch`：

```powershell
pwsh -File tool/build.ps1 -Platform windows -Mode debug -SkipPubGet -SkipPatch
```

CI 直接调用 `lib/scripts/patch.ps1` 时，补丁脚本会先准备依赖；调用方已执行依赖解析时可传入 `-SkipPubGet`。

重新生成 Android JNI bindings：

```powershell
fvm dart run tool/jnigen.dart
```

## Python 工具环境

Python 探针使用根目录的 `.python-version`、`pyproject.toml` 和 `uv.lock` 管理环境。首次准备环境时，在仓库根目录运行：

```powershell
uv python install 3.14
uv sync --locked
```

之后用 `uv run --locked python ...` 启动 Python 探针。Pillow 是截图检查所需的唯一第三方 Python 工具依赖；其余探针只使用 Python 标准库。

## 原生与设备验证

媒体加载、独立音轨、跳转、旋转、纹理首帧和超分切换的运行命令集中在[平台探针](probes/README.md)。探针分别使用模拟对象、原生库或测试设备，运行前按入口说明准备输入文件与输出目录。

## 依赖版本与来源检查

```powershell
fvm dart run tool/check_dependencies.dart
fvm flutter test --no-pub test/architecture/dependency_policy_test.dart test/common/widgets/font_awesome_icons_test.dart
```

该工具只读工作区，检查 Git 来源、path 范围、来源 SHA、许可证、版本登记与锁文件，并核对合并依赖的目录和许可证信息。可用位置参数指定工作区。普通依赖更新和定制包维护流程见 `third_party/README.md`。本地构建和 CI 会在依赖解析后执行检查，依赖解析使用 `--enforce-lockfile`。更新版本时先修改精确约束，再运行 `fvm flutter pub get` 并核对锁文件差异。

## 播放图标资源

播放图标的路径、透明度和模糊阴影源定义保存在 `tool/generate_play_icon.dart`。从仓库根目录重新生成 1×、2×、3×、4× PNG：

```powershell
fvm flutter test --no-pub tool/generate_play_icon.dart
```

产物为 `assets/images/play.png` 及同目录下的分辨率变体。图形逻辑尺寸为 60×60，四周各留 12 像素透明边距容纳阴影；`PlayIcon` 在布局时扣除该边距。修改源定义后需同步更新这四张资源。
