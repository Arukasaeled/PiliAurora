import 'dart:math';

import 'package:pili_aurora/utils/random_id.dart';
import 'package:pili_aurora/utils/id_utils.dart';
import 'package:flutter_test/flutter_test.dart';

class _BytesRandom implements Random {
  _BytesRandom(this.bytes);
  final List<int> bytes;
  var offset = 0;

  @override
  int nextInt(int max) {
    expect(max, 256);
    return bytes[offset++];
  }

  @override
  bool nextBool() => throw UnsupportedError('unused');

  @override
  double nextDouble() => throw UnsupportedError('unused');
}

void main() {
  test(
    'UUID v4 consumes 16 bytes and changes only version and variant bits',
    () {
      final random = _BytesRandom(List.generate(16, (index) => index));
      expect(
        newUuidV4(random: random),
        '00010203-0405-4607-8809-0a0b0c0d0e0f',
      );
      expect(random.offset, 16);
    },
  );

  test('Buvid3 preserves uppercase UUID, five digit suffix and infoc', () {
    final value = IdUtils.genBuvid3();
    expect(
      RegExp(
        r'^[0-9A-F]{8}-[0-9A-F]{4}-4[0-9A-F]{3}-[89AB][0-9A-F]{3}-[0-9A-F]{12}\d{5}infoc$',
      ).hasMatch(value),
      isTrue,
    );
  });
}
