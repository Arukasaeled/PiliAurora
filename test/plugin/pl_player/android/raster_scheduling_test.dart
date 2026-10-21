import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/plugin/pl_player/utils/android_raster_scheduling.dart';

void main() {
  test('应用成功后的回读失败仍能在释放时恢复', () {
    var mask = [0xc0];
    var failRead = true;
    final scheduling = AndroidRasterScheduling.forTesting(
      read: () {
        if (failRead) throw StateError('read failed');
        return mask;
      },
      write: (value) => mask = value.toList(),
      sameThread: () => true,
      original: [0xc0],
      app: [0xff],
    );
    expect(() => scheduling.useAppCpus(true), throwsStateError);
    expect(mask, [0xff]);
    failRead = false;
    scheduling.restore();
    expect(mask, [0xc0]);
  });

  test('输出复用期间保持放宽，释放时恢复，再次使用可重新取得', () {
    var mask = [0xc0];
    final writes = <List<int>>[];
    final scheduling =
        AndroidRasterScheduling.forTesting(
            read: () => mask,
            write: (value) {
              mask = value.toList();
              writes.add(mask);
            },
            sameThread: () => true,
            original: [0xc0],
            app: [0xff],
          )
          ..useAppCpus(true)
          ..useAppCpus(true);
    expect(mask, [0xff]);
    scheduling
      ..restore()
      ..restore();
    expect(mask, [0xc0]);
    scheduling
      ..useAppCpus(true)
      ..restore();
    expect(writes, [
      [0xff],
      [0xc0],
      [0xff],
      [0xc0],
    ]);
  });

  for (final replacedThread in [false, true]) {
    test('释放时保留${replacedThread ? '已替换线程' : '其它调度策略'}的亲和性', () {
      var currentThread = true;
      var mask = [0xc0];
      final scheduling = AndroidRasterScheduling.forTesting(
        read: () => mask,
        write: (value) => mask = value.toList(),
        sameThread: () => currentThread,
        original: [0xc0],
        app: [0xff],
      )..useAppCpus(true);
      if (replacedThread) {
        currentThread = false;
      } else {
        mask = [0x3f];
      }
      scheduling.restore();
      expect(mask, replacedThread ? [0xff] : [0x3f]);
    });
  }
}
