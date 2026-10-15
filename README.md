# PiliAurora

[![GitHub Release](https://img.shields.io/github/v/release/wallpap/PiliAurora?display_name=tag)](https://github.com/wallpap/PiliAurora/releases/latest)
[![License](https://img.shields.io/github/license/wallpap/PiliAurora)](LICENSE)

PiliAurora 是基于 [PiliPlus 2.1.5](https://github.com/bggRGjQaUbCoE/PiliPlus/tree/2.1.5) 继续开发的 Bilibili 第三方客户端，使用 Flutter 编写，目前面向 Android 和 Windows x64。项目保留上游的内容浏览、播放、互动与账号管理能力，并将持续维护重点放在两端的播放体验、弹幕和 Windows 桌面播放场景,相较于原版具有更低占用,更高性能,并开发了额外的功能,进行了多种优化以降低资源使用(尤其是Windows方面,内存,cpu占用等全面大幅降低)。

[下载](https://github.com/wallpap/PiliAurora/releases/latest) · [更新日志](doc/releases/v1.4.4.md) · [问题反馈](https://github.com/wallpap/PiliAurora/issues) · [许可证](LICENSE)

## 与上游的关系

PiliAurora 以 PiliPlus 2.1.5 为开发起点，在本仓库独立维护。上游基线列出 Android、iOS、Pad、Windows 和 Linux；PiliAurora 当前发布 Android 与 Windows x64 版本。两端使用独立的应用标识和数据目录，可以与 PiliPlus 并存；账号状态、设置、缓存和离线文件不会自动共享。

## 项目特点

- Windows 视频和直播可弹出为多个独立窗口，支持置顶、拖动、缩放、网格或层叠排列；窗口位置和大小会在关闭后恢复。每个窗口可以分别调节音量，也可以切换声音来源，主窗口则可继续浏览其他内容。
- Windows 播放优先尝试 D3D11 硬件解码和共享纹理输出；设备不支持或初始化失败时会尝试其他路径。视频输出尺寸按显示区域限制，Android 可选启用实验性的屏幕分辨率缩放，默认关闭。Android 针对 MediaCodec、Surface 和图像输出错误加入有界恢复与解码回退。
- 视频与直播播放会话按页面和请求代次隔离，快速切源时复用播放器资源，避免旧请求或回调改写当前播放状态。播放地址可按需尝试备用 CDN；网络读取中断时会结合当前媒体和缓冲状态恢复。
- Windows 弹幕渲染复用文字布局、轨迹和栅格图片，并为缓存和活动工作集设定容量预算。视频弹幕可合并 20 秒内相同或相似的内容、按重复数量放大字号，更新节奏可设为跟随屏幕或 30、60、90、120 FPS，设置入口见[弹幕合并与帧率设置](doc/danmaku-merge.md)。直播消息解析复用后台 worker，弹幕数据按分段和条目数限界缓存。
- 主页与消息入口共享未读状态；回复、@、点赞、系统通知和私信按主账号管理，切换账号后丢弃旧账号的在途响应。会话操作同步共享状态，聊天历史按消息标识去重，并使过期分页结果失效。私信支持文本、图片和分享卡片；分享卡片与附言共用发送锁，结果待确认时保留草稿并提示核对聊天记录，卡片和附言的发送结果分别反馈。模块说明见[消息模块说明](lib/services/messaging/README.md)。
- 其他持续改进包括下载音质选择、分集间字幕状态继承、直播表情弹幕、失效番剧订阅清理，以及可自定义颜色的高能进度条。

输出尺寸限制主要减少渲染表面和纹理开销，不会改变源视频的解码分辨率。Android 的屏幕分辨率缩放属于实验性选项，默认关闭。实际播放表现受系统版本、设备、驱动、媒体编码、清晰度、弹幕设置和播放窗口数量影响；硬件解码路径也取决于设备支持。

## 适配平台与下载

- Android：`arm64-v8a`、`armeabi-v7a`、`x86_64`
- Windows x64

从 [GitHub Releases](https://github.com/wallpap/PiliAurora/releases/latest) 下载对应平台的安装包。Android 提供分 ABI APK；Windows 提供便携包和安装程序。

## 功能概览

- 内容浏览：首页推荐、热门、排行榜、视频、番剧、文章、音频、直播和搜索。
- 播放：清晰度和音质选择、播放速度、硬件解码设置、弹幕、字幕、分集切换和播放记录。
- 互动：评论、动态、关注、粉丝、消息通知、私信和直播聊天。
- 评论长按菜单支持拉黑用户；表情包可按分类添加、移除和预览，详见[评论与表情包](doc/comments-and-emotes.md)。
- 账号与内容管理：多账号、收藏夹、观看历史、稍后再看、番剧订阅和离线下载。
- 扩展能力：DLNA 投屏、WebDAV 设置备份、SponsorBlock 和 WebView。

功能受 Bilibili 接口、账号权限、平台和具体媒体资源影响。

## 从源码构建

项目使用 [.fvmrc](.fvmrc) 固定 Flutter 版本。Android 构建需要 Android SDK 和 JDK 25；Windows 构建需要启用了“使用 C++ 的桌面开发”工作负载的 Visual Studio。Windows 使用仓库内的 [mpv 预编译包](third_party/mpv/README.md)，本地构建和 GitHub Windows CI 都会校验并解压；更新原生库时可从固定源码重建。环境要求与验证命令见[构建与测试](doc/build-and-test.md)。

```powershell
git clone https://github.com/wallpap/PiliAurora.git
cd PiliAurora
fvm install
pwsh -File tool/build.ps1 -Platform windows -Mode debug
pwsh -File tool/build.ps1 -Platform android -Mode debug
```

## 项目文档

[文档索引](doc/README.md)提供使用说明、开发与排障指南及版本记录。常用文档：

- 使用：[弹幕设置](doc/danmaku-merge.md)、[Windows 独立播放窗口](doc/windows-playback-windows.md)。
- 开发：[构建与测试](doc/build-and-test.md)、[功能领域地图](doc/features.md)、[架构](doc/architecture.md)。
- 排障：[维护指南](doc/maintenance.md)、[Windows 视频输出](doc/windows-video-output.md)、[消息模块](lib/services/messaging/README.md)。

## 参与贡献

欢迎通过 GitHub Issues 报告问题或提交 Pull Request。修改播放器、弹幕或平台代码前，请阅读[维护与排障](doc/maintenance.md)和[构建与测试](doc/build-and-test.md)；修改第三方依赖时，请按[依赖维护说明](third_party/README.md)登记来源和许可证。

## 问题反馈

请在 [GitHub Issues](https://github.com/wallpap/PiliAurora/issues) 提交问题，并附上系统、设备、应用版本、复现步骤和相关页面。播放问题请补充视频编码、清晰度、弹幕设置和硬件解码状态。分享日志前，请移除 Cookie、Token、二维码登录信息和其他账号数据。

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
