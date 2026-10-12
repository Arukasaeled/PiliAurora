# 运行流程图

## 应用启动

`main.dart` 调用 `bootstrapApplication()`。Windows 的 Cookie 同步会读取 WebView 环境，因此该环境要先于 `Request.setCookie()` 初始化。

```mermaid
sequenceDiagram
    participant OS as Android / Windows
    participant Boot as app/bootstrap.dart
    participant Local as 路径与本地存储
    participant Platform as 平台初始化
    participant Net as Request / Cookie
    participant App as Catcher2 / PiliAuroraApp

    OS->>Boot: main() → bootstrapApplication()
    Boot->>Boot: 初始化 Flutter binding 与 MediaKit
    Boot->>Local: 初始化应用支持目录
    Boot->>Local: 初始化 GStorage
    alt GStorage 初始化失败
        Local-->>Boot: 抛出错误
        Boot->>Boot: 记录错误并退出
    else 初始化成功
        Boot->>Boot: 设置 UI 缩放并初始化日志
        par 准备本地资源
            Boot->>Local: 下载目录
        and 准备其他本地资源
            Boot->>Local: 临时目录、缓存、字体
        end
        Boot->>Boot: lazy 注册 AccountService、DownloadService
        Boot->>Net: 安装全局 HTTP overrides
        Boot->>Platform: 初始化平台服务
        Note over Platform: Windows 创建 WebView 环境；Android 准备方向与服务定位
        Boot->>Net: 创建 Request、同步 Cookie 与历史状态
        Boot->>Platform: 初始化系统 UI 或桌面窗口
        Boot->>Boot: 按设置读取动态颜色
        Boot->>App: 安装异常处理并创建根 Widget
    end
    App->>App: 创建主题、GetMaterialApp 与路由表
```

`GStorage` 初始化失败时，应用记录错误后退出。下载路径、临时目录、缓存和字体并行准备，`AccountService` 与 `DownloadService` 通过 `lazyPut` 延迟创建。实现见 [`bootstrap.dart`](../lib/app/bootstrap.dart)、[`platform_setup.dart`](../lib/app/platform_setup.dart) 和 [`app.dart`](../lib/app/app.dart)。

## HTTP 请求

业务 API 使用 `Request` 创建的 Dio 客户端。HTTP/2 开启时配置 HTTP/1.1 fallback；重试、诊断和压缩响应转换由请求层处理。

```mermaid
sequenceDiagram
    participant Caller as 页面 / Service
    participant Api as 业务 API 模块
    participant Dio as Request / Dio
    participant Int as Retry / 诊断拦截器
    participant Adapter as HTTP/2 或 HTTP/1.1 adapter
    participant Remote as Bilibili / 第三方服务

    Caller->>Api: 请求业务数据
    Api->>Dio: get / post / download
    Dio->>Int: 请求与响应经过拦截器
    Int->>Adapter: 发送请求
    Adapter->>Remote: HTTP 请求
    Remote-->>Adapter: HTTP 响应
    Adapter-->>Int: 响应或传输错误
    Int-->>Dio: 诊断、必要的传输重试
    Dio-->>Api: 转换后的响应
    Api-->>Caller: Success / Failure 或下载结果
```

`Request.get()` 和 `Request.post()` 会把 `DioException` 转成含错误消息的 `Response`，调用层仍需检查业务响应。重试条件见 [`retry_interceptor.dart`](../lib/http/retry_interceptor.dart)。

`_CustomHttpOverrides` 在调试模式或 `Pref.badCertificateCallback` 开启时接受无效证书，此时 TLS 证书校验会降低。

## 播放器切源与网络恢复

### 请求、切源与页面归属

视频页与直播页通过 `PlaybackSession.attach()` 借用共享播放器。最近进入的页面拥有加载权；返回上一页面时显式激活其 `PlaybackOwner`，关闭页面时释放借用。页面被替换时，其在途查询同步失效，返回该页面后也不会重新接受这些旧结果。

地址查询绑定请求开始时的媒体标识。新查询立即执行，并取消上一轮在途 HTTP 请求；响应与补充画质结果提交前检查请求代次及页面归属。`VideoPlaybackSource` 将画质、编码、独立音轨与 CDN 地址解析成一次选择；页面用这份选择提交加载，字幕和播放信息沿用该媒体的有效性检查。

