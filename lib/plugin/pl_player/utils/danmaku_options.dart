import 'dart:math' show max;

import 'package:pili_aurora/utils/extension/box_ext.dart';
import 'package:pili_aurora/utils/storage.dart';
import 'package:pili_aurora/utils/storage_key.dart';
import 'package:pili_aurora/utils/storage_pref.dart';
import 'package:canvas_danmaku/canvas_danmaku.dart';

abstract final class DanmakuOptions {
  static final Set<int> blockTypes = Pref.danmakuBlockType;
  static bool blockColorful = blockTypes.contains(6);

  static int danmakuWeight = Pref.danmakuWeight;
  static double danmakuFontScaleFS = Pref.danmakuFontScaleFS;
  static double danmakuFontScale = Pref.danmakuFontScale;
  static int danmakuFontWeight = Pref.danmakuFontWeight;
  static double danmakuShowArea = Pref.danmakuShowArea;
  static double danmakuDuration = Pref.danmakuDuration;
  static double danmakuStaticDuration = Pref.danmakuStaticDuration;
  static double danmakuStrokeWidth = Pref.danmakuStrokeWidth;
  static bool danmakuFixedV = Pref.danmakuFixedV;
  static bool danmakuStatic2Scroll = Pref.danmakuStatic2Scroll;
  static bool danmakuMassiveMode = Pref.danmakuMassiveMode;
  static double danmakuLineHeight = Pref.danmakuLineHeight;

  static bool get sameFontScale => danmakuFontScale == danmakuFontScaleFS;

  static DanmakuOption get({
    required bool notFullscreen,
    double speed = 1.0,
    bool mergedFontScale = false,
  }) {
    return DanmakuOption(
      fontSize: 15 * (notFullscreen ? danmakuFontScale : danmakuFontScaleFS),
      fontWeight: danmakuFontWeight,
      area: danmakuShowArea,
      duration: danmakuDuration / speed,
      staticDuration: danmakuStaticDuration / speed,
      hideBottom: blockTypes.contains(4),
      hideScroll: blockTypes.contains(2),
      hideTop: blockTypes.contains(5),
      hideSpecial: blockTypes.contains(7),
      strokeWidth: danmakuStrokeWidth,
      scrollFixedVelocity: danmakuFixedV,
      massiveMode: danmakuMassiveMode,
      static2Scroll: danmakuStatic2Scroll,
      safeArea: true,
      // 合并字号最多放大两倍，预留轨道高度避免相邻弹幕重叠。
      lineHeight: mergedFontScale
          ? max(danmakuLineHeight, 2.4)
          : danmakuLineHeight,
    );
  }

  static Future<void>? save(double danmakuOpacity) {
    return GStorage.setting.putAllNE({
      SettingBoxKey.danmakuBlockType: blockTypes.toList(),
      SettingBoxKey.danmakuShowArea: danmakuShowArea,
      SettingBoxKey.danmakuFontScale: danmakuFontScale,
      SettingBoxKey.danmakuFontScaleFS: danmakuFontScaleFS,
      SettingBoxKey.danmakuDuration: danmakuDuration,
      SettingBoxKey.danmakuStaticDuration: danmakuStaticDuration,
      SettingBoxKey.danmakuStrokeWidth: danmakuStrokeWidth,
      SettingBoxKey.danmakuFontWeight: danmakuFontWeight,
      SettingBoxKey.danmakuLineHeight: danmakuLineHeight,
      SettingBoxKey.danmakuMassiveMode: danmakuMassiveMode,
      SettingBoxKey.danmakuStatic2Scroll: danmakuStatic2Scroll,
      SettingBoxKey.danmakuFixedV: danmakuFixedV,
      SettingBoxKey.danmakuWeight: danmakuWeight,
      SettingBoxKey.danmakuOpacity: danmakuOpacity,
    });
  }
}
