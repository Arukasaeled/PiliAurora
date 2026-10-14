# PiliAurora 图标字体

Copyright (c) 2026 wallpap。许可与来源说明见 [NOTICE](NOTICE)，随项目按 [GPL-3.0-only](../../../LICENSE) 分发。

## 集中维护

- `*.svg`：32 个图标的维护源稿，采用 24 × 24 网格、1.8px 圆角描边。
- [`manifest.json`](manifest.json)：功能名称、SVG 文件、Unicode 私用区编号，以及字体名称、版本、版权与许可证。已有字形编号保持稳定，保留原未使用的 `0xe804` 空位。
- [`build_font.py`](build_font.py)：将描边展开为轮廓、合并填充，生成字体和 Dart 常量。
- [`piliaurora_icons.ttf`](../../../assets/fonts/piliaurora_icons.ttf)：应用打包的单个 TrueType 字体。
- [`custom_icon.dart`](../../../lib/common/widgets/custom_icon.dart)：生成的 `CustomIcons` 定义，页面继续使用 `Icon(CustomIcons.dm_on)` 等调用。

字体中的版权、作者、许可证名称和许可证链接由映射表写入 OpenType `name` 表。每份 SVG 同时保留版权与 SPDX 标识。

## 重新生成

从仓库根目录运行：

```powershell
uv run tool/artwork/icons/build_font.py
```

脚本通过 PEP 723 声明固定版本的开发工具：FontTools 4.67.0（MIT，[来源](https://github.com/fonttools/fonttools)）与 skia-pathops 0.9.2（BSD-3-Clause，[来源](https://github.com/fonttools/skia-pathops)）。uv 将它们安装到隔离的工具缓存；Flutter 应用不增加运行依赖。

修改现有图标时编辑对应 SVG；新增图标时在 `manifest.json` 中增加条目并分配新的私用区编号，再执行生成命令。生成字体固定创建和修改时间，相同源稿可重复生成相同字节。

一致性检查可将产物导出到临时目录后比较：

```powershell
uv run tool/artwork/icons/build_font.py --output build/icon-font-check
```

`test/common/widgets/custom_icon_test.dart` 从实际字体加载所有字形，与 SVG 源稿对比渲染轮廓，同时检查字形映射及主题颜色、尺寸、选中和禁用状态。