```mermaid
sequenceDiagram
    participant Page as 视频页 / 直播页
    participant Owner as PlaybackOwner
    participant Http as 播放地址 API
    participant Session as PlaybackSession / LoadQueue
    participant C as PlPlayerController
    participant Runtime as NativePlaybackRuntime
    participant P as media_kit / 平台输出

    Page->>Owner: query(请求快照)
    Owner->>Http: 查询地址 / 补充画质
    Http-->>Owner: 响应
    Owner->>Owner: 校验代次、媒体标识与归属
    Owner-->>Page: 提交当前来源选择
    Page->>C: setDataSource(source, owner, autoplay, seekTo)
    C->>Session: load(owner, operation)
    Session->>Session: 新代次、跳过旧排队任务、串行执行
    Session->>C: operation(isCurrent)
    C->>C: 更新元数据，暂停旧播放
    C->>Runtime: initialize / open
    opt 首次加载
        Runtime->>P: 创建 Player 与 VideoController
    end
    Runtime->>P: open(media, play: false)
    P-->>Runtime: open 完成
    Runtime-->>C: 校验当前请求后返回
    C->>C: 更新时长、位置、loaded 与画面适配
    opt 播放意图允许且请求有效
        C->>P: 开始播放
    end
```

已发出的原生操作保留在串行链中，返回后再检查代次。快速切源复用原生资源；释放最后一份借用后，先使会话与资源不可见，再等待在途加载结束并销毁播放器，避免 `open` 与 `dispose` 并发。

实现见 [`playback_session.dart`](../lib/plugin/pl_player/playback/playback_session.dart)、[`native_playback_runtime.dart`](../lib/plugin/pl_player/playback/native_playback_runtime.dart) 和 [`playback_source.dart`](../lib/pages/video/playback_source.dart)。

### 网络错误恢复

```mermaid
flowchart TD
    Error[收到播放器网络错误]
    Local{本地文件源?}
    Live{直播源?}
    Throttle[按当前媒体、CDN 候选和错误类型限频]
    Wait[等待 3 秒]
    Current{播放器仍存活且媒体源未变化?}
    NeedBuffer{是否要求等缓冲耗尽?}
    Exhausted{可播放缓冲已耗尽?}
    Defer{仍在消耗缓冲且仍处于 buffering?}
    Retry[重载媒体，按设置尝试下一个 CDN]
    Stop[结束本轮恢复]

    Error --> Local
    Local -->|是| Stop
    Local -->|否| Live
    Live -->|是：跳过缓冲耗尽检查| Wait
    Live -->|否| Throttle --> Wait
    Wait --> Current
    Current -->|否| Stop
    Current -->|是| NeedBuffer
    NeedBuffer -->|否| Retry
    NeedBuffer -->|是| Exhausted
    Exhausted -->|是| Retry
    Exhausted -->|否| Defer
    Defer -->|是：重新安排检查| Wait
    Defer -->|否| Stop
```

连接中断和媒体读取截断进入该链；HTTP 403 不按 CDN 故障重试。`utils/playback_network_recovery.dart` 识别网络读取错误，[`playback/network_recovery.dart`](../lib/plugin/pl_player/playback/network_recovery.dart) 管理当前媒体的计时器、限频与缓冲等待。切源会释放恢复状态，当前媒体的错误风暴合并为一个计时器，终止读取可升级已有的缓冲等待。分离音视频的读取错误先保留主视频剩余缓存，耗尽后再重载；主媒体的播放与缓存同时恢复推进时，可以取消本轮网络重载。加载队列繁忙时继续等待，保留本轮恢复机会。

网络源的音频读取或解码错误同时交给 [`playback/audio_recovery.dart`](../lib/plugin/pl_player/playback/audio_recovery.dart)。它先观察 2 秒，音频时间戳继续推进且与播放位置同步时保持播放；缓存中的音频仍有效时也不提前重载。确认音频停滞后，先异步重载当前外部音轨，mpv 将其同步到视频位置；确认仍未恢复时，再通过加载队列执行一次保留位置与播放意图的整段重载，按多 CDN 设置选择后备地址。听视频或没有外部音轨的来源直接使用整段重载兜底。

每轮最多尝试一次音轨重连和一次整段重载；失败后降低观察频率并仅提示一次。音频连续健康 30 秒后重新开放预算。暂停、缓冲、静音、拖动或接近片尾时让出恢复，恢复播放后继续检查遗留故障。切源和关闭使旧观察失效；mpv 的外部音轨异步命令绑定原生播放生命周期，不占用页面加载队列。观察依据音频时间戳而非音量，内容本身的无声片段不会触发恢复。

