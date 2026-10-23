import 'package:pili_aurora/http/black.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:pili_aurora/utils/global_data.dart';
import 'package:pili_aurora/utils/storage_pref.dart';

/// 同一账号共用完整黑名单；分页未读完时继续使用上次的完整缓存。
abstract final class BlockedAuthors {
  static Account? _owner;
  static Future<void>? _pending;
  static DateTime? _checkedAt;
  static Map<int, bool>? _changes;

  static bool contains(int? mid) =>
      mid != null && mid > 0 && GlobalData().blackMids.contains(mid);

  static void setBlocked(int mid, bool blocked) {
    if (identical(_owner, Accounts.main)) _changes?[mid] = blocked;
    if (blocked) {
      Pref.setBlackMid(mid);
    } else {
      Pref.removeBlackMid(mid);
    }
  }

  static Future<void>? ensureLoaded() {
    if (!Pref.filterBlockedAuthors || !Accounts.main.isLogin) return null;
    final account = Accounts.main;
    if (!identical(account, _owner)) {
      _owner = account;
      _pending = null;
      _checkedAt = null;
      _changes = null;
    }
    if (_pending case final pending?) return pending;
    final now = DateTime.now();
    if (_checkedAt case final checkedAt?
        when now.difference(checkedAt) < const Duration(minutes: 5)) {
      return null;
    }
    // 同步请求限频；失败时继续沿用该账号的完整缓存。
    _checkedAt = now;
    final pending = _load(account);
    _pending = pending;
    return pending.whenComplete(() {
      if (identical(_pending, pending)) {
        _pending = null;
        _changes = null;
      }
    });
  }

  static Future<void> _load(Account account) async {
    final data = GlobalData();
    final changes = <int, bool>{};
    _changes = changes;
    final mids = <int>{};
    var received = 0;
    try {
      for (var page = 1; ; page++) {
        final result = await BlackHttp.blackList(pn: page, account: account);
        if (!identical(account, Accounts.main) || !identical(account, _owner)) {
          return;
        }
        if (result case Success(:final response)) {
          final list = response.list ?? const [];
          final previousLength = mids.length;
          mids.addAll(list.map((item) => item.mid).whereType<int>());
          received += list.length;
          if (response.total case final total? when received >= total) break;
          if (list.isEmpty || mids.length == previousLength) return;
          if (response.total == null && list.length < 50) break;
        } else {
          return;
        }
      }
      // 同步期间的拉黑/解除操作优先于较早发出的名单请求。
      for (final entry in changes.entries) {
        if (entry.value) {
          mids.add(entry.key);
        } else {
          mids.remove(entry.key);
        }
      }
      data.blackMids = mids;
      Pref.blackMids = mids;
    } catch (_) {
      // 网络不可用时沿用该账号缓存，内容请求仍可继续。
    }
  }
}
