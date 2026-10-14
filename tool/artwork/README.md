# 应用视觉资源

2026-10-14 更新。应用图标使用用户提供的银白发角色，由内置 imagegen 重绘为蓝紫背景的头像构图。其余资源以石墨灰、灰蓝和暖米色为主体，直播与会员标识使用少量低饱和玫瑰色。应用主题配色沿用用户设置。

| 资源 | 应用路径 | 源稿 / 导出 |
| --- | --- | --- |
| 图片占位 / 头像 / AI 总结 | `assets/images/loading.png`、`noface.jpeg`、`ai.png` | `loading.svg`、`avatar.svg`、`ai.svg` |
| 空状态 / 话题背景 | `assets/images/error.svg`、`topic-header-bg.png` | `error.svg`、`topic-header.svg` |
| 热搜横幅 | `assets/images/trending_banner.png` | 内置 imagegen，1125 × 528，PNG |
| 直播默认背景 | `assets/images/live/default_bg.webp` | 内置 imagegen，1125 × 2436，WebP |
| 应用图标 / 单色标记 | `assets/images/logo/logo.png`、`logo_2.png` | `raster/app-icon.png`、`logo-mark.svg`，512 × 512 |
| 会员标识 | `assets/images/big-vip.svg` | `vip.svg`，64 × 64 |
| 播放图标 | `assets/images/play.png` 及 2× / 3× / 4× 变体 | `tool/generate_play_icon.dart` |
| 播放中指示 | `assets/images/live.gif`、`live.png` | `export.py`，36 × 36 |
| 直播徽章 | `assets/images/live/live.gif` | `export.py`，135 × 42 |
| 播放器缓冲 | `assets/images/loading.webp` | `export.py`，72 × 72 |
| 投币静态预览与空币槽 | `assets/images/paycoins/ic_22_*.png` | `coin_motion.py`，360 × 260；沿用历史文件名 |
| 单币 / 双币抛投 | `assets/images/paycoins/coin_toss_one.gif`、`coin_toss_two.gif` | `raster/coin.png` + `coin_motion.py`，360 × 260 |
| 选择硬币、投币盒、箭头、关闭 | `assets/images/paycoins/*.png` | `raster/coin.png`、`raster/coin-box.png`、`paycoins/*.svg` |
| Android 快捷方式 | `android/app/src/main/res/drawable/ic_shortcut_*.png` | `shortcut-search.svg`、`shortcut-download.svg` |
| Android 桌面图标、启动图 | `android/app/src/main/res/mipmap-*/ic_launcher.png`、`drawable-*/splash.png` | `export.py` |
| Windows 应用及托盘图标 | `windows/runner/resources/app_icon.ico`、`assets/images/logo/ico/app_icon.ico` | `export.py`，16 至 256 px 共 7 档 |

投币区使用硬币与币槽，去掉角色。点击或上滑播放一次抛投 GIF：硬币上抛、翻转、缩小落入槽口，双币版增加第二枚并延后出手 100ms。24 个采样帧间隔 40ms，GIF 编码合并相同的起始停留帧，当前编码为 22 帧，总时长 960ms。省略循环扩展，完成后停在落币帧。页面从首帧显示开始计时，随后关闭并调用原投币回调；播放中锁定金额，每次打开使用独立 MemoryImage 重播，中途关闭取消提交。余额限制、原创视频的金额范围和同时点赞设置沿用现有规则。

热搜标题由 Flutter 文本叠加；横幅高度随标题排版调整，避免系统大字号与顶部导航重叠。话题背景是透明装饰，适配明暗主题表面。播放图标继续采用 60px 逻辑尺寸、四周 12px 阴影边距的约定；卡片底板不透明度为 36%，反光、边框和阴影同步减弱，播放三角保持清晰。

Android 普通自适应前景使用 `drawable-nodpi/app_icon_artwork.png`，108dp 前景中心 72dp 放入完整头像，其余区域保留遮罩与视差余量；系统负责圆形或方圆裁切。`ic_launcher_monochrome.xml` 使用角色蝴蝶结与菱形饰件构成的单色标记，供系统主题图标着色；应用内需要颜色滤镜的 `logo_2.png` 共用该标记。Windows ICO、传统 Android 图标和明暗启动图使用圆角头像版本。

