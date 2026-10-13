import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yaml/yaml.dart';

Map<dynamic, dynamic> workflow(String name) =>
    loadYaml(File('.github/workflows/$name.yml').readAsStringSync()) as Map;

void main() {
  test('Windows verifies cnativeapi before packaging', () {
    final steps = workflow('win_x64')['jobs']['build-windows-app']['steps'] as List;
    final verify = steps.indexWhere((s) => s['name'] == 'Verify prebuilt cnativeapi');
    final build = steps.indexWhere((s) => s['name'] == 'Build Windows release');
    expect(verify, greaterThanOrEqualTo(0));
    expect(build, greaterThan(verify));
    expect(steps[verify]['run'], 'python third_party/nativeapi/package.py verify');
    expect(workflow('nativeapi')['on'], contains('workflow_dispatch'));
  });

  test('Windows verifies prebuilt libmpv before packaging Flutter', () {
    final steps =
        workflow('win_x64')['jobs']['build-windows-app']['steps'] as List;
    final nativeIndex = steps.indexWhere(
      (step) => step['name'] == 'Verify prebuilt libmpv',
    );
    final flutterIndex = steps.indexWhere(
      (step) => step['name'] == 'Build Windows release',
    );
    expect(nativeIndex, greaterThanOrEqualTo(0));
    expect(flutterIndex, greaterThan(nativeIndex));
    expect(steps[nativeIndex]['run'], contains('package-runtime.py verify'));
    expect(
      File('third_party/mpv/prebuilt/windows-x64.zip').existsSync(),
      isTrue,
    );
    expect(File('third_party/mpv/prebuilt/SHA256SUMS').existsSync(), isTrue);
    expect(File('third_party/mpv/source.tar.gz').existsSync(), isTrue);
  });

  test(
    'Native library rebuilding stays separate from application packaging',
    () {
      final config = workflow('mpv');
      expect((config['on'] as Map).keys, contains('workflow_dispatch'));
      final steps = config['jobs']['build-mpv']['steps'] as List;
      final buildIndex = steps.indexWhere(
        (step) => step['name'] == 'Build and test libmpv',
      );
      final uploadIndex = steps.indexWhere(
        (step) => step['name'] == 'Upload prebuilt package',
      );
      expect(buildIndex, greaterThanOrEqualTo(0));
      expect(uploadIndex, greaterThan(buildIndex));
      expect(steps[buildIndex]['run'], 'bash third_party/mpv/build.sh');
      expect(steps[uploadIndex]['with']['path'], 'third_party/mpv/prebuilt/');
    },
  );

  for (final (name, event) in [
    ('build', 'workflow_dispatch'),
    ('win_x64', 'workflow_call'),
    ('win_x64', 'workflow_dispatch'),
  ]) {
    test('$name $event keeps draft publishing opt-in', () {
      final input = workflow(name)['on'][event]['inputs']['draft_release'];
      expect(input['type'], 'boolean');
      expect(input['default'], isFalse);
      expect(input['required'], isFalse);
    });
  }

  for (final (name, job) in [
    ('build', 'android'),
    ('win_x64', 'build-windows-app'),
  ]) {
    test('$name release action obeys the selected draft mode', () {
      final steps = workflow(name)['jobs'][job]['steps'] as List;
      final release =
          steps.singleWhere((step) => step['name'] == 'Release') as Map;
      expect(release['uses'], startsWith('softprops/action-gh-release@'));
      expect(release['with']['draft'], r'${{ inputs.draft_release }}');
    });
  }

  test(
    'Android coordinator passes draft mode to the reusable Windows workflow',
    () {
      final job = workflow('build')['jobs']['win_x64'];
      expect(job['uses'], './.github/workflows/win_x64.yml');
      expect(
        job['with']['draft_release'],
        r"${{ github.event_name == 'workflow_dispatch' && inputs.draft_release }}",
      );
    },
  );
}
