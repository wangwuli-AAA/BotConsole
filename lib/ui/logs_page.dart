import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app.dart';
import '../core/log_tailer.dart';
import '../services/service_controller.dart';
import 'theme.dart';

/// 日志查看（自动增量刷新）。
class LogsPage extends StatefulWidget {
  const LogsPage({super.key, this.active = true});
  final bool active;

  @override
  State<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends State<LogsPage> {
  ServiceKind _kind = ServiceKind.snowluma;
  bool _showError = false;
  bool _follow = true;
  String _content = '';
  String? _error;
  Timer? _timer;
  final ScrollController _scroll = ScrollController();
  String? _lastPath;
  int? _lastSize;
  DateTime? _lastModified;
  List<String> _lines = const [];

  @override
  void initState() {
    super.initState();
    _startPolling();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  void _startPolling() {
    _timer?.cancel();
    if (widget.active) {
      _timer = Timer.periodic(
        const Duration(milliseconds: 1200),
        (_) => _poll(),
      );
    }
  }

  @override
  void didUpdateWidget(covariant LogsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) {
      _startPolling();
      if (widget.active) _reload();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  String _pathFor(ServiceKind kind, bool error) {
    final state = AppScope.of(context);
    return error
        ? state.controller.errLogPath(kind)
        : state.controller.outLogPath(kind);
  }

  void _reload({bool force = true}) {
    if (!mounted || !widget.active) return;
    final path = _pathFor(_kind, _showError);
    try {
      final stat = File(path).statSync();
      if (!force &&
          _error == null &&
          path == _lastPath &&
          stat.size == _lastSize &&
          stat.modified == _lastModified) {
        return;
      }
      final lines = LogTailer.readTail(
        path,
        maxLines: 400,
        maxBytes: 64 * 1024,
      );
      final text = lines.join('\n');
      _lastPath = path;
      _lastSize = stat.size;
      _lastModified = stat.modified;
      if (text == _content && _error == null) return;
      setState(() {
        _lines = lines;
        _content = text;
        _error = null;
      });
      if (_follow) _scrollToBottom();
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    }
  }

  void _poll() {
    if (!mounted) return;
    if (!_follow) return;
    _reload(force: false);
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '日志',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      '两个服务的 stdout / stderr 全部落在这里，边跑边看',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ],
                ),
              ),
              SegmentedButton<ServiceKind>(
                segments: [
                  for (final kind in ServiceKind.values)
                    ButtonSegment(value: kind, label: Text(kind.label)),
                ],
                selected: {_kind},
                onSelectionChanged: (value) {
                  setState(() => _kind = value.first);
                  _reload();
                },
                showSelectedIcon: false,
              ),
              const SizedBox(width: 10),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('stdout')),
                  ButtonSegment(value: true, label: Text('stderr')),
                ],
                selected: {_showError},
                onSelectionChanged: (value) {
                  setState(() => _showError = value.first);
                  _reload();
                },
                showSelectedIcon: false,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: SelectableText(
                  _pathFor(_kind, _showError),
                  style: const TextStyle(
                    fontSize: 11,
                    fontFamily: 'Consolas',
                    color: AppColors.textMuted,
                  ),
                ),
              ),
              FilterChip(
                label: const Text('自动滚动'),
                selected: _follow,
                onSelected: (value) {
                  setState(() => _follow = value);
                  if (value) {
                    _reload();
                    _scrollToBottom();
                  }
                },
              ),
              const SizedBox(width: 8),
              IconButton(
                tooltip: '刷新',
                onPressed: _reload,
                icon: const Icon(Icons.refresh_rounded, size: 18),
              ),
              IconButton(
                tooltip: '复制全部',
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: _content));
                  if (mounted) {
                    // ignore: use_build_context_synchronously
                    showInfo(context, '已复制 ${_content.length} 字符');
                  }
                },
                icon: const Icon(Icons.copy_all_rounded, size: 18),
              ),
              IconButton(
                tooltip: '用记事本打开',
                onPressed: () async {
                  final path = _pathFor(_kind, _showError);
                  if (!File(path).existsSync()) {
                    showError(context, '文件还不存在：$path');
                    return;
                  }
                  try {
                    await Process.start('notepad.exe', [
                      path,
                    ], mode: ProcessStartMode.detached);
                  } catch (e) {
                    if (mounted) {
                      // ignore: use_build_context_synchronously
                      showError(context, '$e');
                    }
                  }
                },
                icon: const Icon(Icons.open_in_new_rounded, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFF0C0E13),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.border),
              ),
              child: _error != null
                  ? Center(
                      child: Text(
                        _error!,
                        style: const TextStyle(
                          color: AppColors.danger,
                          fontSize: 12,
                        ),
                      ),
                    )
                  : Scrollbar(
                      controller: _scroll,
                      thumbVisibility: true,
                      child: SelectionArea(
                        child: ListView.builder(
                          controller: _scroll,
                          padding: const EdgeInsets.all(14),
                          itemCount: _lines.isEmpty ? 1 : _lines.length,
                          itemBuilder: (context, index) => Text(
                            _lines.isEmpty ? '（暂无日志）' : _lines[index],
                            style: TextStyle(
                              fontSize: 11.5,
                              height: 1.5,
                              fontFamily: 'Consolas',
                              color: _lines.isEmpty
                                  ? AppColors.textMuted
                                  : AppColors.textPrimary,
                            ),
                          ),
                        ),
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              '${state.controller.statusOf(_kind).state.name} · 末尾 400 行 / 64 KB · 每 1.2 秒检查更新',
              style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
            ),
          ),
        ],
      ),
    );
  }
}
