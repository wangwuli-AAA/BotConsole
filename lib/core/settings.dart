import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// 配置模型与持久化。
///
/// 全部字段可变（界面直接改），保存时整体写回 `%APPDATA%\BotConsole\settings.json`。
/// 读取时保留未知键，避免未来版本/手工编辑的键被覆盖丢失。

/// SnowLuma 启动配置。
class SnowLumaSettings {
  SnowLumaSettings({
    required this.dir,
    required this.entry,
    required this.nodeExe,
  });

  /// SnowLuma 工作目录。
  String dir;

  /// 入口文件（相对 dir），默认 `index.mjs`
  String entry;

  /// node 可执行文件绝对路径
  String nodeExe;

  Map<String, dynamic> toJson() => {
    'dir': dir,
    'entry': entry,
    'nodeExe': nodeExe,
  };

  factory SnowLumaSettings.fromJson(
    Map<String, dynamic> json,
    SnowLumaSettings fallback,
  ) {
    return SnowLumaSettings(
      dir: _str(json['dir'], fallback.dir),
      entry: _str(json['entry'], fallback.entry),
      nodeExe: _str(json['nodeExe'], fallback.nodeExe),
    );
  }

  SnowLumaSettings copy() =>
      SnowLumaSettings(dir: dir, entry: entry, nodeExe: nodeExe);
}

/// MaiBot 启动配置。
class MaiBotSettings {
  MaiBotSettings({
    required this.dir,
    required this.pythonExe,
    required this.entry,
  });

  String dir;

  /// Python 解释器；相对路径时相对 [dir] 解析，默认 `.venv\Scripts\python.exe`
  String pythonExe;

  /// 入口文件（相对 dir），默认 `bot.py`
  String entry;

  String get pythonExeResolved => p.isAbsolute(pythonExe)
      ? p.normalize(pythonExe)
      : p.normalize(p.join(dir, pythonExe));

  String get entryResolved => p.isAbsolute(entry) ? entry : p.join(dir, entry);

  Map<String, dynamic> toJson() => {
    'dir': dir,
    'pythonExe': pythonExe,
    'entry': entry,
  };

  factory MaiBotSettings.fromJson(
    Map<String, dynamic> json,
    MaiBotSettings fallback,
  ) {
    return MaiBotSettings(
      dir: _str(json['dir'], fallback.dir),
      pythonExe: _str(json['pythonExe'], fallback.pythonExe),
      entry: _str(json['entry'], fallback.entry),
    );
  }

  MaiBotSettings copy() =>
      MaiBotSettings(dir: dir, pythonExe: pythonExe, entry: entry);
}

/// 端口与主机配置（“bot 地址”）。
class HostSettings {
  HostSettings({
    this.host = '127.0.0.1',
    this.snowlumaHttp = 3000,
    this.snowlumaWs = 3001,
    this.snowlumaWebui = 5099,
    this.maibotWs = 8000,
    this.maibotWebui = 8001,
  });

  String host;
  int snowlumaHttp;
  int snowlumaWs;
  int snowlumaWebui;
  int maibotWs;
  int maibotWebui;

  String get snowlumaWebuiUrl => 'http://$host:$snowlumaWebui/';
  String get maibotWebuiUrl => 'http://$host:$maibotWebui/';

  Map<String, dynamic> toJson() => {
    'host': host,
    'snowlumaHttp': snowlumaHttp,
    'snowlumaWs': snowlumaWs,
    'snowlumaWebui': snowlumaWebui,
    'maibotWs': maibotWs,
    'maibotWebui': maibotWebui,
  };

  factory HostSettings.fromJson(Map<String, dynamic> json) {
    final d = HostSettings();
    return HostSettings(
      host: _str(json['host'], d.host),
      snowlumaHttp: _int(json['snowlumaHttp'], d.snowlumaHttp),
      snowlumaWs: _int(json['snowlumaWs'], d.snowlumaWs),
      snowlumaWebui: _int(json['snowlumaWebui'], d.snowlumaWebui),
      maibotWs: _int(json['maibotWs'], d.maibotWs),
      maibotWebui: _int(json['maibotWebui'], d.maibotWebui),
    );
  }

  HostSettings copy() => HostSettings.fromJson(toJson());

  List<String> validate() {
    final errors = <String>[];
    if (host.trim().isEmpty) errors.add('主机地址不能为空');
    for (final entry in {
      'SnowLuma HTTP 端口': snowlumaHttp,
      'SnowLuma WS 端口': snowlumaWs,
      'SnowLuma WebUI 端口': snowlumaWebui,
      'MaiBot WS 端口': maibotWs,
      'MaiBot WebUI 端口': maibotWebui,
    }.entries) {
      final v = entry.value;
      if (v < 1 || v > 65535) errors.add('${entry.key} 必须是 1~65535（当前 $v）');
    }
    final ports = [
      snowlumaHttp,
      snowlumaWs,
      snowlumaWebui,
      maibotWs,
      maibotWebui,
    ];
    if (ports.toSet().length != ports.length) errors.add('端口不能重复');
    return errors;
  }
}

