import 'package:hive_ce/hive.dart';

/// 播放状态使用比例，原生播放器使用整数百分比。
double volumePercent(num ratio) => (ratio.clamp(0, 1) * 100).roundToDouble();

double roundVolumeRatio(num ratio) => volumePercent(ratio) / 100;

/// 累积触控板的细小滚动，输出仍保持整数百分比。
class VolumeScrollAdjustment {
  double? _pending;
  double? _last;

  double apply(double current, double scrollDelta) {
    if (current != _last) _pending = current;
    _pending = (_pending! - scrollDelta / 4000).clamp(0.0, 1.0);
    return _last = roundVolumeRatio(_pending!);
  }
}

/// 读取旧配置时归整并回写，导入旧备份后也沿用同一规则。
double readVolumePreference(
  Box<dynamic> settings,
  String key, {
  required double defaultValue,
  bool percentage = false,
}) {
  final saved = settings.get(key, defaultValue: defaultValue) as num;
  final value = percentage
      ? saved.clamp(0, 100).roundToDouble()
      : roundVolumeRatio(saved);
  if (value != saved) settings.put(key, value);
  return value;
}
