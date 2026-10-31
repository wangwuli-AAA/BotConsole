import 'dart:typed_data';

/// 子进程环境变量构造。
///
/// 纯函数，方便单元测试；不接触 `dart:io` 以外的系统状态。

const String kNoProxyValue = 'localhost,127.0.0.1,::1';

/// 由父进程环境 + 代理设置 + 服务特有变量 + 用户自定义变量，合成最终环境。
///
/// [useProxy] 为 true 时注入 `HTTP_PROXY` 等变量（与现有 start_mai.bat 行为一致）；
/// [pythonUtf8] 为 true 时（MaiBot）注入 `PYTHONIOENCODING=utf-8` 与
/// `PYTHONUNBUFFERED=1`，让日志落盘就是 UTF-8，不必再按 GBK 解码。
/// [extraEnvText] 是多行 `KEY=VALUE`；`!KEY` 表示删除该变量；空行与 `#` 开头忽略。
Map<String, String> buildEnvironment({
  required Map<String, String> base,
  required bool useProxy,
  required String proxyUrl,
  required bool pythonUtf8,
  String extraEnvText = '',
}) {
  final env = <String, String>{...base};

  final url = proxyUrl.trim();
  if (useProxy && url.isNotEmpty) {
    for (final key in const ['HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY']) {
      env[key] = url;
      env[key.toLowerCase()] = url;
    }
    env['NO_PROXY'] = kNoProxyValue;
    env['no_proxy'] = kNoProxyValue;
  }

  if (pythonUtf8) {
    env['PYTHONIOENCODING'] = 'utf-8';
    env['PYTHONUNBUFFERED'] = '1';
  }

  for (final entry in parseEnvLines(extraEnvText).entries) {
    if (entry.value == null) {
      env.remove(entry.key);
    } else {
      env[entry.key] = entry.value!;
    }
  }
  return env;
}

/// 解析多行 `KEY=VALUE`（`!KEY` → 值为 null 表示删除）。
Map<String, String?> parseEnvLines(String text) {
  final result = <String, String?>{};
  for (final raw in text.split(RegExp(r'\r?\n'))) {
    final line = raw.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    if (line.startsWith('!')) {
      final key = line.substring(1).trim();
      if (key.isNotEmpty) result[key] = null;
      continue;
    }
    final idx = line.indexOf('=');
    if (idx <= 0) continue;
    final key = line.substring(0, idx).trim();
    final value = line.substring(idx + 1).trim();
    if (key.isEmpty) continue;
    result[key] = value;
  }
  return result;
}

/// 把环境变量编码成 `CreateProcessW` 需要的 UTF-16 环境块：
/// `KEY=VALUE\0KEY=VALUE\0\0`（Windows 约定按键名不区分大小写排序）。
Uint16List encodeEnvironmentBlock(Map<String, String> env) {
  final keys = env.keys.toList()
    ..sort((a, b) {
      final lower = a.toLowerCase().compareTo(b.toLowerCase());
      return lower != 0 ? lower : a.compareTo(b);
    });
  final units = <int>[];
  for (final key in keys) {
    final pair = '$key=${env[key]}';
    for (final codeUnit in pair.codeUnits) {
      units.add(codeUnit);
    }
    units.add(0);
  }
  units.add(0);
  return Uint16List.fromList(units);
}

/// Windows 命令行参数转义（遵循 CommandLineToArgvW 的规则）。
String quoteWindowsArg(String arg) {
  if (arg.isEmpty) return '""';
  if (!RegExp(r'[\s"]').hasMatch(arg)) return arg;
  final buffer = StringBuffer('"');
  var backslashes = 0;
  for (final ch in arg.split('')) {
    if (ch == r'\') {
      backslashes++;
      continue;
    }
    if (ch == '"') {
      buffer.write('\\' * (backslashes * 2 + 1));
      buffer.write('"');
      backslashes = 0;
      continue;
    }
    buffer.write('\\' * backslashes);
    buffer.write(ch);
    backslashes = 0;
  }
  buffer.write('\\' * (backslashes * 2));
  buffer.write('"');
  return buffer.toString();
}

/// 拼出完整命令行（第 0 个参数是可执行文件本身）。
String buildCommandLine(String executable, List<String> arguments) {
  final parts = <String>['"$executable"', ...arguments.map(quoteWindowsArg)];
  return parts.join(' ');
}
