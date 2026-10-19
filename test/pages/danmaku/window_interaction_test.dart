import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/pages/danmaku/window_renderer.dart';

DanmakuWindowRenderer<String> _renderer({
  double height = 120,
  bool massive = false,
}) => DanmakuWindowRenderer(
  option: DanmakuOption(
    massiveMode: massive,
    fontSize: 20,
    duration: 2,
    staticDuration: 2,
    safeArea: false,
  ),
  size: Size(320, height),
);
DanmakuWindowContent<String> _item(
  String id,
  int time, {
  DanmakuItemType type = DanmakuItemType.scroll,
}) => DanmakuWindowContent(
  id,
  time,
  DanmakuContentItem<String>(
    id,
    color: const Color(0xffffffff),
    type: type,
    extra: 'business-$id',
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('selection freezes one item while others move; release preserves remaining lifetime', () {
    final renderer = _renderer();
    addTearDown(renderer.dispose);
    renderer
      ..prepare(
        [_item('a', 0), _item('b', 0)],
        generation: renderer.generation,
        preparedUntilUs: 10000000,
      )
      ..present(500000);
    final handle = renderer.interaction;
    final before = {for (final item in handle.snapshot) item.identity: item};
    final images = renderer.rasters.rasterizations;
    expect(handle.select('a'), isTrue);
    expect(renderer.validFromUs, 500000);
    expect(handle.isValid, isTrue);
    renderer.present(1500000, allowUnprepared: true);
    final current = {for (final item in handle.snapshot) item.identity: item};
    expect(current['a']!.bounds, before['a']!.bounds);
    expect(current['a']!.extra, 'business-a');
    expect(current['b']!.bounds.left, lessThan(before['b']!.bounds.left));
    expect(handle.hitTest(current['a']!.bounds.center)!.identity, 'a');
    renderer.present(2500000, allowUnprepared: true);
    expect(handle.snapshot.single.identity, 'a');
    expect(handle.snapshot.single.selected, isTrue);
    expect(handle.clearSelection(), isTrue);
    expect(renderer.validFromUs, 2500000);
    renderer.present(3000000, allowUnprepared: true);
    expect(
      handle.snapshot.single.bounds.left,
      lessThan(before['a']!.bounds.left),
    );
    expect(renderer.rasters.rasterizations, images);
    renderer.present(4000000, allowUnprepared: true);
    expect(handle.snapshot, isEmpty);
    expect(renderer.activeBytes, 0);
  });

  test('static selection pauses its remaining duration', () {
    final renderer = _renderer();
    addTearDown(renderer.dispose);
    renderer
      ..prepare(
        [_item('fixed', 0, type: DanmakuItemType.top)],
        generation: renderer.generation,
        preparedUntilUs: 12000000,
      )
      ..present(500000);
    final handle = renderer.interaction;
    final bounds = handle.snapshot.single.bounds;
    handle.select('fixed');
    renderer.present(9000000, allowUnprepared: true);
    expect(handle.snapshot.single.bounds, bounds);
    handle.clearSelection();
    renderer.present(10000000, allowUnprepared: true);
    expect(handle.snapshot.single.bounds, bounds);
    renderer.present(10500000, allowUnprepared: true);
    expect(handle.snapshot, isEmpty);
  });

  test('held geometry reserves future placement, then release allows following content', () {
    final renderer = _renderer(height: 40);
    addTearDown(renderer.dispose);
    renderer
      ..prepare(
        [_item('a', 0)],
        generation: renderer.generation,
        preparedUntilUs: 5000000,
      )
      ..present(600000);
    final handle = renderer.interaction..select('a');
    renderer
      ..prepare(
        [_item('blocked', 1000000)],
        generation: renderer.generation,
        preparedUntilUs: 4000000,
      )
      ..present(1100000, allowUnprepared: true);
    expect(handle.snapshot.map((item) => item.identity), ['a']);
    handle.clearSelection();
    renderer
      ..prepare(
        [_item('following', 1400000)],
        generation: renderer.generation,
        preparedUntilUs: 4000000,
      )
      ..present(1500000, allowUnprepared: true);
    expect(handle.snapshot.map((item) => item.identity), ['a', 'following']);
  });

  test(
    'switching selection releases the old item and keeps one frozen reference',
    () {
      final renderer = _renderer();
      addTearDown(renderer.dispose);
      renderer
        ..prepare(
          [_item('a', 0), _item('b', 0)],
          generation: renderer.generation,
          preparedUntilUs: 5000000,
        )
        ..present(500000);
      final handle = renderer.interaction..select('a');
      renderer.present(800000, allowUnprepared: true);
      handle.select('b');
      expect(
        handle.snapshot.where((item) => item.selected).single.identity,
        'b',
      );
      renderer.present(3000000, allowUnprepared: true);
      expect(handle.snapshot.single.identity, 'b');
    },
  );

  test('massive fallback may overlap the held item while selection remains topmost', () {
    final renderer = _renderer(height: 40, massive: true);
    addTearDown(renderer.dispose);
    renderer
      ..prepare(
        [_item('a', 0)],
        generation: renderer.generation,
        preparedUntilUs: 5000000,
      )
      ..present(600000);
    final handle = renderer.interaction..select('a');
    renderer
      ..prepare(
        [_item('b', 1000000)],
        generation: renderer.generation,
        preparedUntilUs: 4000000,
      )
      ..present(1600000, allowUnprepared: true);
    expect(handle.snapshot.length, 2);
    final held = handle.snapshot.singleWhere((item) => item.selected);
    expect(handle.hitTest(held.bounds.center)!.identity, 'a');
  });

  test(
    'reset and disposal invalidate old handles even when identities are reused',
    () {
      final renderer = _renderer();
      var disposed = false;
      addTearDown(() {
        if (!disposed) renderer.dispose();
      });
      renderer
        ..prepare(
          [_item('a', 0)],
          generation: renderer.generation,
          preparedUntilUs: 5000000,
        )
        ..present(500000);
      final old = renderer.interaction;
      renderer.reset(1000000);
      renderer
        ..prepare(
          [_item('a', 1000000)],
          generation: renderer.generation,
          preparedUntilUs: 5000000,
        )
        ..present(1100000);
      expect(old.isValid, isFalse);
      expect(old.select('a'), isFalse);
      expect(old.clearSelection(), isFalse);
      expect(old.snapshot, isEmpty);
      final fresh = renderer.interaction;
      expect(fresh.select('a'), isTrue);
      renderer.dispose();
      disposed = true;
      expect(fresh.isValid, isFalse);
      expect(fresh.select('a'), isFalse);
      expect(fresh.snapshot, isEmpty);
    },
  );
}
