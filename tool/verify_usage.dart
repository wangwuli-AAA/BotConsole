import 'dart:convert';
import 'dart:io';

import 'package:bot_console/usage/usage_models.dart';
import 'package:bot_console/usage/usage_repository.dart';

/// Read-only reconciliation against a supplied MaiBot database.
/// `dart run tool/verify_usage.dart <database> [detail-csv-output]`
Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('用法：dart run tool/verify_usage.dart <数据库> [明细CSV路径]');
    exitCode = 64;
    return;
  }
  const repository = UsageRepository();
  final watch = Stopwatch()..start();
  final snapshot = await repository.snapshot(
    args.first,
    UsageQuery.range(UsageRange.day),
  );
  final elapsed = watch.elapsedMilliseconds;
  final db = openUsageDatabase(args.first);
  int calls = 0, tokens = 0, input = 0, output = 0, hit = 0, miss = 0;
  double cost = 0;
  try {
    final rows = db.select(
      'SELECT * FROM llm_usage WHERE timestamp >= ? AND timestamp < ? AND id <= ?',
      [
        sqlTime(snapshot.start),
        sqlTime(snapshot.query.end),
        snapshot.highWater,
      ],
    );
    for (final row in rows) {
      calls++;
      tokens += (row['total_tokens'] as num).toInt();
      final prompt = (row['prompt_tokens'] as num).toInt();
      input += prompt;
      output += (row['completion_tokens'] as num).toInt();
      cost += (row['cost'] as num).toDouble();
      if (row['prompt_cache_enabled'] == 1) {
        var h = (row['prompt_cache_hit_tokens'] as num?)?.toInt() ?? 0;
        var m = (row['prompt_cache_miss_tokens'] as num?)?.toInt() ?? 0;
        if (h < 0) h = 0;
        if (m < 0) m = 0;
        if (m == 0 && h > 0) m = prompt - h > 0 ? prompt - h : 0;
        if (h + m == 0 && prompt > 0) m = prompt;
        hit += h;
        miss += m;
      }
    }
  } finally {
    db.close();
  }
  final m = snapshot.metrics;
  if (calls != m.calls ||
      tokens != m.tokens ||
      input != m.input ||
      output != m.output ||
      hit != m.hit ||
      miss != m.miss ||
      (cost - m.cost).abs() > 1e-8) {
    throw StateError('原始记录与统计快照不一致');
  }
  for (final entry in snapshot.groups.entries) {
    if (entry.value.fold<int>(0, (n, g) => n + g.metrics.tokens) != tokens ||
        entry.value.fold<int>(0, (n, g) => n + g.metrics.calls) != calls) {
      throw StateError('${entry.key} 维度无法对账');
    }
  }
  if (snapshot.trend.fold<int>(0, (n, p) => n + p.metrics.tokens) != tokens ||
      snapshot.heatmap.fold<int>(0, (n, v) => n + v) != tokens) {
    throw StateError('趋势或热力图无法对账');
  }
  final page = await repository.details(args.first, snapshot);
  if (page.total != calls) throw StateError('明细条数不一致');
  int? exported;
  if (args.length > 1) {
    exported = await repository.export(args.first, snapshot, args[1]);
  }
  if (exported != null && exported != calls) throw StateError('导出条数不一致');
  stdout.writeln(
    const JsonEncoder.withIndent('  ').convert({
      'verified': true,
      'database': args.first,
      'startBeijingInclusive': sqlTime(snapshot.start),
      'endBeijingExclusive': sqlTime(snapshot.query.end),
      'highWater': snapshot.highWater,
      'journalMode': snapshot.journalMode,
      'snapshotMilliseconds': elapsed,
      'calls': calls,
      'tokens': tokens,
      'input': input,
      'output': output,
      'costCny': cost,
      'cacheHit': hit,
      'cacheMiss': miss,
      'exportedDetails': exported,
      'sessions': [
        for (final g in snapshot.groups['session']!)
          {
            'id': g.key,
            'label': g.label,
            'type': g.type,
            'tokens': g.metrics.tokens,
            'calls': g.metrics.calls,
          },
      ],
      'dimensionChecks': snapshot.groups.keys.toList(),
    }),
  );
}
