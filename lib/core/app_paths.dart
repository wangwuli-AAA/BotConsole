import 'dart:io';

import 'package:path/path.dart' as p;

/// 应用数据目录与文件路径。
///
/// 默认位于 `%APPDATA%\BotConsole\`；设置环境变量 `BOTCONSOLE_HOME`
/// 可覆盖根目录（单元测试用这个，避免污染真实配置）。
class AppPaths {
  AppPaths._();

  static String? _base;
  static String? _logs;
  static String? logsWarning;

  static String get baseDir => _base ??= _resolveBaseDir();

  static String get settingsFile => p.join(baseDir, 'settings.json');

  static String get logsDir => _logs ?? p.join(baseDir, 'logs');

  static String get lockFile => p.join(baseDir, '.lock');

  static String _resolveBaseDir() {
    final override = Platform.environment['BOTCONSOLE_HOME'];
    if (override != null && override.trim().isNotEmpty) {
      return p.normalize(override.trim());
    }
    final appData = Platform.environment['APPDATA'];
    if (appData != null && appData.trim().isNotEmpty) {
      return p.join(appData, 'BotConsole');
    }
    final home = Platform.environment['USERPROFILE'];
    if (home != null && home.trim().isNotEmpty) {
      return p.join(home, 'AppData', 'Roaming', 'BotConsole');
    }
    return p.join(Directory.current.path, '.botconsole');
  }

  /// 创建根目录与日志目录（幂等）。
  static void ensureDirs() {
    try {
      Directory(baseDir).createSync(recursive: true);
    } on FileSystemException {
      // 日志可以落到备用目录；配置文件的读写错误会在对应操作时单独提示。
    }
    final preferred = p.join(baseDir, 'logs');
    try {
      _logs = resolveWritableLogsDir([
        preferred,
        if (Platform.environment['LOCALAPPDATA']?.trim().isNotEmpty ?? false)
          p.join(Platform.environment['LOCALAPPDATA']!, 'BotConsole', 'logs'),
        p.join(Directory.systemTemp.path, 'BotConsole', 'logs'),
      ]);
      logsWarning = _logs == preferred ? null : '默认日志目录不可写，日志目录已切换到：$_logs';
    } on FileSystemException catch (e) {
      // 仍允许打开界面修改配置；服务启动时会显示具体的文件错误。
      _logs = preferred;
      logsWarning = '没有可写的日志目录：$e';
    }
  }

  static String logFile(String name) => p.join(logsDir, name);

  /// 仅供测试：重置缓存，让下次访问重新读取环境变量。
  static void resetForTest() {
    _base = null;
    _logs = null;
    logsWarning = null;
  }
}

/// 检查实际的四个日志文件，避免目录可建但已有日志文件不可写。
String resolveWritableLogsDir(List<String> candidates) {
  final failures = <String>[];
  for (final directory in candidates.toSet()) {
    try {
      Directory(directory).createSync(recursive: true);
      for (final service in ['snowluma', 'maibot']) {
        for (final stream in ['out', 'err']) {
          File(
            p.join(directory, '$service.$stream.log'),
          ).openSync(mode: FileMode.append).closeSync();
        }
      }
      return directory;
    } on FileSystemException catch (e) {
      failures.add('$directory：${e.message}${e.osError == null ? '' : '（${e.osError}）'}');
    }
  }
  throw FileSystemException('日志目录均不可写：${failures.join('；')}');
}
