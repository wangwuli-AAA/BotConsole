import 'dart:io';

import 'package:bot_console/core/app_paths.dart';
import 'package:bot_console/core/proc_launcher.dart';
import 'package:bot_console/core/settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('能用 %APPDATA% 下的日志路径拉起进程', () async {
    AppPaths.ensureDirs();
    final outPath = AppPaths.logFile('probe.out.log');
    final errPath = AppPaths.logFile('probe.err.log');
    // ignore: avoid_print
    print('baseDir=${AppPaths.baseDir} out=$outPath');
    final spec = LaunchSpec(
      name: 'probe',
      executable: resolveNodeExe(),
      arguments: const ['-e', 'console.log("hi")'],
      workingDirectory: Directory.current.path,
      environment: Platform.environment,
      stdoutPath: outPath,
      stderrPath: errPath,
    );
    final handle = FfiLauncher().start(spec);
    await Future<void>.delayed(const Duration(seconds: 2));
    await handle.terminate(grace: const Duration(seconds: 1));
    handle.close();
    final out = File(outPath).existsSync()
        ? File(outPath).readAsStringSync()
        : '<missing>';
    // ignore: avoid_print
    print('out=$out');
    expect(out, contains('hi'));
  });
}
