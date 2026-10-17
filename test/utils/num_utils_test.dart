import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/services/diagnostics/diagnostics.dart';
import 'package:pili_aurora/utils/num_utils.dart';

void main() {
  test('missing optional counts return zero without warning records', () {
    final before = Diagnostics.instance.recentLogs.length;
    for (final input in ['', '  ', '-', ' - ']) {
      expect(NumUtils.parseNum(input), 0);
    }
    expect(Diagnostics.instance.recentLogs.length, before);
    expect(NumUtils.parseNum('1.2万'), 12000);
  });
}
