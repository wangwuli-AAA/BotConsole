import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app.dart';
import '../services/whitelist_store.dart';
import 'theme.dart';
import 'widgets.dart';

/// 群聊 / 私聊白名单编辑（改 `config\adapter_policy.toml`）。
class WhitelistPage extends StatefulWidget {
  const WhitelistPage({super.key});

  @override
  State<WhitelistPage> createState() => _WhitelistPageState();
}

class _WhitelistPageState extends State<WhitelistPage> {
  List<String> _groups = [];
  List<String> _privates = [];
  bool _loaded = false;
  String? _loadError;
  bool _saving = false;
  String? _expectedPath;

  final TextEditingController _groupInput = TextEditingController();
  final TextEditingController _privateInput = TextEditingController();
  String? _groupInputError;
  String? _privateInputError;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = AppScope.of(context);
    final path = WhitelistStore.defaultPathFor(state.settings.maibot.dir);
    if (!_loaded || _expectedPath != path) {
      _expectedPath = path;
      _reload();
    }
  }

  void _reload() {
    final state = AppScope.of(context);
    state.whitelist = WhitelistStore(WhitelistStore.defaultPathFor(state.settings.maibot.dir));
    try {
      final snapshot = state.whitelist.read();
      setState(() {
        _groups = List.of(snapshot.groupIds);
        _privates = List.of(snapshot.privateIds);
        _loaded = true;
        _loadError = null;
      });
    } catch (e) {
      setState(() {
        _loaded = true;
        _loadError = '$e';
      });
    }
  }

  Future<void> _save() async {
    final state = AppScope.of(context);
    setState(() => _saving = true);
    try {
      final snapshot = state.whitelist.save(groupIds: _groups, privateIds: _privates);
      setState(() {
        _groups = List.of(snapshot.groupIds);
        _privates = List.of(snapshot.privateIds);
      });
      if (mounted) showInfo(context, '已写入 adapter_policy.toml，MaiBot 会自动热加载');
    } catch (e) {
      if (mounted) showError(context, '保存失败：$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _add(List<String> target, TextEditingController input, void Function(String?) setError) {
    final value = input.text.trim();
    final error = validateChatId(value);
    if (error != null) {
      setError(error);
      return;
    }
    if (target.contains(value)) {
      setError('已存在');
      return;
    }
    setError(null);
    setState(() => target.add(value));
    input.clear();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final path = state.whitelist.path;
    final exists = state.whitelist.exists;

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
                    Text('群聊白名单', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                    SizedBox(height: 4),
                    Text(
                      'MaiBot 只响应白名单里的群和私聊，修改后立即生效（无需重启）',
                      style: TextStyle(fontSize: 12, color: AppColors.textMuted),
                    ),
                  ],
                ),
              ),
              OutlinedButton.icon(
                onPressed: _saving ? null : _reload,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('重新读取'),
              ),
              const SizedBox(width: 8),
              FilledButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 1.8),
                      )
                    : const Icon(Icons.save_rounded, size: 18),
                label: const Text('保存'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SectionCard(
                    title: '文件',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SelectableText(
                          path,
                          style: const TextStyle(fontSize: 12, fontFamily: 'Consolas'),
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Dot(on: exists),
                            const SizedBox(width: 8),
                            Text(
                              exists ? '文件存在' : '文件不存在（保存时会新建）',
                              style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
                            ),
                          ],
                        ),
                        if (_loadError != null) ...[
                          const SizedBox(height: 8),
                          Text(
                            _loadError!,
                            style: const TextStyle(fontSize: 12, color: AppColors.danger),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),
                  _IdEditor(
                    title: '群聊白名单',
                    hint: '输入需要允许的群号',
                    ids: _groups,
                    input: _groupInput,
                    inputError: _groupInputError,
                    onAdd: () => _add(_groups, _groupInput, (e) => setState(() => _groupInputError = e)),
                    onRemove: (id) => setState(() => _groups.remove(id)),
                  ),
                  const SizedBox(height: 14),
                  _IdEditor(
                    title: '私聊白名单',
                    hint: '输入需要允许的 QQ 号',
                    ids: _privates,
                    input: _privateInput,
                    inputError: _privateInputError,
                    onAdd: () => _add(_privates, _privateInput, (e) => setState(() => _privateInputError = e)),
                    onRemove: (id) => setState(() => _privates.remove(id)),
                  ),
                  const SizedBox(height: 14),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Icon(Icons.info_outline_rounded, size: 18, color: AppColors.textMuted),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              '写入采用“只替换 ids 数组、保留其余内容”的方式，MaiBot 端有文件监视器会自动重载；'
                              '每次保存前都会在同一目录生成 adapter_policy.toml.bak-时间戳 备份。',
                              style: const TextStyle(fontSize: 12, color: AppColors.textMuted, height: 1.6),
                            ),
                          ),
                        ],
                      ),
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

class _IdEditor extends StatelessWidget {
  const _IdEditor({
    required this.title,
    required this.hint,
    required this.ids,
    required this.input,
    required this.onAdd,
    required this.onRemove,
    this.inputError,
  });

  final String title;
  final String hint;
  final List<String> ids;
  final TextEditingController input;
  final String? inputError;
  final VoidCallback onAdd;
  final ValueChanged<String> onRemove;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: '$title（${ids.length}）',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (ids.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 10),
              child: Text('还没有条目', style: TextStyle(fontSize: 12, color: AppColors.textMuted)),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final id in ids)
                  InputChip(
                    label: Text(id, style: const TextStyle(fontSize: 12, fontFamily: 'Consolas')),
                    onDeleted: () => onRemove(id),
                    backgroundColor: AppColors.surfaceHigh,
                    side: const BorderSide(color: AppColors.border),
                    deleteIcon: const Icon(Icons.close_rounded, size: 15),
                  ),
              ],
            ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: TextField(
                  controller: input,
                  onSubmitted: (_) => onAdd(),
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: InputDecoration(hintText: hint, errorText: inputError),
                ),
              ),
              const SizedBox(width: 10),
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: OutlinedButton.icon(
                  onPressed: onAdd,
                  icon: const Icon(Icons.add_rounded, size: 18),
                  label: const Text('添加'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
