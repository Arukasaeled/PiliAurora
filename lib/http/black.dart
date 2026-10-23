import 'package:pili_aurora/http/api.dart';
import 'package:pili_aurora/http/init.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/models/remote/blacklist/data.dart';
import 'package:pili_aurora/utils/accounts.dart';
import 'package:pili_aurora/utils/accounts/account.dart';
import 'package:dio/dio.dart';

abstract final class BlackHttp {
  static Future<LoadingState<BlackListData>> blackList({
    required int pn,
    int ps = 50,
    Account? account,
  }) async {
    final requestAccount = account ?? Accounts.main;
    final res = await Request().get(
      Api.blackLst,
      queryParameters: {
        'pn': pn,
        'ps': ps,
        're_version': 0,
        'jsonp': 'jsonp',
        'csrf': requestAccount.csrf,
      },
      options: Options(extra: {'account': requestAccount}),
    );
    if (res.data['code'] == 0) {
      return Success(BlackListData.fromJson(res.data['data']));
    } else {
      return Error(res.data['message']);
    }
  }
}
