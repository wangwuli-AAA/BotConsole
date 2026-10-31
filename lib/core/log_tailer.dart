import 'dart:convert';
import 'dart:io';

/// 日志增量读取（tail）。
///
/// 子进程的 stdout/stderr 由 [FfiLauncher] 直接写入文件，这里只按偏移读新增内容，
/// 用 UTF-8 解码（`allowMalformed: true`，遇到 GBK 残留也不会抛异常）。
class LogTailer {
  LogTailer(this.path);

  final String path;

  int _offset = 0;
  String _pending = '';
  bool _started = false;

  /// 读取自上次调用以来的新行。
  ///
  /// 首次调用默认从文件末尾开始（不重复显示历史），[fromStart] 为 true 则从头读。
  List<String> readNew({bool fromStart = false}) {
    final file = File(path);
    if (!file.existsSync()) return const [];

    final length = file.lengthSync();
    if (!_started) {
      _started = true;
      _offset = fromStart ? 0 : length;
    } else if (length < _offset) {
      // 文件被清空或轮转
      _offset = 0;
      _pending = '';
    }
    if (length <= _offset) return const [];

    List<int> bytes;
    final raf = file.openSync(mode: FileMode.read);
    try {
      raf.setPositionSync(_offset);
      bytes = raf.readSync(length - _offset);
      _offset = length;
    } finally {
      raf.closeSync();
    }

    final text = _pending + utf8.decode(bytes, allowMalformed: true);
    final lines = text.split('\n');
    _pending = lines.removeLast();
    return lines
        .map((line) => line.endsWith('\r') ? line.substring(0, line.length - 1) : line)
        .toList();
  }

  /// 跳到文件末尾（启动服务前调用，避免把上次运行的旧日志当新日志）。
  void seekToEnd() {
    final file = File(path);
    _started = true;
    _pending = '';
    _offset = file.existsSync() ? file.lengthSync() : 0;
  }

  void reset() {
    _started = false;
    _offset = 0;
    _pending = '';
  }

  /// 日志文件过大时轮转成 `.1`（最多保留一份旧的）。
  static void rotateIfLarge(String path, {int maxBytes = 20 * 1024 * 1024}) {
    final file = File(path);
    if (!file.existsSync()) return;
    if (file.lengthSync() < maxBytes) return;
    final backup = File('$path.1');
    try {
      if (backup.existsSync()) backup.deleteSync();
      file.renameSync(backup.path);
    } on FileSystemException {
      // 文件被占用（服务正在写）时跳过轮转，不影响启动
    }
  }

  /// 读取日志末尾若干行（用于界面首次展示）。
  static List<String> readTail(String path, {int maxLines = 3000}) {
    final file = File(path);
    if (!file.existsSync()) return const [];
    const chunk = 256 * 1024;
    final length = file.lengthSync();
    final start = length > chunk ? length - chunk : 0;
    final raf = file.openSync(mode: FileMode.read);
    try {
      raf.setPositionSync(start);
      final bytes = raf.readSync(length - start);
      final text = utf8.decode(bytes, allowMalformed: true);
      final lines = const LineSplitter().convert(text);
      if (start > 0 && lines.isNotEmpty) lines.removeAt(0); // 首行可能被截断
      if (lines.length > maxLines) {
        return lines.sublist(lines.length - maxLines);
      }
      return lines;
    } finally {
      raf.closeSync();
    }
  }
}
