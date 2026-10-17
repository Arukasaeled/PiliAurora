import 'package:pili_aurora/utils/path_utils.dart';
import 'package:path/path.dart' as path;

sealed class DataSource {
  final String videoSource;
  final String? audioSource;

  DataSource({
    required this.videoSource,
    required this.audioSource,
  });
}

class NetworkSource extends DataSource {
  NetworkSource({
    required super.videoSource,
    required super.audioSource,
    Iterable<String> videoCandidates = const [],
    Iterable<String> audioCandidates = const [],
  }) : videoCandidates = List.unmodifiable(
         _withPrimary(videoSource, videoCandidates),
       ),
       audioCandidates = audioSource == null || audioSource.isEmpty
           ? const []
           : List.unmodifiable(_withPrimary(audioSource, audioCandidates));

  final List<String> videoCandidates;
  final List<String> audioCandidates;

  static List<String> _withPrimary(
    String primary,
    Iterable<String> candidates,
  ) {
    final result = <String>[primary];
    for (final candidate in candidates) {
      if (candidate.isNotEmpty && !result.contains(candidate)) {
        result.add(candidate);
      }
    }
    return result;
  }
}

class FileSource extends DataSource {
  final String dir;
  final bool isMp4;

  FileSource({
    required this.dir,
    required this.isMp4,
    required bool hasDashAudio,
    required String typeTag,
  }) : super(
         videoSource: path.join(
           dir,
           typeTag,
           isMp4 ? PathUtils.videoNameType1 : PathUtils.videoNameType2,
         ),
         audioSource: isMp4 || !hasDashAudio
             ? null
             : path.join(dir, typeTag, PathUtils.audioNameType2),
       );
}