/// 代理配置。
class ProxySettings {
  ProxySettings({this.autoDetect = true, this.url = 'http://127.0.0.1:7897'});

  bool autoDetect;
  String url;

  Map<String, dynamic> toJson() => {'autoDetect': autoDetect, 'url': url};

  factory ProxySettings.fromJson(Map<String, dynamic> json) {
    final d = ProxySettings();
    return ProxySettings(
      autoDetect: _bool(json['autoDetect'], d.autoDetect),
      url: _str(json['url'], d.url),
    );
  }

  ProxySettings copy() => ProxySettings.fromJson(toJson());
}

/// 界面行为配置。
class UiSettings {
  UiSettings({this.confirmOnClose = true, this.autoStart = false});

  bool confirmOnClose;
  bool autoStart;

  Map<String, dynamic> toJson() => {
    'confirmOnClose': confirmOnClose,
    'autoStart': autoStart,
  };

  factory UiSettings.fromJson(Map<String, dynamic> json) {
    final d = UiSettings();
    return UiSettings(
      confirmOnClose: _bool(json['confirmOnClose'], d.confirmOnClose),
      autoStart: _bool(json['autoStart'], d.autoStart),
    );
  }

  UiSettings copy() => UiSettings.fromJson(toJson());
}

/// 完整配置。
class AppSettings {
  AppSettings({
    required this.snowluma,
    required this.maibot,
    required this.hosts,
    required this.proxy,
    required this.ui,
    this.extraEnv = const [],
    this.maibotToken = '',
    this.usageDatabasePath = '',
  });

  SnowLumaSettings snowluma;
  MaiBotSettings maibot;
  HostSettings hosts;
  ProxySettings proxy;
  UiSettings ui;

  /// 额外环境变量，每行 `KEY=VALUE`
  List<String> extraEnv;

  /// MaiBot WebUI 登录令牌
  String maibotToken;

  /// 留空时使用 MaiBot 目录下的 data/MaiBot.db。
  String usageDatabasePath;
  String get usageDatabaseResolved => usageDatabasePath.trim().isEmpty
      ? p.join(maibot.dir, 'data', 'MaiBot.db')
      : usageDatabasePath.trim();

  /// 读取时保留下来的未知键（保存时原样写回）。
  Map<String, dynamic> unknownKeys = {};

  Map<String, dynamic> toJson() => {
    'snowluma': snowluma.toJson(),
    'maibot': maibot.toJson(),
    'hosts': hosts.toJson(),
    'proxy': proxy.toJson(),
    'ui': ui.toJson(),
    'env': {'extra': extraEnv},
    'maibotToken': maibotToken,
    'usageDatabasePath': usageDatabasePath,
    ...unknownKeys,
  };

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    final defaults = AppSettings.defaults();
    final settings = AppSettings(
      snowluma: SnowLumaSettings.fromJson(
        _map(json['snowluma']),
        defaults.snowluma,
      ),
      maibot: MaiBotSettings.fromJson(_map(json['maibot']), defaults.maibot),
      hosts: HostSettings.fromJson(_map(json['hosts'])),
      proxy: ProxySettings.fromJson(_map(json['proxy'])),
      ui: UiSettings.fromJson(_map(json['ui'])),
      extraEnv: _stringList(_map(json['env'])['extra'], defaults.extraEnv),
      maibotToken: _str(json['maibotToken'], defaults.maibotToken),
      usageDatabasePath: _str(json['usageDatabasePath'], ''),
    );
    const known = {
      'snowluma',
      'maibot',
      'hosts',
      'proxy',
      'ui',
      'env',
      'maibotToken',
      'usageDatabasePath',
    };
    for (final key in json.keys) {
      if (!known.contains(key)) settings.unknownKeys[key] = json[key];
    }
    return settings;
  }

  /// 默认配置：探测应用旁或当前目录下的服务目录。
  factory AppSettings.defaults() {
    final appDir = p.dirname(Platform.resolvedExecutable);
    final snowlumaDir = _pickDir([
      p.join(appDir, 'SnowLuma'),
      p.join(appDir, '..', 'SnowLuma'),
      p.join(Directory.current.path, 'SnowLuma'),
      p.join(Directory.current.path, '..', 'SnowLuma'),
    ]);
    final maibotDir = _pickDir([
      p.join(appDir, 'MaiBot'),
      p.join(appDir, '..', 'MaiBot'),
      p.join(Directory.current.path, 'MaiBot'),
      p.join(Directory.current.path, '..', 'MaiBot'),
    ]);
    return AppSettings(
      snowluma: SnowLumaSettings(
        dir: snowlumaDir,
        entry: 'index.mjs',
        nodeExe: resolveNodeExe(),
      ),
      maibot: MaiBotSettings(
        dir: maibotDir,
        pythonExe: r'.venv\Scripts\python.exe',
        entry: 'bot.py',
      ),
      hosts: HostSettings(),
      proxy: ProxySettings(),
      ui: UiSettings(),
      extraEnv: const [],
    );
  }

  AppSettings copy() => AppSettings.fromJson(toJson());

  /// 启动前校验，返回中文错误列表（空 = 通过）。
  List<String> validate() => [
    ...hosts.validate(),
    ...validateSnowLuma(),
    ...validateMaiBot(),
  ];

  /// 仅校验 SnowLuma。
  List<String> validateSnowLuma() {
    final errors = <String>[];
    if (!Directory(snowluma.dir).existsSync()) {
      errors.add('SnowLuma 目录不存在：${snowluma.dir}');
    }
    if (!File(snowluma.nodeExe).existsSync()) {
      errors.add('node 可执行文件不存在：${snowluma.nodeExe}');
    }
    final entry = File(p.join(snowluma.dir, snowluma.entry));
    if (!entry.existsSync()) {
      errors.add('SnowLuma 入口文件不存在：${entry.path}');
    }
    return errors;
  }

  /// 仅校验 MaiBot。
  List<String> validateMaiBot() {
    final errors = <String>[];
    if (!Directory(maibot.dir).existsSync()) {
      errors.add('MaiBot 目录不存在：${maibot.dir}');
    }
    if (!File(maibot.pythonExeResolved).existsSync()) {
      errors.add('MaiBot Python 解释器不存在：${maibot.pythonExeResolved}');
    }
    if (!File(maibot.entryResolved).existsSync()) {
      errors.add('MaiBot 入口文件不存在：${maibot.entryResolved}');
    }
    return errors;
  }
}

