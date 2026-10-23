import 'package:pili_aurora/utils/storage_pref.dart';
import 'package:pili_aurora/utils/accounts.dart';

class GlobalData {
  int imgQuality = Pref.picQuality;

  num? coins;

  void afterCoin(num coin) {
    if (coins != null) {
      coins = coins! - coin;
    }
  }

  int? _blackMidsOwner;
  Set<int> _blackMids = {};

  Set<int> get blackMids {
    if (_blackMidsOwner != Accounts.main.mid) {
      _blackMidsOwner = Accounts.main.mid;
      _blackMids = Pref.blackMids;
    }
    return _blackMids;
  }

  set blackMids(Set<int> value) {
    _blackMidsOwner = Accounts.main.mid;
    _blackMids = value;
  }

  bool dynamicsWaterfallFlow = Pref.dynamicsWaterfallFlow;

  bool showMedal = Pref.showMedal;

  // 私有构造函数
  GlobalData._();

  // 单例实例
  static final GlobalData _instance = GlobalData._();

  // 获取全局实例
  factory GlobalData() => _instance;
}
