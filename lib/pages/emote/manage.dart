import 'package:pili_aurora/common/widgets/image/network_img_layer.dart';
import 'package:pili_aurora/common/widgets/loading_widget/loading_widget.dart';
import 'package:pili_aurora/common/widgets/scaffold/simple_scaffold.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/http/reply.dart';
import 'package:pili_aurora/models/common/image_type.dart';
import 'package:pili_aurora/models/remote/emote/package.dart';
import 'package:pili_aurora/models/remote/emote/setting_panel.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:material_ui/material_ui.dart';

/// 原生管理评论区表情包。
class EmoteManagePage extends StatefulWidget {
  const EmoteManagePage({super.key});

  @override
  State<EmoteManagePage> createState() => _EmoteManagePageState();
}

class _EmoteManagePageState extends State<EmoteManagePage> {
  final _searchController = TextEditingController();
  final _busyPackageIds = <int>{};
  EmoteSettingPanel? _panel;
  String? _error;
  bool _loading = true;
  String _keyword = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final result = await ReplyHttp.getEmoteSettingPanel();
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (result case Success(:final response)) {
        _panel = response;
      } else if (result case Error(:final errMsg)) {
        _error = errMsg ?? '加载失败';
      }
    });
  }

  Future<void> _changePackage(Package package, {required bool add}) async {
    final id = package.id;
    if (id == null || _busyPackageIds.contains(id)) return;
    setState(() => _busyPackageIds.add(id));
    final result = add
        ? await ReplyHttp.addEmotePackage(packageId: id)
        : await ReplyHttp.removeEmotePackage(packageId: id);
    if (!mounted) return;
    if (result is Success<void>) {
      SmartDialog.showToast(add ? '添加成功' : '移除成功');
      await _load();
    } else if (result is Error) {
      SmartDialog.showToast(result.errMsg ?? '操作失败');
    }
    if (mounted) setState(() => _busyPackageIds.remove(id));
  }

  @override
  Widget build(BuildContext context) {
    final panel = _panel;
    final addedIds = panel?.userPanelPackages.map((e) => e.id).toSet() ?? {};
    final added = panel?.userPanelPackages ?? const <Package>[];
    final available =
        panel?.allPackages
            .where(
              (package) =>
                  !addedIds.contains(package.id) &&
                  package.flags?.added != true,
            )
            .toList() ??
        const <Package>[];

    return DefaultTabController(
      length: 2,
      child: SimpleScaffold(
        appBar: AppBar(title: const Text('表情包管理')),
        body: SafeArea(
          top: false,
          bottom: true,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: TextField(
                  controller: _searchController,
                  onChanged: (value) => setState(() => _keyword = value.trim()),
                  decoration: InputDecoration(
                    prefixIcon: const Icon(Icons.search),
                    hintText: '搜索表情包',
                    suffixIcon: _keyword.isEmpty
                        ? null
                        : IconButton(
                            tooltip: '清除搜索',
                            onPressed: () {
                              _searchController.clear();
                              setState(() => _keyword = '');
                            },
                            icon: const Icon(Icons.clear),
                          ),
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
              ),
              TabBar(
                tabs: [
                  Tab(text: '已添加 (${added.length})'),
                  Tab(text: '未添加 (${available.length})'),
                ],
              ),
              Expanded(
                child: _loading
                    ? m3eLoading
                    : _error != null
                    ? Center(
                        child: TextButton.icon(
                          onPressed: _load,
                          icon: const Icon(Icons.refresh),
                          label: Text(_error!),
                        ),
                      )
                    : TabBarView(
                        children: [
                          _buildPackageList(added, add: false),
                          _buildPackageList(available, add: true),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPackageList(List<Package> packages, {required bool add}) {
    final filtered = packages
        .where(
          (package) =>
              _keyword.isEmpty ||
              (package.text?.toLowerCase().contains(_keyword.toLowerCase()) ??
                  false),
        )
        .toList();
    if (filtered.isEmpty) {
      return Center(
        child: Text(_keyword.isEmpty ? '暂无表情包' : '没有匹配的表情包'),
      );
    }
    return ListView.separated(
      itemCount: filtered.length,
      separatorBuilder: (context, index) => const Divider(height: 1),
      itemBuilder: (context, index) {
        final package = filtered[index];
        final id = package.id;
        final busy = id != null && _busyPackageIds.contains(id);
        return ListTile(
          leading: NetworkImgLayer(
            src: package.url,
            width: 44,
            height: 44,
            type: ImageType.emote,
            fit: BoxFit.contain,
          ),
          title: Text(package.text ?? '未命名表情包'),
          subtitle: package.emote == null
              ? null
              : Text('${package.emote!.length} 个表情'),
          trailing: busy
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : IconButton(
                  tooltip: add ? '添加' : '移除',
                  onPressed: id == null
                      ? null
                      : () => _changePackage(package, add: add),
                  icon: Icon(add ? Icons.add_circle_outline : Icons.remove),
                ),
        );
      },
    );
  }
}
