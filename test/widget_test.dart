import 'package:bot_console/core/settings.dart';
import 'package:bot_console/core/env_builder.dart';
import 'package:bot_console/services/whitelist_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('默认配置可自检', () {
    final settings = AppSettings.defaults();
    expect(settings.hosts.snowlumaHttp, 3000);
    expect(settings.hosts.maibotWebui, 8001);
    expect(settings.maibot.entry, 'bot.py');
    expect(settings.maibotToken, isEmpty);
  });

  test('环境变量块按 key 排序且以 NUL 结尾', () {
    final block = encodeEnvironmentBlock({'B': '2', 'A': '1'});
    final text = String.fromCharCodes(block);
    expect(text, startsWith('A=1\u0000B=2\u0000'));
  });

  test('命令行引号拼装', () {
    expect(quoteWindowsArg(r'D:\a b\x.exe'), r'"D:\a b\x.exe"');
    expect(buildCommandLine('a.exe', ['x y']), '"a.exe" "x y"');
  });

  test('白名单文件文本改写保留注释', () {
    const source = '''
# 注释
[defaults.group]
list_type = "whitelist"
ids = ["111111"]
''';
    final updated = writeIds(source, sectionGroup, ['222222', '333333']);
    expect(updated.contains('# 注释'), isTrue);
    expect(readIds(updated, sectionGroup), ['222222', '333333']);
    expect(readListType(updated, sectionGroup), 'whitelist');
  });
}
