import 'package:pili_aurora/common/assets.dart';
import 'package:material_ui/material_ui.dart';

/// 阴影随图标预渲染，避免首次显示时触发复杂路径的模糊栅格化。
class PlayIcon extends StatelessWidget {
  const PlayIcon({super.key, this.size = 60});

  final double size;

  @override
  Widget build(BuildContext context) => Semantics(
    label: '播放',
    textDirection: TextDirection.ltr,
    child: SizedBox.square(
      dimension: size,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 资源的 60px 图形四周保留 12px 阴影；布局尺寸仍按图形计算。
          final extent = constraints.biggest.shortestSide * 84 / 60;
          return OverflowBox(
            minWidth: extent,
            maxWidth: extent,
            minHeight: extent,
            maxHeight: extent,
            child: Image.asset(
              Assets.playIcon,
              width: extent,
              height: extent,
              excludeFromSemantics: true,
              filterQuality: FilterQuality.medium,
            ),
          );
        },
      ),
    ),
  );
}
