import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../app.dart';
import '../usage/usage_controller.dart';
import '../usage/usage_models.dart';
import 'theme.dart';
import 'widgets.dart';

String usageNumber(num value) {
  if (value.abs() >= 1000000) return '${(value / 1000000).toStringAsFixed(2)}M';
  if (value.abs() >= 10000) return '${(value / 10000).toStringAsFixed(2)}万';
  if (value.abs() >= 1000) return '${(value / 1000).toStringAsFixed(1)}k';
  return value == value.roundToDouble()
      ? '${value.toInt()}'
      : value.toStringAsFixed(2);
}

class UsageMetricsView extends StatelessWidget {
  const UsageMetricsView({
    super.key,
    required this.snapshot,
    this.compact = false,
  });
  final UsageSnapshot snapshot;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final m = snapshot.metrics, p = snapshot.previous;
    final cards = <(String, String, String, String)>[
      (
        '总 token',
        usageNumber(m.tokens),
        '${m.tokens}',
        changeLabel(m.tokens, p.tokens),
      ),
      (
        '输入 / 输出',
        '${usageNumber(m.input)} / ${usageNumber(m.output)}',
        '输入 ${m.input} / 输出 ${m.output}',
        '${changeLabel(m.input, p.input)} / ${changeLabel(m.output, p.output)}',
      ),
      (
        '调用次数',
        usageNumber(m.calls),
        '${m.calls}',
        changeLabel(m.calls, p.calls),
      ),
      (
        '账面费用（元）',
        '¥${m.cost.toStringAsFixed(4)}',
        '¥${m.cost.toStringAsFixed(8)}',
        changeLabel(m.cost, p.cost),
      ),
      if (!compact) ...[
        (
          '缓存命中率',
          m.cacheRate == null
              ? '—'
              : '${(m.cacheRate! * 100).toStringAsFixed(1)}%',
          '命中 ${m.hit} / 可统计 ${m.hit + m.miss}',
          changeLabel(m.cacheRate, p.cacheRate, percentagePoints: true),
        ),
        (
          '平均调用耗时',
          m.meanSeconds == null
              ? '—'
              : '${m.meanSeconds!.toStringAsFixed(2)} 秒',
          '${m.timedCalls} 次有耗时记录的调用',
          changeLabel(m.meanSeconds, p.meanSeconds),
        ),
      ],
    ];
    return LayoutBuilder(
      builder: (context, box) {
        final columns = math.max(
          1,
          math.min(cards.length, (box.maxWidth / 205).floor()),
        );
        final width = (box.maxWidth - (columns - 1) * 10) / columns;
        return Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final item in cards)
              SizedBox(
                width: width,
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.$1,
                          style: const TextStyle(
                            color: AppColors.textSecondary,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Tooltip(
                          message: item.$3,
                          child: Text(
                            item.$2,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '较上期 ${item.$4}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppColors.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class UsageDashboardCard extends StatelessWidget {
  const UsageDashboardCard({
    super.key,
    required this.controller,
    required this.onOpen,
  });
  final UsageController controller;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) => SectionCard(
      title: '近 24 小时用量',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            tooltip: '刷新用量',
            onPressed: controller.loading ? null : controller.refresh,
            icon: const Icon(Icons.refresh, size: 18),
          ),
          TextButton(onPressed: onOpen, child: const Text('用量分析 →')),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (controller.loading) const LinearProgressIndicator(),
          if (controller.error != null)
            _notice(
              controller.error!.message,
              stale: controller.snapshot != null,
            ),
          if (controller.snapshot != null) ...[
            UsageMetricsView(snapshot: controller.snapshot!, compact: true),
            const SizedBox(height: 8),
            Text(_rangeLabel(controller.snapshot!), style: _muted),
          ] else if (!controller.loading && controller.error == null)
            const Text('等待读取用量', style: _muted),
        ],
      ),
    ),
  );
}

