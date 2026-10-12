# PiliAurora

[![GitHub Release](https://img.shields.io/github/v/release/wallpap/PiliAurora?display_name=tag)](https://github.com/wallpap/PiliAurora/releases/latest)
[![License](https://img.shields.io/github/license/wallpap/PiliAurora)](LICENSE)

基于 [PiliPlus 2.1.5](https://github.com/bggRGjQaUbCoE/PiliPlus/tree/2.1.5) 继续开发的 Bilibili 第三方客户端，使用 Flutter 编写，主要维护 Android 和 Windows x64。

[下载](https://github.com/wallpap/PiliAurora/releases/latest) · [更新日志](doc/releases/v1.2.0.md) · [问题反馈](https://github.com/wallpap/PiliAurora/issues) · [许可证](LICENSE)

## 项目特点

- 继承 PiliPlus 的内容浏览、视频与直播、互动、账号管理、收藏、历史和离线下载等客户端功能。
- 聚焦 Android 与 Windows x64 播放体验，维护跨平台播放器、视频输出和弹幕渲染。
- 对播放状态、缓存和渲染工作设置边界，降低资源占用并改善高负载播放场景。

## 与 PiliPlus 2.1.5 的差异

以下列出 PiliAurora 基于上游版本持续维护的代表性改进，完整功能变更见各版本发布说明。

### 桌面播放

- Windows 视频和直播可弹出多个独立播放窗口，支持置顶、拖动、缩放、网格或层叠排列，并可分别调节音量和选择声音来源。
- Windows 播放器增加桌面音量滑块、静音、键盘和滚轮调节；窗口位置和大小可在关闭后恢复。
- Windows 优先使用 D3D11 硬件解码并通过共享纹理输出；设备支持时可降低 CPU 解码负载，不支持或初始化失败时可回退到其他解码路径。

### 播放、纹理与解码

- 视频输出尺寸按显示区域限制，避免为超出显示能力的画面创建过大的输出纹理；Android 可选启用实验性的屏幕分辨率缩放，默认关闭。缩小输出 Surface 会降低纹理和渲染链路的内存开销；Android 视频仍按源分辨率解码。
- Android 针对 MediaCodec、Surface 和图像输出错误增加有界恢复与解码回退，减少播放异常后持续卡顿或失去画面的情况。
- 视频与直播播放会话按页面和请求代次隔离，快速切源时复用播放器资源，避免过期请求或回调改写当前播放状态。
- 音视频地址支持按需尝试备用 CDN，网络读取中断时结合当前媒体和缓冲状态恢复播放。

### 弹幕与内存占用

- Windows 弹幕使用预处理渲染器，复用文字布局、轨迹和栅格图片，并为缓存与活动工作集设定容量预算，减少逐帧重复布局和图片生成。
- 视频输出、弹幕图片缓存和活动对象均采用资源控制。相同设备和播放场景下，PiliAurora 的整体内存占用要明显低于原版 PiliPlus；实际消耗会随分辨率、弹幕数量、硬件和同时播放的窗口数变化。
- 直播消息解析复用后台 worker，弹幕数据按分段和条目数限界缓存，减少长时间播放中的任务与对象堆积。

### 其他功能改进

- Android 改进屏幕旋转、视频输出尺寸同步、硬件解码错误恢复和网络异常恢复。
- 增加下载音质选择、分集间字幕状态继承、直播表情弹幕和失效订阅清理等体验改进。
- GitHub Release 提供 Android 分 ABI APK，以及 Windows x64 便携包和安装程序。

实际表现受系统版本、设备、驱动、媒体编码、清晰度、弹幕设置和播放窗口数量影响。纹理输出尺寸优化主要降低渲染目标和纹理开销；硬件解码路径是否生效取决于设备支持。

## 适配平台

- Android：`arm64-v8a`、`armeabi-v7a`、`x86_64`
- Windows x64

从 [GitHub Releases](https://github.com/wallpap/PiliAurora/releases/latest) 下载对应平台的安装包。PiliAurora 使用独立的应用标识和数据目录，可以与 PiliPlus 并存；两个应用不会自动共享账号状态、设置、缓存或离线文件。

## 功能概览

- **内容浏览：** 首页推荐、热门、排行榜、视频、番剧、文章、音频、直播和搜索。
- **播放：** 清晰度和音质选择、播放速度、硬件解码设置、弹幕、字幕、分集切换和播放记录。
- **互动：** 评论、动态、关注、粉丝、私信和直播聊天。
- **账号与内容管理：** 多账号、收藏夹、观看历史、稍后再看、番剧订阅和离线下载。
- **扩展能力：** DLNA 投屏、WebDAV 设置备份、SponsorBlock 和 WebView。

功能受 Bilibili 接口、账号权限、平台和具体媒体资源影响。

## 从源码构建

项目使用 [.fvmrc](.fvmrc) 固定 Flutter 版本。Android 构建需要 Android SDK 和 JDK 25；Windows 构建需要安装启用了“使用 C++ 的桌面开发”工作负载的 Visual Studio。详细环境要求、平台构建和测试命令见[构建与测试](doc/build-and-test.md)。

```powershell
git clone https://github.com/wallpap/PiliAurora.git
cd PiliAurora
fvm install
pwsh -File tool/build.ps1 -Platform windows -Mode debug
pwsh -File tool/build.ps1 -Platform android -Mode debug
```

## 项目文档

- [文档索引](doc/README.md)
- [功能领域地图与性能说明](doc/features.md)
- [Windows 独立播放窗口](doc/windows-playback-windows.md)
- [架构说明](doc/architecture.md)
- [运行流程图](doc/runtime-flows.md)
- [构建与测试](doc/build-and-test.md)
- [维护与排障](doc/maintenance.md)
- [第三方依赖及许可证](third_party/README.md)

## 参与贡献

欢迎通过 GitHub Issues 报告问题或提交 Pull Request。修改播放器、弹幕或平台代码前，请先阅读[维护与排障](doc/maintenance.md)和[构建与测试](doc/build-and-test.md)；修改第三方依赖时，按[依赖维护说明](third_party/README.md)登记来源和许可证。

## 问题反馈

请在 [GitHub Issues](https://github.com/wallpap/PiliAurora/issues) 提交问题，附上系统、设备、应用版本、复现步骤和相关页面。播放问题请补充视频编码、清晰度、弹幕设置和硬件解码状态。分享日志前，请移除 Cookie、Token、二维码登录信息和其他账号数据。

## 声明

PiliAurora 是社区独立维护的第三方客户端，与 Bilibili 官方无隶属关系，也未获得其背书。项目使用公开接口，不提供破解内容。使用时请遵守 Bilibili 服务条款及适用法律。Bilibili 名称、商标及相关内容归其权利人所有。

## 致谢

- [PiliPlus](https://github.com/bggRGjQaUbCoE/PiliPlus)：本项目直接基于其 2.1.5 版本继续开发。
- [PiliPalaX](https://github.com/orz12/PiliPalaX) 与 [PiliPala](https://github.com/guozhigq/pilipala)：PiliPlus 的上游项目及历史来源。
- [My-Responsitories](https://github.com/My-Responsitories) 及所有为上游项目和 PiliAurora 作出贡献的开发者。
- Flutter、media_kit、Dio 及其他开源依赖的作者和维护者。

上游源码保留原有版权与许可声明。依赖和移植组件的来源、版权与许可证见 [`third_party/README.md`](third_party/README.md) 及对应组件文件。

## 许可证

本项目采用 [GNU General Public License v3.0](LICENSE)。第三方组件遵循各自的许可证。
