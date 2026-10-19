import 'package:pili_aurora/grpc/bilibili/community/service/dm/v1.pb.dart';

/// 对象和列表开销加 UTF-16 字段的保守估算，供缓存与处理预算共用。
int estimateDanmakuElementBytes(DanmakuElem element) =>
    512 +
    2 *
        (element.content.length +
            element.midHash.length +
            element.action.length +
            element.idStr.length +
            element.animation.length +
            element.extra.length);