点播重载保留位置，直播重载不设置起始位置。切换画质、音质或重新解析已加载媒体时保留位置与播放意图。两者先暂停加载，完成后检查媒体有效性与最新播放意图；加载期间用户主动暂停时不会被恢复操作覆盖。开启多 CDN 时，直播仅使用当前协议、格式和编码提供的候选地址。

Windows 在确定硬件或软件后端后注册纹理，硬件初始化失败时先释放 GL 资源再进入软件路径。Android 保留既有 MediaCodec、Surface 与解码恢复实现。GPU、MediaCodec、Surface 行为和帧率仍需在目标设备验证。

## 下载

### 任务时序

下载记录由 `DownloadRepository` 持久化，`DownloadService` 维护待下载队列和当前任务，`DownloadManager` 负责单路媒体流。DASH 视频与音频可并发传输；任务只有在所需媒体流都完成后才标记完成。恢复时根据已有文件长度发送 Range 请求；暂停会保留已写入字节，删除则由服务移除对应目录。

```mermaid
sequenceDiagram
    participant UI as 下载页 / 视频页
    participant S as DownloadService
    participant R as DownloadRepository
    participant RPC as DmGrpc
    participant API as DownloadHttp / VideoHttp
    participant V as 视频 DownloadManager
    participant A as 音频 DownloadManager
    participant Disk as 下载目录

    UI->>S: 创建 UGC / PGC 下载项
    S->>R: 创建目录并保存 entry.json
    S->>S: 加入待下载队列，选择当前任务
    S->>RPC: 获取弹幕分段
    RPC-->>S: 返回分段数据
    S->>Disk: 写入弹幕文件
    S->>API: 获取播放地址与媒体信息
    API-->>S: Type1 分段或 DASH 视频 / 音频
    S->>R: 保存 index.json
    par 写入媒体文件
        S->>V: 使用 Range 请求恢复或开始视频
        V->>Disk: 流式写入并回报进度
    and
        S->>A: DASH 存在音轨时并发下载
        A->>Disk: 流式写入音频
    end
    V-->>S: 完成 / 暂停 / 错误
    A-->>S: 完成 / 暂停 / 错误
    alt 所需媒体流全部完成
        S->>R: 保存完成记录
        S->>S: 移出队列并启动下一项
    else 暂停或传输错误
        S->>R: 保存可恢复的进度和状态
    end
```

### 任务状态

```mermaid
flowchart TD
    Request[创建下载请求]
    Duplicate{CID 已在完成列表或队列?}
    Skip[忽略重复请求]
    Persist[创建目录并保存记录]
    Queue[加入待下载队列]
    Active[成为当前下载项]
    Danmaku[下载弹幕并写入文件]
    Url[请求播放地址]
    Address{播放地址获取成功?}
    Index[保存媒体索引]
    Transfer[传输视频；DASH 时并发传输音频]
    Result[收到媒体流结果回调]
    Error{本次传输失败或暂停?}
    Both{所需媒体流均已完成?}
    Other{是否还有必要的媒体流运行中?}
    Wait[等待下一路媒体流结果]
    Complete[保存完成状态并启动下一项]
    Failed[进入失败 / 暂停状态；由当前阶段处理]
    Cancel{取消方式}
    Keep[保留已写入字节并保存暂停状态]
    Remove[删除任务时移除目录]

    Request --> Duplicate
    Duplicate -->|是| Skip
    Duplicate -->|否| Persist --> Queue --> Active --> Danmaku
    Danmaku -->|成功| Url --> Address
    Address -->|否| Failed
    Address -->|是| Index --> Transfer --> Result --> Error
    Danmaku -->|失败| Failed
    Error -->|是| Failed
    Error -->|否| Both
    Both -->|是| Complete
    Both -->|否| Other
    Other -->|是| Wait --> Result
    Other -->|否| Failed
    Transfer -.-> Cancel
    Cancel -->|暂停| Keep
    Cancel -->|删除| Remove
```

实现与测试：[`download_service.dart`](../lib/services/download/download_service.dart)、[`download_repository.dart`](../lib/services/download/download_repository.dart)、[`download_manager.dart`](../lib/services/download/download_manager.dart)；`test/services/download/`。

## 账号消息与私信

