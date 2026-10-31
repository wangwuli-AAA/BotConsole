import 'dart:io';

import 'package:path/path.dart' as p;

/// 聊天白名单文件（`config\adapter_policy.toml`）的读写。
///
/// 采用**文本级**修改：只替换 `ids = [...]` 那一行（或跨行数组的几行），
/// 注释、顺序、其它段落全部原样保留。MaiBot 侧对该文件有监视器，
/// 改完无需重启即生效。
class WhitelistSnapshot {
  const WhitelistSnapshot({
    required this.raw,
    required this.groupIds,
    required this.privateIds,
    required this.groupListType,
    required this.privateListType,
  });

  final String raw;
  final List<String> groupIds;
  final List<String> privateIds;
  final String groupListType;
  final String privateListType;

  bool get groupIsWhitelist => groupListType != 'blacklist';

  bool get privateIsWhitelist => privateListType != 'blacklist';
}

const String sectionGroup = 'defaults.group';
const String sectionPrivate = 'defaults.private';

/// 群号 / QQ 号格式校验。
bool isValidChatId(String id) => RegExp(r'^\d{5,12}$').hasMatch(id.trim());

/// 判断 id 是否像群号（5~12 位数字），UI 校验用。
String? validateChatId(String id) {
  final value = id.trim();
  if (value.isEmpty) return '不能为空';
  if (!isValidChatId(value)) return '必须是 5~12 位数字';
  return null;
}

/// 读某段落的 `ids` 列表。
List<String> readIds(String toml, String section) {
  final lines = toml.split('\n');
  final range = _findSection(lines, section);
  if (range == null) return const [];
  final span = _findAssignmentSpan(lines, range.$1 + 1, range.$2, 'ids');
  if (span == null) return const [];
  final buffer = lines.sublist(span.$1, span.$2 + 1).join('\n');
  return _extractStrings(buffer);
}

/// 读某段落的 `list_type`（缺省返回 `"whitelist"`）。
String readListType(String toml, String section) {
  final lines = toml.split('\n');
  final range = _findSection(lines, section);
  if (range == null) return 'whitelist';
  final span = _findAssignmentSpan(lines, range.$1 + 1, range.$2, 'list_type');
  if (span == null) return 'whitelist';
  final values = _extractStrings(lines.sublist(span.$1, span.$2 + 1).join('\n'));
  if (values.isEmpty) return 'whitelist';
  return values.first == 'blacklist' ? 'blacklist' : 'whitelist';
}

/// 写入某段落的 `ids` 列表，返回新的文件文本。
String writeIds(String toml, String section, List<String> ids) {
  final normalized = _dedupe(ids);
  final array = normalized.map((id) => '"$id"').join(', ');
  return _writeAssignment(
    toml,
    section,
    'ids',
    'ids = [$array]',
    ensureSection: true,
  );
}

/// 写入 `list_type`。
String writeListType(String toml, String section, String listType) {
  final value = listType == 'blacklist' ? 'blacklist' : 'whitelist';
  return _writeAssignment(
    toml,
    section,
    'list_type',
    'list_type = "$value"',
    ensureSection: false,
  );
}

String _writeAssignment(
  String toml,
  String section,
  String key,
  String newLine, {
  required bool ensureSection,
}) {
  final lines = toml.split('\n');
  var range = _findSection(lines, section);
  if (range == null) {
    if (!ensureSection) return toml;
    if (lines.isNotEmpty && lines.last.trim().isEmpty) lines.removeLast();
    lines
      ..add('')
      ..add('[$section]')
      ..add('list_type = "whitelist"')
      ..add(newLine)
      ..add('');
    return lines.join('\n');
  }

  final span = _findAssignmentSpan(lines, range.$1 + 1, range.$2, key);
  if (span == null) {
    final indent = RegExp(r'^\s*').firstMatch(lines[range.$1])?.group(0) ?? '';
    lines.insert(range.$1 + 1, '$indent$newLine');
    return lines.join('\n');
  }

  final firstLine = lines[span.$1];
  final indent = RegExp(r'^\s*').firstMatch(firstLine)?.group(0) ?? '';
  final trailing = _trailingComment(lines.sublist(span.$1, span.$2 + 1).join('\n'));
  lines.replaceRange(span.$1, span.$2 + 1, ['$indent$newLine$trailing']);
  return lines.join('\n');
}

(int, int)? _findSection(List<String> lines, String section) {
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].trim() == '[$section]') {
      return (i, _sectionEnd(lines, i));
    }
  }
  return null;
}

int _sectionEnd(List<String> lines, int start) {
  for (var i = start + 1; i < lines.length; i++) {
    final trimmed = lines[i].trim();
    if (trimmed.startsWith('[') && trimmed.endsWith(']')) return i;
  }
  return lines.length;
}

