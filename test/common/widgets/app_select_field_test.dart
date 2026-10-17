import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:pili_aurora/common/widgets/app_select_field.dart';

void main() {
  testWidgets('opens the shared menu and selects from a long list', (
    tester,
  ) async {
    var value = '1080P 高码率';
    const options = [
      ('8K 超清', '8K 超清'),
      ('4K 超清', '4K 超清'),
      ('1080P60', '1080P60'),
      ('1080P 高码率', '1080P 高码率'),
      ('1080P', '1080P'),
      ('720P60', '720P60'),
      ('720P', '720P'),
      ('480P', '480P'),
      ('360P', '360P'),
      ('自动', '自动'),
    ];

    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          useMaterial3: true,
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
        ),
        home: Scaffold(
          body: Center(
            child: StatefulBuilder(
              builder: (context, setState) {
                return AppSelectField<String>(
                  value: value,
                  label: '画质',
                  selectedLabel: value,
                  options: options,
                  onSelected: (next) => setState(() => value = next),
                );
              },
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byType(TextButton));
    await tester.pumpAndSettle();

    expect(find.text('画质'), findsOneWidget);
    expect(find.text('8K 超清'), findsOneWidget);

    await tester.ensureVisible(find.text('360P'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('360P'));
    await tester.pumpAndSettle();

    expect(value, '360P');
    expect(find.text('360P'), findsOneWidget);
  });
}
