import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/services/diagnostics/process_metrics.dart';

void main() {
  test('Windows native process counters remain available', () {
    final metrics = ProcessMetrics();
    final first = metrics.sample();
    final second = metrics.sample();
    expect(first['rssBytes'], greaterThan(0));
    expect(first['privateBytes'], greaterThan(0));
    expect(second['cpuPercentMachine'], isA<num>());
    metrics.reset();
    expect(metrics.sample()['cpuPercentMachine'], isNull);
  }, skip: !Platform.isWindows);
}
