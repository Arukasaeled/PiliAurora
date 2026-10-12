import 'package:pili_aurora/common/widgets/scroll_physics.dart'
    show platformClampingPhysics;
import 'package:pili_aurora/models/common/super_chat_type.dart';
import 'package:pili_aurora/pages/live_room/controller.dart';
import 'package:pili_aurora/pages/live_room/superchat/superchat_card.dart';
import 'package:pili_aurora/common/widgets/debounced_state.dart';
import 'package:get/get_state_manager/src/rx_flutter/rx_obx_widget.dart';
import 'package:material_ui/material_ui.dart';

class SuperChatPanel extends StatefulWidget {
  const SuperChatPanel({
    super.key,
    required this.controller,
  });

  final LiveRoomController controller;

  @override
  State<SuperChatPanel> createState() => _SuperChatPanelState();
}

class _SuperChatPanelState extends DebounceStreamState<SuperChatPanel, bool>
    with AutomaticKeepAliveClientMixin {
  @override
  Duration get duration => const Duration(milliseconds: 300);

  late final persistentSC =
      widget.controller.superChatType == SuperChatType.persist;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              style: TextButton.styleFrom(foregroundColor: Colors.white),
              onPressed: () => widget.controller.pageController?.animateToPage(
                0,
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeInOut,
              ),
              icon: const Icon(Icons.keyboard_arrow_left),
              label: const Text('返回聊天'),
            ),
          ),
        ),
        Expanded(
          child: Obx(() {
            if (widget.controller.superChatMsg.isEmpty) {
              return const Center(
                child: Text('暂无 SC', style: TextStyle(color: Colors.white60)),
              );
            }
            return ListView.separated(
              key: const PageStorageKey(_SuperChatPanelState),
              padding: const EdgeInsets.symmetric(horizontal: 12),
              physics: platformClampingPhysics,
              itemCount: widget.controller.superChatMsg.length,
              findItemIndexCallback: (key) {
                final index = widget.controller.superChatMsg.indexWhere(
                  (i) => i.id == (key as ValueKey<int>).value,
                );
                // Return item index directly - no need to multiply by 2.
                return index == -1 ? null : index;
              },
              itemBuilder: (context, index) {
                final item = widget.controller.superChatMsg[index];
                return SuperChatCard(
                  key: ValueKey(item.id),
                  item: item,
                  onRemove: () => ctr?.add(true),
                  persistentSC: persistentSC,
                  onReport: () => widget.controller.reportSC(item),
                );
              },
              separatorBuilder: (_, _) => const SizedBox(height: 8),
            );
          }),
        ),
      ],
    );
  }

  @override
  void onValueChanged(value) => widget.controller.clearSC();

  @override
  bool get wantKeepAlive => true;
}
