import 'dart:io';

import 'package:bot_console/core/proc_launcher.dart';
import 'package:bot_console/core/settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('FFI 能无窗口拉起进程并写日志', () async {
    final dir = Directory.systemTemp.createTempSync('bc_launch_');
    final outPath = p.join(dir.path, 'out.log');
    final errPath = p.join(dir.path, 'err.log');
    final spec = LaunchSpec(
      name: 'snowluma',
      executable: resolveNodeExe(),
      arguments: const [
        '-e',
        'console.log("hello from child"); setTimeout(()=>{}, 1500)',
      ],
      workingDirectory: dir.path,
      environment: {'PATH': Platform.environment['PATH'] ?? ''},
      stdoutPath: outPath,
      stderrPath: errPath,
    );

    final handle = FfiLauncher().start(spec);
    // ignore: avoid_print
    print('started pid=${handle.pid}');
    await Future<void>.delayed(const Duration(seconds: 3));
    final out = File(outPath).existsSync()
        ? File(outPath).readAsStringSync()
        : '<missing>';
    final err = File(errPath).existsSync()
        ? File(errPath).readAsStringSync()
        : '<missing>';
    // ignore: avoid_print
    print('stdout file: $out');
    // ignore: avoid_print
    print('stderr file: $err');
    await handle.terminate(grace: const Duration(seconds: 2));
    handle.close();
    dir.deleteSync(recursive: true);
    expect(out, contains('hello from child'));
  });
}
