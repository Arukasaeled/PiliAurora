# 消息业务模块

页面保留 GetX 路由，通过 Riverpod 订阅业务快照。HTTP 与 gRPC 适配器负责协议转换，页面使用会话目标、消息内容和操作结果。

## 所有权与入口

- `session.dart`：主账号每次切换创建新的 `MessagingSession`，释放旧资源；请求绑定该 Session 的账号，返回时再次检查有效性。
- `providers.dart`：向 Riverpod 提供当前 Session，并将 `ValueListenable` 快照桥接为同步订阅。
- `overview.dart`：账号共享的未读概览，主页和消息入口使用同一来源。查询失败保留旧值，缺失字段保持未知；阅读成功使旧查询失效。
- `sessions.dart`：按稳定 `SessionKey` 共享会话实体，各文件夹维护自己的列表、分页和快照。删除、置顶、免打扰与已读操作更新共享实体，并废弃相关在途列表请求。
- `conversation.dart`：管理聊天时间线、历史分页、发送与撤回。缓存租约保护使用中的聊天，释放后按容量回收空闲会话。
- `feed.dart`、`feed_notifier.dart`：管理分类消息分页与页面订阅，刷新使旧分页失效。点赞保留最新与历史两个分组。
- `settings.dart`：管理接收设置、关键词屏蔽与联系设置，复制协议对象并按操作版本处理回滚。

## 异步操作约定

查询通过代次和账号有效性检查决定是否应用响应。消息写请求关闭网络层自动重试；发送网络异常使用 `OperationStatus.unknown`，页面提示核对结果。文本草稿在确认成功后清理，发送锁在操作结束时释放。

消息行完成布局后调用 `markRendered`。已读水位单调递增；失败 ACK 等待更高水位或手动刷新后重试。已读成功通知未读概览与会话列表刷新。

## 验证

```powershell
fvm flutter test --no-pub test/services/messaging/
```

该目录已接入 `tool/run-ci-tests.ps1`。测试覆盖账号切换、订阅、列表操作与在途响应、分页、发送锁、未知结果、撤回和 ACK；真实服务接口及 Android、Windows 页面交互需要登录后的设备验证。