const _muted = TextStyle(fontSize: 12, color: AppColors.textSecondary);
String _rangeLabel(UsageSnapshot s) =>
    '${timeLabel(s.start)} 至 ${timeLabel(s.query.end)}（北京时间，结束不含） · 更新 ${timeLabel(s.loadedAt)}';

Widget _notice(String text, {bool stale = false}) => Padding(
  padding: const EdgeInsets.symmetric(vertical: 10),
  child: Text(
    '${stale ? '上次结果已过期 · ' : ''}$text',
    style: const TextStyle(color: AppColors.warning, fontSize: 12),
  ),
);

class UsagePageView extends StatefulWidget {
  const UsagePageView({super.key, required this.controller});
  final UsageController controller;
  @override
  State<UsagePageView> createState() => _UsagePageViewState();
}

class _UsagePageViewState extends State<UsagePageView> {
  UsageController get c => widget.controller;

  Future<void> _custom() async {
    final startText = TextEditingController(
      text: timeLabel(
        c.query.start ?? usageNow().subtract(const Duration(days: 1)),
      ),
    );
    final endText = TextEditingController(text: timeLabel(c.query.end));
    String? error;
    final result = await showDialog<(DateTime, DateTime)>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('自定义时间（北京时间）'),
          content: SizedBox(
            width: 390,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: startText,
                  decoration: const InputDecoration(
                    labelText: '开始（含）',
                    hintText: '2026-10-01 00:00',
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: endText,
                  decoration: const InputDecoration(
                    labelText: '结束（不含）',
                    hintText: '2026-11-01 00:00',
                  ),
                ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      error!,
                      style: const TextStyle(color: AppColors.danger),
                    ),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () {
                DateTime? parse(String text) {
                  if (!RegExp(
                    r'^\d{4}-\d{2}-\d{2} \d{2}:\d{2}$',
                  ).hasMatch(text)) {
                    return null;
                  }
                  final value = DateTime.tryParse(
                    '${text.replaceAll(' ', 'T')}:00Z',
                  );
                  return value != null && timeLabel(value) == text
                      ? value
                      : null;
                }

                final start = parse(startText.text.trim()),
                    end = parse(endText.text.trim());
                if (start == null || end == null || !start.isBefore(end)) {
                  setDialogState(() => error = '请填写有效时间，且开始早于结束。');
                  return;
                }
                Navigator.pop(context, (start, end));
              },
              child: const Text('应用'),
            ),
          ],
        ),
      ),
    );
    // Wait until dialog transition no longer uses its fields.
    await Future<void>.delayed(const Duration(milliseconds: 250));
    startText.dispose();
    endText.dispose();
    if (result != null && mounted) {
      c.update(
        c.query.withRange(result.$1, result.$2, c.query.grain),
        selectedRange: UsageRange.custom,
      );
    }
  }

  Future<void> _export(bool summary) async {
    try {
      final snapshot = c.snapshot;
      if (snapshot == null) return;
      final directory = await FilePicker.getDirectoryPath(
        dialogTitle: summary ? '选择用量汇总 CSV 导出目录' : '选择全部明细 CSV 导出目录',
      );
      if (directory == null || !mounted) return;
      final path = p.join(
        directory,
        'usage-${summary ? 'summary' : 'details'}-${DateTime.now().millisecondsSinceEpoch}.csv',
      );
      // A timer refresh during the picker must not silently change the export scope.
      if (snapshot != c.snapshot) {
        showError(context, '数据已刷新，请重新导出当前结果。');
        return;
      }
      final count = await c.export(path, summary: summary);
      if (mounted) showInfo(context, '已导出 $count 行到 $path');
    } catch (error) {
      if (mounted) showError(context, '$error');
    }
  }

  Widget _filter(
    String title,
    String key,
    String? value,
    List<UsageGroup> options,
  ) {
    final all = [...options];
    if (value != null && !all.any((g) => g.key == value)) {
      all.add(
        UsageGroup(
          value,
          value.isEmpty ? '未归属（含后台任务）' : value,
          const UsageMetrics(),
        ),
      );
    }
    return SizedBox(
      width: 230,
      child: DropdownButtonFormField<String>(
        key: ValueKey(
          '$key:${value ?? '<all>'}:${all.map((g) => g.key).join('|')}',
        ),
        initialValue: value == null ? '__botconsole_all__' : 'v:$value',
        isExpanded: true,
        decoration: InputDecoration(labelText: title),
        items: [
          const DropdownMenuItem(
            value: '__botconsole_all__',
            child: Text('全部'),
          ),
          for (final g in all)
            DropdownMenuItem(
              value: 'v:${g.key}',
              child: Tooltip(
                message: '${g.label}\n${g.key}',
                child: Text(g.label, overflow: TextOverflow.ellipsis),
              ),
            ),
        ],
        onChanged: (v) => c.update(
          c.query.filter(
            key,
            v == '__botconsole_all__' ? null : v!.substring(2),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: c,
    builder: (context, _) {
      final s = c.snapshot;
      final locked = c.loading || c.exporting || c.error != null || s == null;
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
                        '用量分析',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text('会话 · 模型 · 时间分布', style: _muted),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '刷新用量',
                  onPressed: c.loading ? null : c.refresh,
                  icon: const Icon(Icons.refresh),
                ),
                PopupMenuButton<bool>(
                  enabled: !locked,
                  tooltip: '导出 CSV',
                  onSelected: _export,
                  itemBuilder: (_) => const [
                    PopupMenuItem(value: true, child: Text('导出汇总 CSV')),
                    PopupMenuItem(value: false, child: Text('导出全部筛选明细 CSV')),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      c.exporting ? '正在导出…' : '导出 CSV',
                      style: TextStyle(
                        color: locked ? AppColors.textMuted : AppColors.accent,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Expanded(
              child: SingleChildScrollView(
                key: const ValueKey('usage-scroll'),
                padding: const EdgeInsets.only(top: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        for (final entry in const {
                          UsageRange.today: '今天',
                          UsageRange.day: '近 24 小时',
                          UsageRange.week: '7 天',
                          UsageRange.month: '30 天',
                          UsageRange.all: '全部',
                          UsageRange.custom: '自定义',
                        }.entries)
                          ChoiceChip(
                            label: Text(entry.value),
                            selected: c.range == entry.key,
                            onSelected: (_) {
                              if (entry.key == UsageRange.custom) {
                                _custom();
                                return;
                              }
                              final q = UsageQuery.range(
                                entry.key,
                                grain: c.query.grain,
                              );
                              c.update(
                                c.query.withRange(q.start, q.end, q.grain),
                                selectedRange: entry.key,
                              );
                            },
                          ),
                        SizedBox(
                          width: 135,
                          child: DropdownButtonFormField<UsageGrain>(
                            key: ValueKey(c.query.grain),
                            initialValue: c.query.grain,
                            decoration: const InputDecoration(
                              labelText: '聚合粒度',
                            ),
                            items: [
                              for (final e in const {
                                UsageGrain.hour: '按小时',
                                UsageGrain.day: '按日',
                                UsageGrain.week: '按周',
                                UsageGrain.month: '按月',
                              }.entries)
                                DropdownMenuItem(
                                  value: e.key,
                                  child: Text(e.value),
                                ),
                            ],
                            onChanged: (grain) => c.update(
                              c.query.withRange(
                                c.query.start,
                                c.query.end,
                                grain!,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Wrap(
                      spacing: 10,
                      runSpacing: 12,
                      children: [
                        _filter('会话类型', 'type', c.query.sessionType, const [
                          UsageGroup('group', '群聊', UsageMetrics()),
                          UsageGroup('private', '私聊', UsageMetrics()),
                          UsageGroup(
                            'unattributed',
                            '未归属（含后台任务）',
                            UsageMetrics(),
                          ),
                          UsageGroup('unknown', '未知会话', UsageMetrics()),
                        ]),
                        _filter(
                          '会话',
                          'session',
                          c.query.sessionId,
                          (s?.options['session'] ?? [])
                              .where(
                                (g) =>
                                    c.query.sessionType == null ||
                                    g.type == c.query.sessionType,
                              )
                              .toList(),
                        ),
                        _filter(
                          '模型 / 别名 / 供应商',
                          'model',
                          c.query.model,
                          s?.options['model'] ?? [],
                        ),
                        _filter(
                          '任务',
                          'task',
                          c.query.task,
                          s?.options['task'] ?? [],
                        ),
                        _filter(
                          '供应商',
                          'provider',
                          c.query.provider,
                          s?.options['provider'] ?? [],
                        ),
                        _filter(
                          '请求类型',
                          'request',
                          c.query.requestType,
                          s?.options['request'] ?? [],
                        ),
                        TextButton(
                          onPressed: () => c.update(
                            UsageQuery(
                              start: c.query.start,
                              end: c.query.end,
                              grain: c.query.grain,
                            ),
                          ),
                          child: const Text('清除维度筛选'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (c.loading) const LinearProgressIndicator(),
                    if (c.error != null)
                      _notice(c.error!.message, stale: s != null),
                    if (c.exporting)
                      const Padding(
                        padding: EdgeInsets.all(8),
                        child: Text('正在后台分批导出，期间仍可浏览页面。', style: _muted),
                      ),
                    if (s != null) ...[
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: SelectableText(_rangeLabel(s), style: _muted),
                      ),
                      if (c.loading)
                        const Text('正在读取新筛选，以下保留上次结果。', style: _muted),
                      UsageMetricsView(snapshot: s),
                      const SizedBox(height: 16),
                      if (s.metrics.calls == 0)
                        const SectionCard(
                          title: '暂无用量',
                          child: Text(
                            '此筛选区间没有已记录的调用，请调整时间或筛选条件。',
                            style: _muted,
                          ),
                        ),
                      if (s.metrics.calls > 0) ...[
                        _Insights(snapshot: s),
                        const SizedBox(height: 16),
                        _UsageTrend(snapshot: s, kind: 'tokens'),
                        const SizedBox(height: 16),
                        _pair(
                          _UsageTrend(snapshot: s, kind: 'calls'),
                          _UsageTrend(snapshot: s, kind: 'cost'),
                        ),
                        const SizedBox(height: 16),
                        _Distribution(
                          title: '会话消耗排行 · 点击查看会话',
                          groups: s.groups['session']!,
                          total: s.metrics.tokens,
                          onSelect: locked
                              ? null
                              : (g) => c.update(
                                  c.query
                                      .filter('type', null)
                                      .filter('session', g.key),
                                ),
                        ),
                        const SizedBox(height: 16),
                        _pair(
                          _Distribution(
                            title: '模型分布',
                            groups: s.groups['model']!,
                            total: s.metrics.tokens,
                            onSelect: locked
                                ? null
                                : (g) =>
                                      c.update(c.query.filter('model', g.key)),
                          ),
                          _Distribution(
                            title: '任务分布',
                            groups: s.groups['task']!,
                            total: s.metrics.tokens,
                            onSelect: locked
                                ? null
                                : (g) =>
                                      c.update(c.query.filter('task', g.key)),
                          ),
                        ),
                        const SizedBox(height: 16),
                        _pair(
                          _Distribution(
                            title: '供应商分布',
                            groups: s.groups['provider']!,
                            total: s.metrics.tokens,
                            onSelect: locked
                                ? null
                                : (g) => c.update(
                                    c.query.filter('provider', g.key),
                                  ),
                          ),
                          _Distribution(
                            title: '请求类型分布',
                            groups: s.groups['request']!,
                            total: s.metrics.tokens,
                            onSelect: locked
                                ? null
                                : (g) => c.update(
                                    c.query.filter('request', g.key),
                                  ),
                          ),
                        ),
                        const SizedBox(height: 16),
                        _Heatmap(snapshot: s),
                      ],
                      const SizedBox(height: 16),
                      _UsageDetails(controller: c, locked: locked),
                      const SizedBox(height: 16),
                      const Text(
                        '统计 MaiBot 已记录的用量；总 token 使用原值，缓存不重复计入。费用为数据库账面费用，不重算价格。'
                        '环比为上一等长区间，星期从周一开始；每 60 秒刷新，收进托盘暂停。',
                        style: _muted,
                      ),
                    ] else if (!c.loading && c.error == null)
                      const Padding(
                        padding: EdgeInsets.all(24),
                        child: Text('等待读取用量数据库。', style: _muted),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}

Widget _pair(Widget a, Widget b) => LayoutBuilder(
  builder: (context, box) => box.maxWidth >= 850
      ? Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: a),
            const SizedBox(width: 16),
            Expanded(child: b),
          ],
        )
      : Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [a, const SizedBox(height: 16), b],
        ),
);

class _UsageTrend extends StatelessWidget {
  const _UsageTrend({required this.snapshot, required this.kind});
  final UsageSnapshot snapshot;
  final String kind;

  @override
  Widget build(BuildContext context) {
    final points = snapshot.trend;
    final stacked = kind == 'tokens';
    final color = kind == 'cost' ? AppColors.warning : AppColors.accent;
    List<FlSpot> spots(num Function(UsageMetrics) value) => [
      for (var i = 0; i < points.length; i++)
        FlSpot(i.toDouble(), value(points[i].metrics).toDouble()),
    ];
    final lines = [
      LineChartBarData(
        spots: spots(
          (m) => stacked
              ? m.input
              : kind == 'calls'
              ? m.calls
              : m.cost,
        ),
        color: color,
        barWidth: 2,
        isCurved: false,
        dotData: const FlDotData(show: false),
        belowBarData: BarAreaData(
          show: true,
          color: color.withValues(alpha: 0.18),
        ),
      ),
      if (stacked)
        LineChartBarData(
          spots: spots((m) => m.input + m.output),
          color: AppColors.success,
          barWidth: 2,
          isCurved: false,
          dotData: const FlDotData(show: false),
        ),
    ];
    final title = stacked
        ? '输入 / 输出堆叠趋势（token）'
        : kind == 'calls'
        ? '调用量趋势（次）'
        : '账面费用趋势（元）';
    final maxY = lines
        .expand((l) => l.spots)
        .fold<double>(0, (v, p) => math.max(v, p.y));
    return SectionCard(
      title: title,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (stacked)
            const Padding(
              padding: EdgeInsets.only(bottom: 12),
              child: Wrap(
                spacing: 12,
                children: [
                  Text(
                    '● 输入',
                    style: TextStyle(fontSize: 12, color: AppColors.accent),
                  ),
                  Text(
                    '● 输出（上层）',
                    style: TextStyle(fontSize: 12, color: AppColors.success),
                  ),
                  Text('悬停查看原始数值', style: _muted),
                ],
              ),
            ),
          SizedBox(
            height: 220,
            child: LineChart(
              LineChartData(
                minX: 0,
                maxX: math.max(1, points.length - 1).toDouble(),
                minY: 0,
                maxY: maxY == 0 ? 1 : maxY * 1.12,
                clipData: const FlClipData.all(),
                borderData: FlBorderData(show: false),
                gridData: FlGridData(
                  drawVerticalLine: false,
                  getDrawingHorizontalLine: (_) =>
                      const FlLine(color: AppColors.border, strokeWidth: 1),
                ),
                titlesData: FlTitlesData(
                  topTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                  rightTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                  leftTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      maxIncluded: false,
                      reservedSize: 54,
                      getTitlesWidget: (v, meta) => Text(
                        kind == 'cost' ? v.toStringAsFixed(3) : usageNumber(v),
                        style: const TextStyle(
                          fontSize: 10,
                          color: AppColors.textMuted,
                        ),
                      ),
                    ),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      maxIncluded: false,
                      reservedSize: 32,
                      interval: math
                          .max(1, (points.length / 4).ceil())
                          .toDouble(),
                      getTitlesWidget: (v, meta) {
                        if (v != v.roundToDouble() ||
                            v < 0 ||
                            v >= points.length) {
                          return const SizedBox.shrink();
                        }
                        final t = points[v.toInt()].time;
                        return Padding(
                          padding: const EdgeInsets.only(top: 7),
                          child: Text(
                            snapshot.query.grain == UsageGrain.hour
                                ? '${t.month}/${t.day} ${t.hour}时'
                                : '${t.month}/${t.day}',
                            style: const TextStyle(
                              fontSize: 10,
                              color: AppColors.textMuted,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                lineBarsData: lines,
                betweenBarsData: stacked
                    ? [
                        BetweenBarsData(
                          fromIndex: 0,
                          toIndex: 1,
                          color: AppColors.success.withValues(alpha: 0.25),
                        ),
                      ]
                    : [],
                lineTouchData: LineTouchData(
                  touchTooltipData: LineTouchTooltipData(
                    fitInsideHorizontally: true,
                    fitInsideVertically: true,
                    getTooltipItems: (spots) => spots.map((spot) {
                      final point =
                          points[spot.x.round().clamp(0, points.length - 1)];
                      final m = point.metrics;
                      final value = stacked
                          ? (spot.barIndex == 0
                                ? '输入 ${m.input}'
                                : '输出 ${m.output}\n原始总 token ${m.tokens}')
                          : kind == 'calls'
                          ? '${m.calls} 次调用'
                          : '¥${m.cost.toStringAsFixed(6)}';
                      return LineTooltipItem(
                        '${spot.barIndex == 0 ? '${timeLabel(point.time)}\n' : ''}$value',
                        TextStyle(color: spot.bar.color, fontSize: 12),
                      );
                    }).toList(),
                  ),
                ),
              ),
              duration: Duration.zero,
            ),
          ),
        ],
      ),
    );
  }
}

class _Distribution extends StatefulWidget {
  const _Distribution({
    required this.title,
    required this.groups,
    required this.total,
    this.onSelect,
  });
  final String title;
  final List<UsageGroup> groups;
  final int total;
  final ValueChanged<UsageGroup>? onSelect;
  @override
  State<_Distribution> createState() => _DistributionState();
}

class _DistributionState extends State<_Distribution> {
  bool _expanded = false;
  @override
  Widget build(BuildContext context) {
    final groups = widget.groups;
    final maximum = groups.fold<int>(
      1,
      (n, g) => math.max(n, g.metrics.tokens),
    );
    return SectionCard(
      title: widget.title,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final g in _expanded ? groups : groups.take(8))
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: widget.onSelect == null
                    ? null
                    : () => widget.onSelect!(g),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    vertical: 7,
                    horizontal: 6,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Tooltip(
                              message:
                                  '${g.label}\nID: ${g.key}\n${g.metrics.tokens} token · ${g.metrics.calls} 次 · ¥${g.metrics.cost.toStringAsFixed(6)}',
                              child: Text(
                                g.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(fontSize: 12),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '${usageNumber(g.metrics.tokens)} · ${widget.total == 0 ? '—' : '${(g.metrics.tokens / widget.total * 100).toStringAsFixed(1)}%'}',
                            style: _muted,
                          ),
                        ],
                      ),
                      const SizedBox(height: 7),
                      LinearProgressIndicator(
                        value: (g.metrics.tokens / maximum).clamp(0, 1),
                        minHeight: 5,
                        backgroundColor: AppColors.surfaceHigh,
                        color: AppColors.accent,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (groups.length > 8)
            TextButton(
              onPressed: () => setState(() => _expanded = !_expanded),
              child: Text(_expanded ? '收起' : '查看全部 ${groups.length} 项'),
            ),
        ],
      ),
    );
  }
}

class _Heatmap extends StatelessWidget {
  const _Heatmap({required this.snapshot});
  final UsageSnapshot snapshot;
  @override
  Widget build(BuildContext context) {
    final maximum = snapshot.heatmap.fold<int>(1, math.max);
    return SectionCard(
      title: '星期 × 小时消耗热力图（北京时间）',
      child: LayoutBuilder(
        builder: (context, box) {
          final width = math.max(650.0, box.maxWidth);
          final cell = (width - 44) / 24;
          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              width: width,
              child: Column(
                children: [
                  Row(
                    children: [
                      const SizedBox(width: 44),
                      for (var hour = 0; hour < 24; hour++)
                        SizedBox(
                          width: cell,
                          child: Text(
                            hour % 3 == 0 ? '$hour' : '',
                            textAlign: TextAlign.center,
                            style: _muted,
                          ),
                        ),
                    ],
                  ),
                  for (var day = 0; day < 7; day++)
                    Row(
                      children: [
                        SizedBox(
                          width: 44,
                          child: Text(
                            ['周一', '周二', '周三', '周四', '周五', '周六', '周日'][day],
                            style: _muted,
                          ),
                        ),
                        for (var hour = 0; hour < 24; hour++)
                          Tooltip(
                            message:
                                '${['周一', '周二', '周三', '周四', '周五', '周六', '周日'][day]} $hour:00–${hour + 1}:00\n${snapshot.heatmap[day * 24 + hour]} token',
                            child: Container(
                              width: cell - 4,
                              height: 24,
                              margin: const EdgeInsets.all(2),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(3),
                                color: Color.lerp(
                                  AppColors.surfaceHigh,
                                  AppColors.accent,
                                  snapshot.heatmap[day * 24 + hour] / maximum,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  const Padding(
                    padding: EdgeInsets.only(top: 10),
                    child: Text('浅色为低用量，亮色为高用量；悬停查看精确值。', style: _muted),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _Insights extends StatelessWidget {
  const _Insights({required this.snapshot});
  final UsageSnapshot snapshot;
  @override
  Widget build(BuildContext context) {
    final s = snapshot;
    final session = s.groups['session']!.first,
        model = s.groups['model']!.first;
    final peak = s.trend.reduce(
      (a, b) => a.metrics.tokens >= b.metrics.tokens ? a : b,
    );
    return SectionCard(
      title: '统计解读',
      child: Text(
        '最大消耗会话：${session.label}（${session.metrics.tokens} token）。\n'
        '峰值时间桶：${timeLabel(peak.time)}（${peak.metrics.tokens} token）。\n'
        '主要模型：${model.label}（${model.metrics.tokens} token）。\n'
        '较上一等长区间：总 token ${changeLabel(s.metrics.tokens, s.previous.tokens)}，'
        '调用次数 ${changeLabel(s.metrics.calls, s.previous.calls)}，账面费用 ${changeLabel(s.metrics.cost, s.previous.cost)}。',
        style: const TextStyle(
          fontSize: 12,
          height: 1.9,
          color: AppColors.textSecondary,
        ),
      ),
    );
  }
}

class _UsageDetails extends StatelessWidget {
  const _UsageDetails({required this.controller, required this.locked});
  final UsageController controller;
  final bool locked;

  @override
  Widget build(BuildContext context) {
    final c = controller, details = c.details;
    const sortColumns = {
      0: UsageSort.timestamp,
      6: UsageSort.input,
      7: UsageSort.output,
      8: UsageSort.tokens,
      9: UsageSort.cost,
      10: UsageSort.duration,
    };
    void order(int index, bool asc) =>
        c.loadDetails(order: sortColumns[index], asc: asc);
    return SectionCard(
      title: '调用明细 · 每页 100 条',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (c.detailsLoading) const LinearProgressIndicator(),
          if (c.detailsError != null)
            Row(
              children: [
                Expanded(
                  child: _notice(
                    c.detailsError!.message,
                    stale: details != null,
                  ),
                ),
                TextButton(
                  onPressed: () => c.loadDetails(page: details?.page ?? 0),
                  child: const Text('重试'),
                ),
              ],
            ),
          if (details != null) ...[
            if (c.detailsError != null || c.detailsLoading)
              const Text('以下明细为上次成功读取的页面。', style: _muted),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: DataTable(
                sortColumnIndex: sortColumns.entries
                    .firstWhere((e) => e.value == c.sort)
                    .key,
                sortAscending: c.ascending,
                columnSpacing: 22,
                headingRowHeight: 42,
                dataRowMinHeight: 38,
                dataRowMaxHeight: 50,
                columns: [
                  for (final e in [
                    '时间（北京）',
                    '会话 / ID',
                    '模型',
                    '任务',
                    '供应商',
                    '请求类型',
                    '输入',
                    '输出',
                    '总 token',
                    '账面费用（元）',
                    '耗时（秒）',
                  ].asMap().entries)
                    DataColumn(
                      label: Text(
                        e.value,
                        style: const TextStyle(fontSize: 12),
                      ),
                      numeric: e.key >= 6,
                      onSort:
                          !locked &&
                              !c.detailsLoading &&
                              sortColumns.containsKey(e.key)
                          ? order
                          : null,
                    ),
                ],
                rows: [
                  for (final r in details.rows)
                    DataRow(
                      cells: [
                        DataCell(Text('${r['timestamp']}', style: _muted)),
                        DataCell(_cell(_sessionLabel(r), width: 220)),
                        DataCell(
                          _cell(
                            '${r['model_name']} / ${r['model_assign_name']}',
                            width: 170,
                          ),
                        ),
                        DataCell(
                          _cell('${r['task_name'] ?? '未记录'}', width: 120),
                        ),
                        DataCell(
                          _cell(
                            '${r['model_api_provider_name'] ?? '未记录'}',
                            width: 100,
                          ),
                        ),
                        DataCell(
                          _cell('${r['request_type'] ?? '未记录'}', width: 160),
                        ),
                        for (final key in [
                          'prompt_tokens',
                          'completion_tokens',
                          'total_tokens',
                        ])
                          DataCell(Text('${r[key] ?? 0}', style: _muted)),
                        DataCell(
                          Text(
                            (r['cost'] as num?)?.toStringAsFixed(6) ?? '—',
                            style: _muted,
                          ),
                        ),
                        DataCell(
                          Text(
                            (r['time_cost'] as num?)?.toStringAsFixed(3) ?? '—',
                            style: _muted,
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              alignment: WrapAlignment.end,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 10,
              children: [
                Text(
                  '共 ${details.total} 条 · 第 ${details.page + 1} / ${math.max(1, (details.total / 100).ceil())} 页',
                  style: _muted,
                ),
                IconButton(
                  tooltip: '上一页',
                  onPressed: !locked && !c.detailsLoading && details.page > 0
                      ? () => c.loadDetails(page: details.page - 1)
                      : null,
                  icon: const Icon(Icons.chevron_left),
                ),
                IconButton(
                  tooltip: '下一页',
                  onPressed:
                      !locked &&
                          !c.detailsLoading &&
                          (details.page + 1) * 100 < details.total
                      ? () => c.loadDetails(page: details.page + 1)
                      : null,
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _cell(String value, {required double width}) => SizedBox(
    width: width,
    child: Tooltip(
      message: value,
      child: Text(
        value,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: _muted,
      ),
    ),
  );

  String _sessionLabel(Map<String, Object?> r) {
    if (r['session_key'] == '') return '未归属（含后台任务）';
    final name = r['session_type'] == 'group'
        ? '${r['group_name'] ?? ''} · 群 ${r['group_id']}'
        : r['session_type'] == 'private'
        ? '${r['user_cardname'] ?? r['user_nickname'] ?? ''} · 用户 ${r['user_id']}'
        : '未知会话';
    return '$name\n${r['session_key']}';
  }
}
