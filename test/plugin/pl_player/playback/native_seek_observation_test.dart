import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/src/player/native/player/seek_observation.dart';

void main() {
  test('原生 seek 需要匹配命令回执、开始与同文件完成', () {
    final record = NativeSeekObservation(
      requestId: 10,
      observationId: 20,
      playlistEntryId: 30,
    )..start(30);
    expect(record.completes(30), isFalse);
    record
      ..acknowledge(9, 0)
      ..start(30);
    expect(record.completes(30), isFalse);
    record.acknowledge(10, 0);
    expect(record.completes(30), isFalse);
    record.start(30);
    expect(record.completes(31), isFalse);
    expect(record.completes(30), isTrue);
  });

  test('失败回执和无归属通知无法结清原生记录', () {
    final record =
        NativeSeekObservation(
            requestId: 10,
            observationId: 20,
            playlistEntryId: 30,
          )
          ..acknowledge(10, -1)
          ..start(30);
    expect(record.completes(30), isFalse);
    record
      ..acknowledge(10, 0)
      ..start(null);
    expect(record.completes(30), isFalse);
    record.start(31);
    expect(record.completes(30), isFalse);
  });
}