`assets/screenshots/` 是已有产品截图，未作为应用插画重绘。字体和 shader 是运行资源，未纳入本次视觉替换。

## 重新导出

在仓库根目录使用项目固定 Flutter 和已有 Python / Pillow：

```powershell
fvm flutter test --no-pub tool/generate_app_artwork.dart tool/generate_play_icon.dart
python tool/artwork/export.py
```

第一条命令从 SVG / Dart 源稿生成位图、同步空状态、会员和 Android 单色 SVG/Vector。头像的中间 PNG 放在 `build/asset-refresh/avatar.png`。第二条命令从图标原稿导出应用 Logo、头像 JPEG、投币与直播动画、Android 桌面与启动资源、Windows ICO。需要先执行第一条命令；导出完成后可删除 `build/asset-refresh/`。

直播徽章文字默认由本机微软雅黑 `C:/Windows/Fonts/msyh.ttc` 渲染；其他开发环境通过 `--font <中文字体路径>` 指定字体。直播指示与缓冲动画为 24 帧、每帧 50ms。GIF 使用统一透明索引并逐帧替换，缓冲 WebP 保留半透明边缘。

重新生成背景后，传入内置 imagegen 返回的原稿：

```powershell
python tool/artwork/export.py --live <直播原稿.png> --trending <热搜原稿.png>
```

背景按原资源比例缩放并居中裁剪，直播 WebP quality=85。省略背景参数时保留当前背景。最终资源均已保存在项目中，应用运行不依赖生成工具。

## imagegen 提示词

应用图标以用户给定的角色图为参考，硬币与投币盒沿用前一轮生成原稿；三份实际提示词见 [`imagegen-prompts.json`](imagegen-prompts.json)。均使用内置 imagegen，未使用 CLI / API。以下两张背景未传入参考图，保留其完整提示词。

### 直播默认背景

```text
Use case: stylized-concept
Asset type: understated production background for PiliAurora Flutter live room, portrait aspect 1125:2436.
Primary request: a calm, almost monochrome abstract night background with soft aurora-like folds, a substantial revision of an overly green visual system. Restrained and plain colors are the goal.
Scene/backdrop: charcoal and ink grey, with a quiet slate-blue veil and one faint warm stone-grey ribbon drifting through the lower half. Large smooth tonal areas, very little texture, a few tiny stars at most.
Composition/framing: tall 9:19.5, full bleed. Top 40 percent very dark and empty for video and navigation. Center quiet for chat. Soft folds run along edges and lower third, no bright focal point.
Style/medium: subtle atmospheric abstract artwork, matte and soft. No glossy sci-fi effects.
Color palette: #10151D, #202934, #394553, #697483; a very small warm-grey #9B9184 accent. Low saturation throughout. No green, purple or vivid cyan.
Constraints: background asset only, no device, no text, no logos, no watermarks, no landscape, no human figures, no border. Chat overlay readability matters. Avoid strong glow and complicated detail.
```

### 热搜横幅

```text
Use case: stylized-concept
Asset type: actual background artwork for PiliAurora trending-search page, landscape 1125:528 (2.13:1).
Primary request: a quiet neutral editorial banner with a simple magnifying glass on the right, warm grey and slate tones, spacious composition. Revise an excessively green glossy banner into restrained, plain, low-saturation artwork.
Scene/backdrop: left half is dark warm charcoal with a smooth matte gradient, subtly lighter towards the right. One gentle paper-like curve in pale stone grey passes low on the right. One large magnifying glass with a smoked glass lens and brushed warm-silver rim occupies the right third. Very simple object, soft diffused studio lighting, a restrained tiny beige dot nearby.
Composition/framing: horizontal 2.13:1. Left 55 percent quiet and dark enough for a white title, top 25 percent quiet for navigation. Complete magnifying glass on the right, no cropped handle. Only a few shapes.
Style/medium: elegant minimal abstract still life, matte surfaces, very restrained depth. Avoid shiny liquid chrome, blinding glints, starbursts and ornament.
Color palette: #2C2E33, #4B4B4D, #7C7B78, #BCB6AC, #DED8CF. Small slate-grey glass reflection. No green, no purple, no saturated colors.
Constraints: background asset only, absolutely no text, letters, numbers, logos, border, watermark, device or mockup. The app adds actual text on top.
```