/// 找到 `key = ...` 的起止行（数组跨行时一直读到 `]`）。
(int, int)? _findAssignmentSpan(List<String> lines, int from, int to, String key) {
  final pattern = RegExp('^\\s*$key\\s*=');
  for (var i = from; i < to; i++) {
    if (!pattern.hasMatch(lines[i])) continue;
    var end = i;
    if (lines[i].contains('[') && !lines[i].contains(']')) {
      while (end + 1 < to && !lines[end].contains(']')) {
        end++;
      }
    }
    return (i, end);
  }
  return null;
}

List<String> _extractStrings(String text) {
  final result = <String>[];
  final pattern = RegExp(r'"([^"]*)"|\x27([^\x27]*)\x27');
  for (final match in pattern.allMatches(text)) {
    final value = (match.group(1) ?? match.group(2) ?? '').trim();
    if (value.isNotEmpty) result.add(value);
  }
  if (result.isEmpty) {
    // 裸数字数组，例如 ids = [123456789]
    final bare = RegExp(r'\[\s*([\d,\s]+)\]').firstMatch(text);
    if (bare != null) {
      for (final part in bare.group(1)!.split(',')) {
        final value = part.trim();
        if (value.isNotEmpty) result.add(value);
      }
    }
  }
  return result;
}

String _trailingComment(String assignment) {
  final close = assignment.lastIndexOf(']');
  final candidate = close >= 0 ? assignment.substring(close + 1) : '';
  final hash = candidate.indexOf('#');
  if (hash < 0) return '';
  return '  ${candidate.substring(hash).trim()}';
}

List<String> _dedupe(List<String> ids) {
  final seen = <String>{};
  final result = <String>[];
  for (final id in ids) {
    final value = id.trim();
    if (value.isEmpty || !seen.add(value)) continue;
    result.add(value);
  }
  return result;
}

/// 白名单文件的读写封装。
class WhitelistStore {
  WhitelistStore(this.path);

  /// MaiBot 目录下的 `config/adapter_policy.toml`。
  final String path;

  bool get exists => File(path).existsSync();

  WhitelistSnapshot read() {
    final file = File(path);
    if (!file.existsSync()) {
      return const WhitelistSnapshot(
        raw: '',
        groupIds: [],
        privateIds: [],
        groupListType: 'whitelist',
        privateListType: 'whitelist',
      );
    }
    final raw = file.readAsStringSync();
    return WhitelistSnapshot(
      raw: raw,
      groupIds: readIds(raw, sectionGroup),
      privateIds: readIds(raw, sectionPrivate),
      groupListType: readListType(raw, sectionGroup),
      privateListType: readListType(raw, sectionPrivate),
    );
  }

  /// 生成新文本（不落盘），供 UI 预览与测试。
  String render({List<String>? groupIds, List<String>? privateIds}) {
    var text = File(path).existsSync() ? File(path).readAsStringSync() : '';
    if (groupIds != null) {
      text = writeListType(text, sectionGroup, 'whitelist');
      text = writeIds(text, sectionGroup, groupIds);
    }
    if (privateIds != null) {
      text = writeListType(text, sectionPrivate, 'whitelist');
      text = writeIds(text, sectionPrivate, privateIds);
    }
    return text;
  }

  /// 落盘：先备份，再原子写入，最后重读校验。
  WhitelistSnapshot save({required List<String> groupIds, required List<String> privateIds}) {
    final file = File(path);
    if (!file.parent.existsSync()) file.parent.createSync(recursive: true);
    if (file.existsSync()) {
      final stamp = _timestamp();
      file.copySync('$path.bak-$stamp');
    }
    final text = render(groupIds: groupIds, privateIds: privateIds);
    final tmp = File('$path.tmp');
    tmp.writeAsStringSync(text, flush: true);
    if (file.existsSync()) file.deleteSync();
    tmp.renameSync(path);

    final snapshot = read();
    final savedGroups = snapshot.groupIds.toSet();
    final savedPrivate = snapshot.privateIds.toSet();
    if (!_sameSet(savedGroups, groupIds.map((e) => e.trim()).toSet()) ||
        !_sameSet(savedPrivate, privateIds.map((e) => e.trim()).toSet())) {
      throw const WhitelistSaveException('写入后校验失败：文件内容与期望不一致');
    }
    return snapshot;
  }

  static bool _sameSet(Set<String> a, Set<String> b) =>
      a.length == b.length && a.containsAll(b);

  static String _timestamp() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${now.year}${two(now.month)}${two(now.day)}-'
        '${two(now.hour)}${two(now.minute)}${two(now.second)}';
  }

  /// 默认白名单文件位置（相对 MaiBot 目录）。
  static String defaultPathFor(String maiBotDir) =>
      p.join(maiBotDir, 'config', 'adapter_policy.toml');
}

class WhitelistSaveException implements Exception {
  const WhitelistSaveException(this.message);

  final String message;

  @override
  String toString() => message;
}
