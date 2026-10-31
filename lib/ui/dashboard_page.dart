import 'dart:async';

import 'package:flutter/material.dart';

import '../app.dart';
import '../core/port_probe.dart';
import '../services/health_monitor.dart';
import '../services/service_controller.dart';
import 'theme.dart';
import 'widgets.dart';
import 'usage_page.dart';

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key, required this.onOpenUsage});
  final VoidCallback onOpenUsage;

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  Map<int, bool> _ports = const {};
  Map<int, int> _owners = const {};
  bool _probing = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _probePorts());
  }

  Future<void> _probePorts() async {
    final state = AppScope.of(context);
    setState(() => _probing = true);
    try {
      final ports = await probePorts(state.settings.hosts.host, state.controller.allPorts);
      final owners = await state.controller.occupiedPorts();
      if (!mounted) return;
      setState(() {
        _ports = ports;
        _owners = owners;
      });
    } catch (_) {
      // 探测失败不影响主界面
    } finally {
      if (mounted) setState(() => _probing = false);
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } catch (e) {
      if (mounted) showError(context, '$e');
    }
    if (mounted) unawaited(_probePorts());
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final controller = state.controller;
    final health = state.health.snapshot;
    final busy = controller.anyBusy;

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(
            busy: busy,
            allRunning: controller.allRunning,
            onStartAll: () => _run(controller.startAll),
            onStopAll: () => _run(controller.stopAll),
            onRefresh: _probePorts,
          ),
          const SizedBox(height: 18),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  UsageDashboardCard(controller: state.dashboardUsage, onOpen: widget.onOpenUsage),
                  const SizedBox(height: 14),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final twoColumns = constraints.maxWidth > 860;
                      final cards = [
                        _ServiceCard(
                          kind: ServiceKind.snowluma,
                          status: controller.statusOf(ServiceKind.snowluma),
                          ports: _ports,
                          owners: _owners,
                          webuiUrl: state.settings.hosts.snowlumaWebuiUrl,
                          subtitle: 'QQ 宿主 · OneBot 3000/3001',
                          extra: health.qqUin == null ? null : 'QQ ${health.qqUin}',
                          onAction: _run,
                        ),
                        _ServiceCard(
                          kind: ServiceKind.maibot,
                          status: controller.statusOf(ServiceKind.maibot),
                          ports: _ports,
                          owners: _owners,
                          webuiUrl: state.settings.hosts.maibotWebuiUrl,
                          subtitle: '聊天机器人 · WebUI 8001',
                          extra: health.adapterConnected ? '适配器已连接' : null,
                          onAction: _run,
                        ),
                      ];
                      if (!twoColumns) {
                        return Column(
                          children: [
                            for (final card in cards) ...[
                              card,
                              const SizedBox(height: 14),
                            ],
                          ],
                        );
                      }
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: cards[0]),
                          const SizedBox(width: 14),
                          Expanded(child: cards[1]),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 14),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final twoColumns = constraints.maxWidth > 860;
                      final healthCard = _HealthCard(snapshot: health);
                      final portsCard = _PortsCard(
                        ports: _ports,
                        owners: _owners,
                        probing: _probing,
                        onRefresh: _probePorts,
                        labels: {
                          state.settings.hosts.snowlumaHttp: 'SnowLuma HTTP',
                          state.settings.hosts.snowlumaWs: 'SnowLuma WS',
                          state.settings.hosts.snowlumaWebui: 'SnowLuma WebUI',
                          state.settings.hosts.maibotWs: 'MaiBot WS',
                          state.settings.hosts.maibotWebui: 'MaiBot WebUI',
                        },
                      );
                      if (!twoColumns) {
                        return Column(
                          children: [
                            healthCard,
                            const SizedBox(height: 14),
                            portsCard,
                          ],
                        );
                      }
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(child: healthCard),
                          const SizedBox(width: 14),
                          Expanded(child: portsCard),
                        ],
                      );
                    },
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

