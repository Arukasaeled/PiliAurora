import 'package:pili_aurora/grpc/im.dart';
import 'package:pili_aurora/http/loading_state.dart';
import 'package:pili_aurora/utils/accounts/account.dart';

class ShareRecipient {
  const ShareRecipient({
    required this.id,
    required this.name,
    required this.avatar,
  });

  final int id;
  final String name;
  final String avatar;
}

class SharingAdapter {
  const SharingAdapter();

  Future<LoadingState<List<ShareRecipient>>> recentRecipients(
    Account account,
  ) async {
    final result = await ImGrpc.shareList(account: account, size: 5);
    return switch (result) {
      Success(:final response) => Success(
        List<ShareRecipient>.unmodifiable(
          response.sessionList.map(
            (item) => ShareRecipient(
              id: item.talkerId.toInt(),
              name: item.talkerUname,
              avatar: item.talkerIcon,
            ),
          ),
        ),
      ),
      Error() => result,
      Loading() => result,
    };
  }
}
