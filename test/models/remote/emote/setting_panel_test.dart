import 'package:flutter_test/flutter_test.dart';
import 'package:pili_aurora/models/remote/emote/setting_panel.dart';

void main() {
  test('parses current and available emote packages', () {
    final panel = EmoteSettingPanel.fromJson({
      'user_panel_packages': [
        {
          'id': 12,
          'text': '已添加',
          'url': 'https://example.com/added.png',
          'flags': {'added': true},
          'emote': [
            {'text': '[微笑]', 'url': 'https://example.com/smile.png'},
          ],
        },
      ],
      'all_packages': [
        {
          'id': 12,
          'text': '已添加',
          'flags': {'added': 1},
        },
        {
          'id': 34,
          'text': '可添加',
          'flags': {'added': 0},
        },
      ],
    });

    expect(panel.userPanelPackages.single.id, 12);
    expect(panel.userPanelPackages.single.emote?.single.text, '[微笑]');
    expect(panel.allPackages.map((package) => package.flags?.added), [
      true,
      false,
    ]);
  });

  test('treats missing package lists as empty', () {
    final panel = EmoteSettingPanel.fromJson({});

    expect(panel.userPanelPackages, isEmpty);
    expect(panel.allPackages, isEmpty);
  });
}
