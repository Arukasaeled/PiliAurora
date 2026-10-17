import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/plugin/pl_player/controller.dart';

void main() {
  tearDown(() => PlPlayerController.setPlayCallBack(null));

  test(
    'retired facade callback cleanup keeps the newer page callback',
    () async {
      final retiredOwner = Object();
      final currentOwner = Object();
      var callbackCount = 0;

      PlPlayerController.setPlayCallBack(() async {
        callbackCount++;
      }, owner: retiredOwner);
      PlPlayerController.setPlayCallBack(() async {
        callbackCount += 10;
      }, owner: currentOwner);

      PlPlayerController.setPlayCallBack(null, owner: retiredOwner);
      await PlPlayerController.playIfExists();

      expect(callbackCount, 10);
    },
  );
}
