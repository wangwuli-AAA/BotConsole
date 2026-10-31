import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../app.dart';
import '../core/app_paths.dart';
import '../core/settings.dart';
import 'theme.dart';
import 'widgets.dart';

/// 路径与端口配置。
class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  late AppSettings _draft;
  late final Map<String, TextEditingController> _controllers;
  bool _dirty = false;
  bool _initialized = false;
  List<String> _errors = const [];

  static const List<String> _textKeys = [
    'snowluma.dir',
    'snowluma.entry',
    'snowluma.nodeExe',
    'maibot.dir',
    'maibot.pythonExe',
    'maibot.entry',
    'maibot.token',
    'usageDatabasePath',
    'hosts.host',
    'hosts.snowlumaHttp',
    'hosts.snowlumaWs',
    'hosts.snowlumaWebui',
    'hosts.maibotWs',
    'hosts.maibotWebui',
    'proxy.url',
    'env.extra',
  ];

  @override
  void initState() {
    super.initState();
    _controllers = {
      for (final key in _textKeys) key: TextEditingController(),
    };
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_initialized) return;
    _initialized = true;
    _draft = AppScope.of(context).settings.copy();
    _syncControllers();
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _syncControllers() {
    _controllers['snowluma.dir']!.text = _draft.snowluma.dir;
    _controllers['snowluma.entry']!.text = _draft.snowluma.entry;
    _controllers['snowluma.nodeExe']!.text = _draft.snowluma.nodeExe;
    _controllers['maibot.dir']!.text = _draft.maibot.dir;
    _controllers['maibot.pythonExe']!.text = _draft.maibot.pythonExe;
    _controllers['maibot.entry']!.text = _draft.maibot.entry;
    _controllers['maibot.token']!.text = _draft.maibotToken;
    _controllers['usageDatabasePath']!.text = _draft.usageDatabasePath;
    _controllers['env.extra']!.text = _draft.extraEnv.join('\n');
    _controllers['hosts.host']!.text = _draft.hosts.host;
    _controllers['hosts.snowlumaHttp']!.text = '${_draft.hosts.snowlumaHttp}';
    _controllers['hosts.snowlumaWs']!.text = '${_draft.hosts.snowlumaWs}';
    _controllers['hosts.snowlumaWebui']!.text = '${_draft.hosts.snowlumaWebui}';
    _controllers['hosts.maibotWs']!.text = '${_draft.hosts.maibotWs}';
    _controllers['hosts.maibotWebui']!.text = '${_draft.hosts.maibotWebui}';
    _controllers['proxy.url']!.text = _draft.proxy.url;
    setState(() => _dirty = false);
  }

  void _markDirty() {
    if (!_dirty) setState(() => _dirty = true);
  }

  AppSettings _collect() {
    int parse(String key, int fallback) =>
        int.tryParse(_controllers[key]!.text.trim()) ?? fallback;
    final next = _draft.copy();
    next.snowluma.dir = _controllers['snowluma.dir']!.text.trim();
    next.snowluma.entry = _controllers['snowluma.entry']!.text.trim();
    next.snowluma.nodeExe = _controllers['snowluma.nodeExe']!.text.trim();
    next.maibot.dir = _controllers['maibot.dir']!.text.trim();
    next.maibot.pythonExe = _controllers['maibot.pythonExe']!.text.trim();
    next.maibot.entry = _controllers['maibot.entry']!.text.trim();
    next.maibotToken = _controllers['maibot.token']!.text.trim();
    next.usageDatabasePath = _controllers['usageDatabasePath']!.text.trim();
    next.extraEnv = _controllers['env.extra']!
        .text
        .split('\n')
        .map((line) => line.trim())
        .where((line) => line.isNotEmpty)
        .toList();
    next.hosts.host = _controllers['hosts.host']!.text.trim();
    next.hosts.snowlumaHttp = parse('hosts.snowlumaHttp', next.hosts.snowlumaHttp);
    next.hosts.snowlumaWs = parse('hosts.snowlumaWs', next.hosts.snowlumaWs);
    next.hosts.snowlumaWebui =
        parse('hosts.snowlumaWebui', next.hosts.snowlumaWebui);
    next.hosts.maibotWs = parse('hosts.maibotWs', next.hosts.maibotWs);
    next.hosts.maibotWebui =
        parse('hosts.maibotWebui', next.hosts.maibotWebui);
    next.proxy.url = _controllers['proxy.url']!.text.trim();
    return next;
  }

  Future<void> _save() async {
    final state = AppScope.of(context);
    final next = _collect();
    final errors = next.validate();
    setState(() => _errors = errors);
    if (errors.isNotEmpty) {
      showError(context, '有 ${errors.length} 项需要先修正');
      return;
    }
    try {
      await state.applySettings(next);
      setState(() {
        _draft = state.settings.copy();
        _dirty = false;
      });
      if (mounted) showInfo(context, '配置已保存到 ${AppPaths.settingsFile}');
    } catch (e) {
      if (mounted) showError(context, '保存失败：$e');
    }
  }

  Future<void> _pickDirectory(String key) async {
    final selected = await FilePicker.getDirectoryPath(
      dialogTitle: '选择目录',
      initialDirectory:
          Directory(_controllers[key]!.text.trim()).existsSync()
              ? _controllers[key]!.text.trim()
              : null,
    );
    if (selected == null) return;
    _controllers[key]!.text = selected;
    _markDirty();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final busy = state.controller.anyRunning;

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
                    Text('设置', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                    SizedBox(height: 4),
                    Text(
                      '路径、端口、代理与环境变量；保存在 %APPDATA%\\BotConsole\\settings.json',
                      style: TextStyle(fontSize: 12, color: AppColors.textMuted),
                    ),
                  ],
                ),
              ),
              if (_dirty)
                const Padding(
                  padding: EdgeInsets.only(right: 12),
                  child: Text(
                    '有未保存的修改',
                    style: TextStyle(fontSize: 12, color: AppColors.warning),
                  ),
                ),
              TextButton(
                onPressed: () async {
                  final ok = await confirmDialog(
                    context,
                    title: '恢复默认配置？',
                    content: '会放弃当前草稿并写回默认值。',
                    confirmLabel: '恢复',
                    danger: true,
                  );
                  if (!ok) return;
                  setState(() {
                    _draft = AppSettings.defaults();
                    _syncControllers();
                  });
                },
                child: const Text('恢复默认'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _save,
                icon: const Icon(Icons.save_rounded, size: 18),
                label: const Text('保存'),
              ),
            ],
          ),
          if (busy)
            const Padding(
              padding: EdgeInsets.only(top: 10),
              child: Text(
                '服务运行中修改端口不会立刻生效，重启对应服务后再使用新端口。',
                style: TextStyle(fontSize: 12, color: AppColors.warning),
              ),
            ),
          const SizedBox(height: 16),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_errors.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: SectionCard(
                        title: '校验未通过',
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            for (final error in _errors)
                              Padding(
                                padding: const EdgeInsets.symmetric(vertical: 2),
                                child: Text(
                                  '· $error',
                                  style: const TextStyle(fontSize: 12, color: AppColors.danger),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  SectionCard(
                    title: 'SnowLuma',
                    child: Column(
                      children: [
                        _PathField(
                          label: '程序目录',
                          controller: _controllers['snowluma.dir']!,
                          hint: r'例如 C:\Bots\SnowLuma',
                          onPick: () => _pickDirectory('snowluma.dir'),
                          onChanged: _markDirty,
                        ),
                        _PathField(
                          label: '入口文件',
                          controller: _controllers['snowluma.entry']!,
                          hint: 'index.mjs',
                          onChanged: _markDirty,
                        ),
                        _PathField(
                          label: 'node.exe',
                          controller: _controllers['snowluma.nodeExe']!,
                          hint: r'例如 C:\Program Files\nodejs\node.exe',
                          onChanged: _markDirty,
                          trailing: TextButton(
                            onPressed: () {
                              _controllers['snowluma.nodeExe']!.text = resolveNodeExe();
                              _markDirty();
                            },
                            child: const Text('自动检测'),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  SectionCard(
                    title: 'MaiBot',
                    child: Column(
                      children: [
                        _PathField(
                          label: '程序目录',
                          controller: _controllers['maibot.dir']!,
                          hint: r'例如 C:\Bots\MaiBot',
                          onPick: () => _pickDirectory('maibot.dir'),
                          onChanged: _markDirty,
                        ),
                        _PathField(
                          label: 'Python',
                          controller: _controllers['maibot.pythonExe']!,
                          hint: r'.venv\Scripts\python.exe',
                          onChanged: _markDirty,
                        ),
                        _PathField(
                          label: '入口文件',
                          controller: _controllers['maibot.entry']!,
                          hint: 'bot.py',
                          onChanged: _markDirty,
                        ),
                        _TextRow(
                          label: 'WebUI 令牌',
                          controller: _controllers['maibot.token']!,
                          hint: '登录 MaiBot 面板用',
                          onChanged: _markDirty,
                        ),
                        _PathField(
                          label: '用量数据库',
                          controller: _controllers['usageDatabasePath']!,
                          hint: '可选；留空使用 MaiBot 目录下 data/MaiBot.db',
                          onChanged: _markDirty,
                          onPick: () async {
                            final result = await FilePicker.pickFiles(dialogTitle: '选择 MaiBot 用量数据库');
                            if (result.isEmpty || result.single.path == null || !mounted) return;
                            _controllers['usageDatabasePath']!.text = result.single.path!;
                            _markDirty();
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  SectionCard(
                    title: '端口 / 主机',
                    child: Column(
                      children: [
                        _TextRow(
                          label: '主机',
                          controller: _controllers['hosts.host']!,
                          hint: '127.0.0.1',
                          onChanged: _markDirty,
                        ),
                        Row(
                          children: [
                            Expanded(
                              child: _TextRow(
                                label: 'SnowLuma HTTP',
                                controller: _controllers['hosts.snowlumaHttp']!,
                                hint: '3000',
                                onChanged: _markDirty,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _TextRow(
                                label: 'SnowLuma WS',
                                controller: _controllers['hosts.snowlumaWs']!,
                                hint: '3001',
                                onChanged: _markDirty,
                              ),
                            ),
                          ],
                        ),
                        Row(
                          children: [
                            Expanded(
                              child: _TextRow(
                                label: 'SnowLuma WebUI',
                                controller: _controllers['hosts.snowlumaWebui']!,
                                hint: '5099',
                                onChanged: _markDirty,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _TextRow(
                                label: 'MaiBot WS',
                                controller: _controllers['hosts.maibotWs']!,
                                hint: '8000',
                                onChanged: _markDirty,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: _TextRow(
                                label: 'MaiBot WebUI',
                                controller: _controllers['hosts.maibotWebui']!,
                                hint: '8001',
                                onChanged: _markDirty,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  SectionCard(
                    title: '代理与环境变量',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('自动注入代理', style: TextStyle(fontSize: 13)),
                          subtitle: const Text(
                            'HTTP_PROXY / HTTPS_PROXY / ALL_PROXY，并在 NO_PROXY 中排除本机地址',
                            style: TextStyle(fontSize: 11, color: AppColors.textMuted),
                          ),
                          value: _draft.proxy.autoDetect,
                          onChanged: (value) {
                            setState(() {
                              _draft.proxy.autoDetect = value;
                              _dirty = true;
                            });
                          },
                        ),
                        _TextRow(
                          label: '代理地址',
                          controller: _controllers['proxy.url']!,
                          hint: 'http://127.0.0.1:7897',
                          onChanged: _markDirty,
                        ),
                        const SizedBox(height: 10),
                        const Text(
                          '额外环境变量（每行 KEY=VALUE，行首 !KEY 表示删除）',
                          style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
                        ),
                        const SizedBox(height: 6),
                        TextField(
                          controller: _controllers['env.extra']!,
                          onChanged: (_) => _markDirty(),
                          maxLines: 5,
                          style: const TextStyle(fontSize: 12, fontFamily: 'Consolas'),
                          decoration: const InputDecoration(
                            hintText: 'GITHUB_TOKEN=xxx\nPYTHONUTF8=1',
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  SectionCard(
                    title: '界面',
                    child: Column(
                      children: [
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('退出程序时确认', style: TextStyle(fontSize: 13)),
                          subtitle: const Text(
                            '托盘菜单退出时确认；最小化或关闭窗口会收起到托盘',
                            style: TextStyle(fontSize: 11, color: AppColors.textMuted),
                          ),
                          value: _draft.ui.confirmOnClose,
                          onChanged: (value) {
                            setState(() {
                              _draft.ui.confirmOnClose = value;
                              _dirty = true;
                            });
                          },
                        ),
                        SwitchListTile(
                          contentPadding: EdgeInsets.zero,
                          title: const Text('启动时自动拉起服务', style: TextStyle(fontSize: 13)),
                          value: _draft.ui.autoStart,
                          onChanged: (value) {
                            setState(() {
                              _draft.ui.autoStart = value;
                              _dirty = true;
                            });
                          },
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  SectionCard(
                    title: '位置',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        InfoRow(label: '配置文件', value: AppPaths.settingsFile, monospace: true),
                        InfoRow(label: '日志目录', value: AppPaths.logsDir, monospace: true),
                        if (AppPaths.logsWarning != null)
                          Text(
                            AppPaths.logsWarning!,
                            style: const TextStyle(color: AppColors.warning, fontSize: 12),
                          ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            OutlinedButton.icon(
                              onPressed: () async {
                                try {
                                  await openDirectory(AppPaths.baseDir);
                                } catch (e) {
                                  if (context.mounted) showError(context, '$e');
                                }
                              },
                              icon: const Icon(Icons.folder_open_rounded, size: 17),
                              label: const Text('打开配置目录'),
                            ),
                            const SizedBox(width: 8),
                            OutlinedButton.icon(
                              onPressed: () async {
                                try {
                                  await openDirectory(AppPaths.logsDir);
                                } catch (e) {
                                  if (context.mounted) showError(context, '$e');
                                }
                              },
                              icon: const Icon(Icons.article_outlined, size: 17),
                              label: const Text('打开日志目录'),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _PathField extends StatelessWidget {
  const _PathField({
    required this.label,
    required this.controller,
    required this.hint,
    required this.onChanged,
    this.onPick,
    this.trailing,
  });

  final String label;
  final TextEditingController controller;
  final String hint;
  final VoidCallback onChanged;
  final Future<void> Function()? onPick;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 104,
            child: Text(
              label,
              style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
            ),
          ),
          Expanded(
            child: TextField(
              controller: controller,
              onChanged: (_) => onChanged(),
              style: const TextStyle(fontSize: 12, fontFamily: 'Consolas'),
              decoration: InputDecoration(hintText: hint),
            ),
          ),
          if (onPick != null) ...[
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: () => onPick!(),
              child: const Text('浏览'),
            ),
          ],
          if (trailing != null) ...[
            const SizedBox(width: 4),
            trailing!,
          ],
        ],
      ),
    );
  }
}

class _TextRow extends StatelessWidget {
  const _TextRow({
    required this.label,
    required this.controller,
    required this.hint,
    required this.onChanged,
  });

  final String label;
  final TextEditingController controller;
  final String hint;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 104,
            child: Text(
              label,
              style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
            ),
          ),
          Expanded(
            child: TextField(
              controller: controller,
              onChanged: (_) => onChanged(),
              style: const TextStyle(fontSize: 12, fontFamily: 'Consolas'),
              decoration: InputDecoration(hintText: hint),
            ),
          ),
        ],
      ),
    );
  }
}
