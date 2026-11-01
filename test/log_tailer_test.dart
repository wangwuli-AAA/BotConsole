import 'dart:convert';
import 'dart:io';

import 'package:bot_console/core/log_tailer.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory temp;
  late File file;
  setUp(() {
    temp = Directory.systemTemp.createTempSync('botconsole-log-');
    file = File('${temp.path}/service.log');
  });
  tearDown(() => temp.deleteSync(recursive: true));

  test(
    'large bursts drain in bounded chunks without losing complete lines',
    () {
      final lines = List.generate(4000, (i) => '$i ${'x' * 100}');
      file.writeAsStringSync('${lines.join('\n')}\n');
      final tailer = LogTailer(file.path);
      final first = tailer.readNew(fromStart: true);
      expect(first.length, lessThan(1000));
      final result = [...first];
      for (var i = 0; i < 10; i++) {
        result.addAll(tailer.readNew());
      }
      expect(result, lines);
    },
  );

  test('unterminated lines and log preview have bounded memory', () {
    file.writeAsStringSync('${'x' * (1024 * 1024)}\nend\n');
    final tailer = LogTailer(file.path);
    final result = <String>[];
    for (var i = 0; i < 20; i++) {
      result.addAll(tailer.readNew(fromStart: true));
    }
    expect(result.last, 'end');
    expect(result.first.length, lessThanOrEqualTo(128 * 1024));
    expect(LogTailer.readTail(file.path, maxBytes: 64 * 1024), ['end']);
  });

  test(
    'UTF-8 characters survive read boundaries and rotation resets decoder',
    () {
      file.writeAsBytesSync([
        ...List.filled(64 * 1024 - 1, 120),
        ...utf8.encode('适配器已连接 ws://test\n'),
      ]);
      final tailer = LogTailer(file.path);
      expect(tailer.readNew(fromStart: true), isEmpty);
      expect(tailer.readNew().single, endsWith('适配器已连接 ws://test'));
      file.writeAsStringSync('新日志\n');
      expect(tailer.readNew(), ['新日志']);
    },
  );
}
