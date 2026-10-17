import 'package:pili_aurora/plugin/pl_player/controller.dart';
import 'package:pili_aurora/plugin/pl_player/models/data_status.dart';
import 'package:pili_aurora/plugin/pl_player/models/play_status.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class PlayOrPauseButton extends StatefulWidget {
  final PlPlayerController plPlayerController;

  const PlayOrPauseButton({
    super.key,
    required this.plPlayerController,
  });

  @override
  PlayOrPauseButtonState createState() => PlayOrPauseButtonState();
}

class PlayOrPauseButtonState extends State<PlayOrPauseButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController controller;

  @override
  void initState() {
    super.initState();
    controller = AnimationController(
      vsync: this,
      value: widget.plPlayerController.playerStatus.isPlaying ? 1 : 0,
      duration: const Duration(milliseconds: 200),
    );
    widget.plPlayerController.addStatusLister(_onStatusChanged);
  }

  void _onStatusChanged(PlayerStatus status) {
    if (status.isPlaying) {
      controller.forward();
    } else {
      controller.reverse();
    }
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.plPlayerController.removeStatusLister(_onStatusChanged);
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 42,
      height: 34,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.plPlayerController.onDoubleTapCenter,
        child: Obx(
          () => Center(
            child: widget.plPlayerController.dataStatus.loading
                ? const SizedBox.square(
                    dimension: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : AnimatedIcon(
                    semanticLabel:
                        widget.plPlayerController.playerStatus.isPlaying
                        ? '暂停'
                        : '播放',
                    progress: controller,
                    icon: AnimatedIcons.play_pause,
                    color: Colors.white,
                    size: 20,
                  ),
          ),
        ),
      ),
    );
  }
}
