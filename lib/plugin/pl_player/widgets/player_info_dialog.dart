import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:pili_aurora/services/diagnostics/redact.dart';
import 'package:pili_aurora/utils/utils.dart';

/// 打开时的播放快照，分类滚动不持有播放器订阅。
class PlayerInfoDialog extends StatelessWidget {
  const PlayerInfoDialog({
    super.key,
    required this.state,
    required this.hwdec,
    required this.volume,
  });

  final PlayerState state;
  final String hwdec;
  final String volume;

  static String _text(Object? value) =>
      value == null || value.toString().isEmpty ? '暂无' : value.toString();

  static String _number(num? value, String unit, {int digits = 2}) {
    if (value == null || !value.isFinite || value <= 0) return '暂无';
    return '${value.toStringAsFixed(digits).replaceFirst(RegExp(r'\.?0+$'), '')} $unit';
  }

  @override
  Widget build(BuildContext context) {
    final video = state.track.video;
    final audio = state.track.audio;
    final params = state.videoParams;
    final sound = state.audioParams;
    final sampleRate = sound.sampleRate ?? audio.samplerate;
    final volumeValue = double.tryParse(volume);
    final pixelFormats = [
      params.pixelformat,
      params.hwPixelformat,
    ].whereType<String>().where((value) => value.isNotEmpty).join(' / ');
    final resolution = state.width > 0 && state.height > 0
        ? '${state.width} × ${state.height}'
        : '暂无';
    final media = state.playlist.medias;
    final index = state.playlist.index;
    final uri = index >= 0 && index < media.length
        ? Uri.tryParse(media[index].uri)
        : null;
    final source = uri == null
        ? '暂无'
        : uri.hasAuthority && (uri.scheme == 'http' || uri.scheme == 'https')
        ? uri.host
        : '本地文件或其他来源';
    final videoRows = <(String, String)>[
      ('分辨率', resolution),
      ('视频编码', _text(video.codec?.toUpperCase())),
      ('帧率', _number(video.fps, 'fps')),
      (
        '视频码率',
        _number(
          video.bitrate == null ? null : video.bitrate! / 1000000,
          'Mb/s',
        ),
      ),
      ('硬件解码', hwdec == 'no' ? '未启用' : _text(hwdec)),
      ('显示比例', _number(params.aspect, ': 1')),
      ('像素格式', _text(pixelFormats)),
      ('色彩空间', _text(params.colormatrix)),
      (
        '色彩范围',
        switch (params.colorlevels) {
          'limited' => '有限范围',
          'full' => '完整范围',
          final value => _text(value),
        },
      ),
      ('伽马', _text(params.gamma)),
    ];
    final audioRows = <(String, String)>[
      ('音频编码', _text(audio.codec?.toUpperCase())),
      (
        '采样率',
        _number(
          sampleRate == null ? null : sampleRate / 1000,
          'kHz',
        ),
      ),
      (
        '声道',
        switch (sound.channels ?? audio.channels) {
          'stereo' => '双声道',
          'mono' => '单声道',
          final value => _text(value),
        },
      ),
      ('声道数', _text(sound.channelCount ?? audio.channelscount)),
      (
        '音频码率',
        _number(audio.bitrate == null ? null : audio.bitrate! / 1000, 'kb/s'),
      ),
      ('采样格式', _text(sound.format)),
      (
        '音量',
        volumeValue != null && volumeValue.isFinite
            ? '${volumeValue.toStringAsFixed(1)}%'
            : '暂无',
      ),
    ];
    final sourceRows = <(String, String)>[
      ('媒体来源', source),
      ('播放列表', media.isEmpty ? '暂无' : '${index + 1} / ${media.length}'),
      ('播放速度', '${state.rate}×'),
    ];
    final raw = DiagnosticRedactor.text(
      'VideoParams\n${state.videoParams}\n\nAudioParams\n${state.audioParams}'
      '\n\nVideoTrack\n$video\n\nAudioTrack\n$audio'
      '\n\nMedia\n${state.playlist}\n\nrate: ${state.rate}\nvolume: $volume\nhwdec: $hwdec',
      maxLength: 16384,
    );
    final summary = DiagnosticRedactor.text(
      [
        '播放信息（打开时快照）',
        for (final group in [
          ('视频', videoRows),
          ('音频', audioRows),
          ('来源', sourceRows),
        ])
          '${group.$1}\n${group.$2.map((row) => '${row.$1}：${row.$2}').join('\n')}',
      ].join('\n\n'),
    );

    return DefaultTabController(
      length: 3,
      child: AlertDialog(
        title: const Text('播放信息'),
        contentPadding: const EdgeInsets.only(top: 12),
        content: SizedBox(
          width: 440,
          height: (MediaQuery.sizeOf(context).height * .6).clamp(120.0, 520.0),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    '打开时快照',
                    style: TextStyle(
                      fontSize: 12,
                      color: ColorScheme.of(context).onSurfaceVariant,
                    ),
                  ),
                ),
              ),
              const TabBar(
                tabs: [
                  Tab(text: '视频'),
                  Tab(text: '音频'),
                  Tab(text: '来源'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    _page(
                      context,
                      Icons.videocam_outlined,
                      resolution,
                      '视频参数',
                      videoRows,
                      '原始视频参数',
                      '${state.videoParams}\n\n$video',
                    ),
                    _page(
                      context,
                      Icons.audiotrack_outlined,
                      _text(audio.codec?.toUpperCase()),
                      '音频参数',
                      audioRows,
                      '原始音频参数',
                      '${state.audioParams}\n\n$audio',
                    ),
                    _page(
                      context,
                      Icons.link,
                      '当前媒体源',
                      '地址与查询参数在复制时脱敏',
                      sourceRows,
                      '原始参数（已脱敏）',
                      raw,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton.icon(
            onPressed: () => Utils.copyText(summary),
            icon: const Icon(Icons.copy_outlined, size: 18),
            label: const Text('复制信息摘要'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('完成'),
          ),
        ],
      ),
    );
  }

  Widget _page(
    BuildContext context,
    IconData icon,
    String title,
    String subtitle,
    List<(String, String)> rows,
    String rawTitle,
    String raw,
  ) {
    final colors = ColorScheme.of(context);
    final safeRaw = DiagnosticRedactor.text(raw, maxLength: 16384);
    return ListView(
      key: ValueKey(subtitle),
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colors.secondaryContainer,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(icon, color: colors.onSecondaryContainer),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Theme.of(context).textTheme.titleMedium),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 12,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        for (final row in rows)
          InkWell(
            onTap: () =>
                Utils.copyText(DiagnosticRedactor.text('${row.$1}：${row.$2}')),
            child: Container(
              padding: const EdgeInsets.symmetric(vertical: 13),
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(
                    color: colors.outlineVariant.withValues(alpha: .4),
                  ),
                ),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 2,
                    child: Text(
                      row.$1,
                      style: TextStyle(color: colors.onSurfaceVariant),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 3,
                    child: Text(row.$2, textAlign: TextAlign.end),
                  ),
                ],
              ),
            ),
          ),
        const SizedBox(height: 12),
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: Text(rawTitle, style: const TextStyle(fontSize: 13)),
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: SelectableText(
                safeRaw,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () => Utils.copyText(safeRaw),
                icon: const Icon(Icons.copy_outlined, size: 16),
                label: const Text('复制脱敏参数'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
