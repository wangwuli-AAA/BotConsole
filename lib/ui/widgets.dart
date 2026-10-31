import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/service_controller.dart';
import 'theme.dart';

/// 状态徽章（颜色 + 文案）。
class StatusPill extends StatelessWidget {
  const StatusPill({super.key, required this.state, this.dense = false});

  final ServiceState state;
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final color = colorForState(state.name);
    final label = switch (state) {
      ServiceState.running => '运行中',
      ServiceState.starting => '启动中',
      ServiceState.stopping => '停止中',
      ServiceState.failed => '失败',
      ServiceState.stopped => '已停止',
    };
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: dense ? 8 : 10,
        vertical: dense ? 3 : 5,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(
            label,
            style: TextStyle(
              fontSize: dense ? 11 : 12,
              color: color,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// 小圆点。
class Dot extends StatelessWidget {
  const Dot({super.key, required this.on, this.color});

  final bool on;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? (on ? AppColors.success : AppColors.textMuted);
    return Container(
      width: 7,
      height: 7,
      decoration: BoxDecoration(
        color: on ? c : AppColors.border,
        shape: BoxShape.circle,
        boxShadow: on
            ? [BoxShadow(color: c.withValues(alpha: 0.6), blurRadius: 6)]
            : null,
      ),
    );
  }
}

/// 一行 “标签 : 值”。
class InfoRow extends StatelessWidget {
  const InfoRow({
    super.key,
    required this.label,
    required this.value,
    this.valueColor,
    this.monospace = false,
  });

  final String label;
  final String value;
  final Color? valueColor;
  final bool monospace;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 88,
            child: Text(
              label,
              style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 12,
                color: valueColor ?? AppColors.textPrimary,
                fontFamily: monospace ? 'Consolas' : null,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 卡片外壳：标题行 + 内容。
class SectionCard extends StatelessWidget {
  const SectionCard({
    super.key,
    required this.title,
    this.trailing,
    required this.child,
    this.padding = const EdgeInsets.fromLTRB(16, 14, 16, 16),
  });

  final String title;
  final Widget? trailing;
  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: padding,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: Text(title, style: kSectionTitle)),
                ?trailing,
              ],
            ),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }
}

/// 服务操作按钮组。
class ServiceActions extends StatelessWidget {
  const ServiceActions({
    super.key,
    required this.kind,
    required this.status,
    required this.controller,
    this.onError,
  });

  final ServiceKind kind;
  final ServiceStatus status;
  final ServiceController controller;
  final void Function(String message)? onError;

  Future<void> _run(BuildContext context, Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      onError?.call('$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final busy = status.state.isBusy;
    final running = status.state == ServiceState.running;
    return Row(
      children: [
        if (!running)
          FilledButton.icon(
            onPressed: busy ? null : () => _run(context, () => controller.start(kind)),
            icon: const Icon(Icons.play_arrow_rounded, size: 18),
            label: const Text('启动'),
          )
        else
          OutlinedButton.icon(
            onPressed: () => _run(context, () => controller.stop(kind)),
            icon: const Icon(Icons.stop_rounded, size: 18),
            label: const Text('停止'),
          ),
        const SizedBox(width: 8),
        OutlinedButton.icon(
          onPressed: busy
              ? null
              : () => _run(context, () async {
                    await controller.stop(kind);
                    await controller.start(kind);
                  }),
          icon: const Icon(Icons.restart_alt_rounded, size: 18),
          label: const Text('重启'),
        ),
      ],
    );
  }
}

/// 打开 URL（外部浏览器）。
Future<void> openExternal(String url) async {
  final uri = Uri.parse(url);
  if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
    throw Exception('无法打开 $url');
  }
}

/// 打开目录。
Future<void> openDirectory(String path) async {
  if (!Directory(path).existsSync()) {
    throw Exception('目录不存在：$path');
  }
  await openExternal(Uri.file(path).toString());
}
