# get 本地版本

- 本地版本：`4.7.2+piliaurora.2`；来源包版本：`4.7.2`。
- 来源仓库：https://github.com/bggRGjQaUbCoE/getx.git
- 来源提交：`3e65da893d9736135b2631a39e46c8f5388c2536`。
- 来源子目录：`.`。
- 许可证：LICENSE。
- 保留原因：保留独立 UI 类型、rawValue、sharedAxis 与页面转场定制。

仅收录生产源码、构建配置、资源及许可说明；不复制上游示例、测试、缓存或 Git 元数据。
导入时除包版本、禁止发布声明及必要依赖声明外，不重写来源实现。
这些包不是 pub.dev 同名版本的镜像，不可仅修改根版本号宣称已升级。
更新流程见 `../README.md`，来源登记见 `../dependencies.json`。

## 本地补丁

- `router_report.dart`：路由销毁并处理关联依赖后，移除 `_routesKey` 中的 Route 键，释放对路由及其 arguments 的静态引用。永久依赖继续遵循 Get 的保留规则。回归测试位于根项目 `test/router/get_route_lifecycle_test.dart`，覆盖真实 Navigator 出栈、普通实例与 `Get.create()` 的关闭、永久实例保留及重复进出。