消息页面沿用 GetX 路由，通过 Riverpod 获取当前主账号的 `MessagingSession` 和业务快照。未读概览、会话列表及聊天缓存由 Session 共享；分类消息句柄随页面订阅释放。状态所有权与协议入口见[消息模块](../lib/services/messaging/README.md)。

```mermaid
sequenceDiagram
    participant UI as 消息页 / 聊天页
    participant RP as Riverpod provider
    participant S as MessagingSession
    participant B as 列表句柄 / Conversation
    participant API as HTTP / gRPC adapter
    participant A as Accounts / Messaging

    UI->>RP: 订阅列表或聊天快照
    RP->>S: 获取当前主账号 Session
    RP->>B: 获取句柄或聊天租约
    B->>S: run(request)
    S->>API: 使用 Session 绑定的账号请求
    API-->>S: 查询结果
    S->>S: 检查账号仍有效
    S-->>B: 返回结果
    B->>B: 检查请求代次并合并数据
    B-->>RP: 发布业务快照
    RP-->>UI: 更新界面
    opt 聊天消息行完成布局
        UI->>B: markRendered(message)
        B->>S: 提交递增的 ACK 水位
        S->>API: 确认已读
        API-->>S: 确认结果
        S-->>B: 返回结果
        B->>S: 成功后通知未读与会话更新
    end
    opt 切换主账号
        A->>S: dispose 旧 Session
        A->>RP: 发布新 Session
        RP->>B: 释放旧订阅 / 租约，创建新状态
        Note over S,B: 旧账号在途响应失效
    end
    UI->>RP: 退出页面，释放订阅
    RP->>B: 释放页面句柄或聊天租约
```

私信分享由 `PageUtils.pmShare` 获取当前 Session 的 `MessageSharing`，将它传入分享页；发送时从同一聊天缓存获取租约。发送文本、图片和分享共用该聊天的发送锁。分享卡片确认成功后才发送附言；消息发送请求成功或结果待确认时，重新查询时间线并废弃发送前的读取。网络层关闭消息写请求的自动重试，结果待确认时页面提示核对聊天记录。卡片与附言分别请求，部分成功的结果保留已发送信息。

聊天读取历史时保留表情映射，刷新使旧历史页失效；消息按稳定标识合并。ACK 失败后等待更高渲染水位或手动刷新重试。系统通知先展示查询结果，再异步确认已读，失败时保留数据和未读数。

## 直播消息与弹幕

视频播放和聊天使用独立连接。页面从 `LiveHttp` 获取播放地址；聊天另取连接信息，再由 WebSocket 接收弹幕和互动消息。

```mermaid
sequenceDiagram
    participant Page as LiveRoomController
    participant API as LiveHttp
    participant WS as LiveMessageStream
    participant Socket as WebSocket 服务端
    participant Decoder as LivePacketDecoder isolate
    participant UI as 聊天缓冲与弹幕渲染

    Page->>API: 获取直播间信息与播放地址
    API-->>Page: 播放流
    Page->>Page: setDataSource(isLive: true)
    Page->>API: 首次启动聊天时获取 token 与 host 列表
    API-->>Page: 连接信息
    Page->>WS: 创建消息流并注册监听器
    WS->>Socket: 依次尝试 WebSocket host
    Socket-->>WS: 连接就绪
    WS->>Socket: 发送认证包 operation 7
    Socket-->>WS: 认证响应 operation 8
    WS->>WS: 启动周期心跳 operation 2
    loop 每个 WebSocket 数据帧
        Socket-->>WS: 二进制数据
        WS->>Decoder: TransferableTypedData
        Decoder->>Decoder: 拆包、解压嵌套包并解析 JSON
        Decoder-->>WS: 保序的消息列表
        WS->>Page: 调用业务监听器
        Page->>UI: 更新缓冲、未读数、弹幕或互动消息
    end
    Page->>WS: 页面关闭
    WS->>Decoder: 关闭 worker 并结束在途任务
    WS->>Socket: 取消订阅并关闭连接
```

每条连接复用一个解析 worker。关闭或 worker 异常会结束在途任务；损坏的数据包会被跳过。实现见 [`live.dart`](../lib/services/live_stream/live.dart)、[`live_packet_decoder.dart`](../lib/services/live_stream/live_packet_decoder.dart) 和 [`live_packet.dart`](../lib/services/live_stream/live_packet.dart)，测试位于 `test/services/live_stream/`。