class _Header extends StatelessWidget {
  const _Header({
    required this.busy,
    required this.allRunning,
    required this.onStartAll,
    required this.onStopAll,
    required this.onRefresh,
  });

  final bool busy;
  final bool allRunning;
  final Future<void> Function() onStartAll;
  final Future<void> Function() onStopAll;
  final Future<void> Function() onRefresh;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '总览',
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
              ),
              SizedBox(height: 4),
              Text(
                '一键拉起 SnowLuma 与 MaiBot，无需再开命令行窗口',
                style: TextStyle(fontSize: 12, color: AppColors.textMuted),
              ),
            ],
          ),
        ),
        IconButton(
          onPressed: onRefresh,
          icon: const Icon(Icons.refresh_rounded, size: 20),
          tooltip: '刷新端口状态',
        ),
        const SizedBox(width: 6),
        if (allRunning)
          OutlinedButton.icon(
            onPressed: busy ? null : () => onStopAll(),
            icon: const Icon(Icons.stop_circle_outlined, size: 18),
            label: const Text('全部停止'),
          )
        else
          FilledButton.icon(
            onPressed: busy ? null : () => onStartAll(),
            icon: const Icon(Icons.power_settings_new_rounded, size: 18),
            label: const Text('一键全部启动'),
          ),
      ],
    );
  }
}

class _ServiceCard extends StatelessWidget {
  const _ServiceCard({
    required this.kind,
    required this.status,
    required this.ports,
    required this.owners,
    required this.webuiUrl,
    required this.subtitle,
    required this.onAction,
    this.extra,
  });

