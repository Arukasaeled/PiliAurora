/// 普通与高级弹幕共用的数量额度；图片字节预算由平台资源管理器核算。
abstract final class DanmakuDisplayLimits {
  static const maxActive = 600;
  static const maxActiveSpecial = 32;
  static const maxPerBatch = 120;
  static const maxSpecialPerBatch = 4;

  static bool canAdd(int active, int special, {required bool isSpecial}) =>
      active < maxActive && (!isSpecial || special < maxActiveSpecial);
}
