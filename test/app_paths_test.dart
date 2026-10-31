import 'dart:io';

import 'package:bot_console/core/app_paths.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('bc_paths_'));
  tearDown(() => root.deleteSync(recursive: true));

  test('优先使用默认目录，保留已有日志内容', () {
    final log = File(p.join(root.path, 'snowluma.out.log'))
      ..writeAsStringSync('existing log\n');
    final fallback = p.join(root.path, 'unused');

    expect(resolveWritableLogsDir([root.path, fallback]), root.path);
    expect(log.readAsStringSync(), 'existing log\n');
    expect(Directory(fallback).existsSync(), isFalse);
    expect(File(p.join(root.path, 'maibot.err.log')).existsSync(), isTrue);
  });

  test('默认目录不可创建时切换到备用目录', () {
    final blocked = File(p.join(root.path, 'blocked'))..writeAsStringSync('');
    final fallback = p.join(root.path, 'fallback');

    expect(
      resolveWritableLogsDir([p.join(blocked.path, 'logs'), fallback]),
      fallback,
    );
  });

  test('已有日志无法打开时也切换目录', () {
    Directory(p.join(root.path, 'snowluma.out.log')).createSync();
    final fallback = p.join(root.path, 'fallback');

    expect(resolveWritableLogsDir([root.path, fallback]), fallback);
  });

  test('全部目录不可写时保留每个失败位置', () {
    final blocked = File(p.join(root.path, 'blocked'))..writeAsStringSync('');
    final candidates = [
      p.join(blocked.path, 'one'),
      p.join(blocked.path, 'two'),
    ];

    expect(
      () => resolveWritableLogsDir(candidates),
      throwsA(
        isA<FileSystemException>().having(
          (e) => e.message,
          'message',
          allOf(contains(candidates[0]), contains(candidates[1])),
        ),
      ),
    );
  });
}