  final ServiceKind kind;
  final ServiceStatus status;
  final Map<int, bool> ports;
  final Map<int, int> owners;
  final String webuiUrl;
  final String subtitle;
  final String? extra;
  final Future<void> Function(Future<void> Function()) onAction;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final controller = state.controller;
    final isSnow = kind == ServiceKind.snowluma;
    final icon = isSnow ? Icons.cloud_queue_rounded : Icons.smart_toy_rounded;
    final tint = isSnow ? AppColors.accent : AppColors.success;
    final kindPorts = controller.portsOf(kind);

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: tint.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(11),
                  ),
                  child: Icon(icon, size: 20, color: tint),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        kind.label,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: const TextStyle(
                          fontSize: 11,
                          color: AppColors.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                StatusPill(state: status.state),
              ],
            ),
            const SizedBox(height: 14),
            InfoRow(
              label: '进程 PID',
              value: status.pid?.toString() ?? '—',
              monospace: true,
            ),
            InfoRow(
              label: '端口',
              value: kindPorts
                  .map((p) => '$p ${ports[p] == true ? '✓' : '✗'}')
                  .join('   '),
              monospace: true,
            ),
            if (extra != null)
              InfoRow(label: '状态', value: extra!, valueColor: tint),
            if (status.note != null)
              InfoRow(
                label: '提示',
                value: status.note!,
                valueColor: AppColors.warning,
              ),
            if (status.error != null)
              InfoRow(
                label: '错误',
                value: status.error!,
                valueColor: AppColors.danger,
              ),
            if (owners.isNotEmpty)
              InfoRow(
                label: '占用',
                value: kindPorts
                    .where((p) => owners[p] != null)
                    .map((p) => '$p ← PID ${owners[p]}')
                    .join('   '),
              ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(
                  child: ServiceActions(
                    kind: kind,
                    status: status,
                    controller: controller,
                    onError: (message) => showError(context, message),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: () async {
                    try {
                      await openExternal(webuiUrl);
                    } catch (e) {
                      if (context.mounted) showError(context, '$e');
                    }
                  },
                  icon: const Icon(Icons.open_in_new_rounded, size: 17),
                  label: const Text('WebUI'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _HealthCard extends StatelessWidget {
  const _HealthCard({required this.snapshot});

  final HealthSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final warmup = snapshot.warmupLoaded != null && snapshot.warmupTotal != null
        ? '${snapshot.warmupLoaded}/${snapshot.warmupTotal} 群'
        : '—';
    return SectionCard(
      title: '运行状态',
      child: Column(
        children: [
          _HealthLine(
            label: 'QQ 登录',
            ok: snapshot.qqUin != null,
            value: snapshot.qqUin == null ? '未登录' : 'UIN ${snapshot.qqUin}',
          ),
          _HealthLine(
            label: 'OneBot HTTP',
            ok: snapshot.onebotHttpListening,
            value: snapshot.onebotHttpListening ? '监听中' : '未监听',
          ),
          _HealthLine(
            label: 'OneBot WS',
            ok: snapshot.onebotWsListening,
            value: snapshot.onebotWsListening ? '监听中' : '未监听',
          ),
          _HealthLine(
            label: '群预热',
            ok: snapshot.warmupTotal != null && snapshot.warmupLoaded == snapshot.warmupTotal,
            value: warmup,
          ),
          _HealthLine(
            label: 'MaiBot 适配器',
            ok: snapshot.adapterConnected,
            value: snapshot.adapterEndpoint ?? '未连接',
          ),
          _HealthLine(
            label: 'SnowLuma 面板',
            ok: snapshot.snowlumaWebuiOk,
            value: snapshot.snowlumaWebuiOk ? '可访问' : '不可访问',
          ),
          _HealthLine(
            label: 'MaiBot 面板',
            ok: snapshot.maibotWebuiOk,
            value: snapshot.maibotWebuiOk ? '可访问' : '不可访问',
          ),
          if (snapshot.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  '探测异常：${snapshot.error}',
                  style: const TextStyle(fontSize: 11, color: Color(0xFFE06C6C)),
                ),
              ),
            ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: Text(
              snapshot.updatedAt == null
                  ? '尚未探测'
                  : '更新于 ${_time(snapshot.updatedAt!)}',
              style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
            ),
          ),
        ],
      ),
    );
  }

  static String _time(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }
}

class _HealthLine extends StatelessWidget {
  const _HealthLine({required this.label, required this.ok, required this.value});

  final String label;
  final bool ok;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Dot(on: ok),
          const SizedBox(width: 10),
          SizedBox(
            width: 104,
            child: Text(
              label,
              style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                fontSize: 12,
                color: ok ? AppColors.textPrimary : AppColors.textMuted,
                fontFamily: 'Consolas',
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _PortsCard extends StatelessWidget {
  const _PortsCard({
    required this.ports,
    required this.owners,
    required this.probing,
    required this.onRefresh,
    required this.labels,
  });

  final Map<int, bool> ports;
  final Map<int, int> owners;
  final bool probing;
  final Future<void> Function() onRefresh;
  final Map<int, String> labels;

  @override
  Widget build(BuildContext context) {
    return SectionCard(
      title: '端口',
      trailing: probing
          ? const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 1.6),
            )
          : IconButton(
              visualDensity: VisualDensity.compact,
              onPressed: onRefresh,
              icon: const Icon(Icons.refresh_rounded, size: 16),
              tooltip: '重新探测',
            ),
      child: Column(
        children: [
          for (final entry in labels.entries)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                children: [
                  Dot(on: ports[entry.key] == true),
                  const SizedBox(width: 10),
                  SizedBox(
                    width: 46,
                    child: Text(
                      '${entry.key}',
                      style: const TextStyle(
                        fontSize: 12,
                        fontFamily: 'Consolas',
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      entry.value,
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppColors.textMuted,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    ports[entry.key] == true
                        ? (owners[entry.key] == null
                            ? '监听中'
                            : 'PID ${owners[entry.key]}')
                        : '空闲',
                    style: TextStyle(
                      fontSize: 11,
                      color: ports[entry.key] == true
                          ? AppColors.success
                          : AppColors.textMuted,
                      fontFamily: 'Consolas',
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
