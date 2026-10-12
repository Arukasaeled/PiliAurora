import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/skeleton/video_card_h.dart';
import 'package:pili_aurora/common/sliver_single_child_delegate.dart';

class PaintCounter extends SingleChildRenderObjectWidget {
  const PaintCounter({super.key, required this.painted, required super.child});
  final VoidCallback painted;
  @override
  RenderObject createRenderObject(BuildContext context) => CounterBox(painted);
}

class CounterBox extends RenderProxyBox {
  CounterBox(this.painted);
  final VoidCallback painted;
  @override
  void paint(PaintingContext context, Offset offset) {
    painted();
    super.paint(context, offset);
  }
}

void main() {
  testWidgets('loading skeleton animation keeps the static header isolated', (
    tester,
  ) async {
    for (final isolated in [false, true]) {
      var paints = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: CustomScrollView(
            slivers: [
              SliverToBoxAdapter(
                child: PaintCounter(
                  painted: () => paints++,
                  child: const SizedBox(
                    height: 40,
                    child: ColoredBox(color: Colors.red),
                  ),
                ),
              ),
              SliverGrid(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  mainAxisExtent: 110,
                ),
                delegate: isolated
                    ? SliverChildBuilderDelegate(
                        (_, _) => const VideoCardHSkeleton(),
                        childCount: 10,
                      )
                    : const SliverSingleChildDelegate(
                        count: 10,
                        child: VideoCardHSkeleton(),
                      ),
              ),
            ],
          ),
        ),
      );
      final first = paints;
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(paints - first, 0);
      await tester.pumpWidget(const SizedBox());
    }
  });
}
