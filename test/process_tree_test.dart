import 'dart:convert';
import 'dart:io';

import 'package:bot_console/core/port_probe.dart';
import 'package:bot_console/core/proc_launcher.dart';
import 'package:bot_console/core/settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('关闭 Job 句柄时结束主进程及其子进程', () async {
    final dir = Directory.systemTemp.createTempSync('bc_tree_');
    LaunchHandle? handle;
    int? childPid;
    try {
      final childScript = File(p.join(dir.path, 'child.js'))
        ..writeAsStringSync('''
const net = require('net');
const server = net.createServer();
server.listen(0, '127.0.0.1', () => {
  console.log(JSON.stringify({pid: process.pid, port: server.address().port}));
});
''');
      final node = resolveNodeExe();
      final output = p.join(dir.path, 'out.log');
      handle = const FfiLauncher().start(
        LaunchSpec(
          name: 'tree-test',
          executable: node,
          arguments: [
            '-e',
            "require('child_process').spawn(process.execPath, [process.argv[1]], "
                "{stdio: ['ignore', 'inherit', 'inherit']}); setInterval(() => {}, 1000);",
            childScript.path,
          ],
          workingDirectory: dir.path,
          environment: Platform.environment,
          stdoutPath: output,
          stderrPath: p.join(dir.path, 'err.log'),
        ),
      );
      var text = '';
      final readyDeadline = DateTime.now().add(const Duration(seconds: 10));
      while (DateTime.now().isBefore(readyDeadline)) {
        text = File(output).readAsStringSync();
        if (text.contains('\n')) break;
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(text, isNotEmpty, reason: '子进程应先成功监听临时端口');
      final info = jsonDecode(text.trim()) as Map<String, dynamic>;
      childPid = info['pid'] as int;
      final port = info['port'] as int;
      expect(await isTcpOpen('127.0.0.1', port), isTrue);
      expect(handle.isAlive, isTrue);

      // 模拟应用退出/崩溃时仅关闭句柄，验证 KILL_ON_JOB_CLOSE 确实生效。
      handle.close();
      var open = true;
      final exitDeadline = DateTime.now().add(const Duration(seconds: 3));
      while (open && DateTime.now().isBefore(exitDeadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        open = await isTcpOpen('127.0.0.1', port);
      }
      expect(open, isFalse, reason: '主进程退出后，子进程不能继续占用端口');
    } finally {
      if (childPid != null) await terminateProcessById(childPid);
      if (handle != null) await terminateProcessById(handle.pid);
      handle?.close();
      dir.deleteSync(recursive: true);
    }
  }, skip: !Platform.isWindows);
}