/// 读写 settings.json。
class SettingsStore {
  SettingsStore(this.path);

  final String path;

  /// 读取配置；文件不存在返回默认值；JSON 损坏时备份后用默认值。
  AppSettings load() {
    final file = File(path);
    if (!file.existsSync()) {
      return AppSettings.defaults();
    }
    try {
      final text = file.readAsStringSync();
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('根节点不是 JSON 对象');
      }
      return AppSettings.fromJson(decoded);
    } catch (e) {
      _backupCorrupt(file);
      return AppSettings.defaults();
    }
  }

  /// 保存配置（先写临时文件再替换，避免半截文件）。
  void save(AppSettings settings) {
    final file = File(path);
    final dir = file.parent;
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final tmp = File('$path.tmp');
    const encoder = JsonEncoder.withIndent('  ');
    tmp.writeAsStringSync(
      '${encoder.convert(settings.toJson())}\n',
      flush: true,
    );
    if (file.existsSync()) file.deleteSync();
    tmp.renameSync(path);
  }

  void _backupCorrupt(File file) {
    try {
      final stamp = _timestamp();
      file.copySync('$path.corrupt-$stamp');
    } catch (_) {
      // 备份失败不影响启动
    }
  }

  static String _timestamp() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${now.year}${two(now.month)}${two(now.day)}-'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
  }
}

/// 优先从 PATH 查找 Node，再检查 Windows 标准安装目录。
String resolveNodeExe() {
  final pathVar = Platform.environment['PATH'] ?? '';
  for (final dir in pathVar.split(';')) {
    if (dir.trim().isEmpty) continue;
    final exe = File(p.join(dir.trim(), 'node.exe'));
    if (exe.existsSync()) return exe.path;
  }
  final programFiles = Platform.environment['ProgramFiles'];
  if (programFiles != null) {
    final standard = p.join(programFiles, 'nodejs', 'node.exe');
    if (File(standard).existsSync()) return standard;
  }
  return 'node.exe';
}

String _pickDir(List<String> candidates) {
  for (final c in candidates) {
    if (Directory(c).existsSync()) return p.normalize(c);
  }
  return p.normalize(candidates.first);
}

Map<String, dynamic> _map(Object? value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return value.map((k, v) => MapEntry('$k', v));
  return <String, dynamic>{};
}

String _str(Object? value, String fallback) {
  if (value is String && value.trim().isNotEmpty) return value;
  return fallback;
}

int _int(Object? value, int fallback) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) {
    final parsed = int.tryParse(value.trim());
    if (parsed != null) return parsed;
  }
  return fallback;
}

bool _bool(Object? value, bool fallback) {
  if (value is bool) return value;
  if (value is String) {
    final v = value.trim().toLowerCase();
    if (v == 'true' || v == '1') return true;
    if (v == 'false' || v == '0') return false;
  }
  return fallback;
}

List<String> _stringList(Object? value, List<String> fallback) {
  if (value is List) {
    return value.map((e) => '$e').where((e) => e.trim().isNotEmpty).toList();
  }
  return List<String>.from(fallback);
}
