import 'dart:convert';

enum UsageGrain { hour, day, week, month }

enum UsageRange { today, day, week, month, all, custom }

/// UTC-shaped values represent Beijing wall time, never the host time zone.
DateTime usageNow() => DateTime.now().toUtc().add(const Duration(hours: 8));

DateTime wallTime(DateTime value) => DateTime.utc(
  value.year,
  value.month,
  value.day,
  value.hour,
  value.minute,
  value.second,
  value.millisecond,
  value.microsecond,
);

String sqlTime(DateTime value) {
  final text = value.toIso8601String().replaceAll('T', ' ').replaceAll('Z', '');
  return text.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');
}

String timeLabel(DateTime value) => sqlTime(value).substring(0, 16);

DateTime bucketStart(DateTime t, UsageGrain grain) => switch (grain) {
  UsageGrain.hour => DateTime.utc(t.year, t.month, t.day, t.hour),
  UsageGrain.day => DateTime.utc(t.year, t.month, t.day),
  UsageGrain.week => DateTime.utc(
    t.year,
    t.month,
    t.day,
  ).subtract(Duration(days: t.weekday - 1)),
  UsageGrain.month => DateTime.utc(t.year, t.month),
};

DateTime nextBucket(DateTime t, UsageGrain grain) => switch (grain) {
  UsageGrain.hour => t.add(const Duration(hours: 1)),
  UsageGrain.day => t.add(const Duration(days: 1)),
  UsageGrain.week => t.add(const Duration(days: 7)),
  UsageGrain.month => DateTime.utc(t.year, t.month + 1),
};

class UsageQuery {
  const UsageQuery({
    required this.end,
    this.start,
    this.grain = UsageGrain.hour,
    this.sessionType,
    this.sessionId,
    this.model,
    this.task,
    this.provider,
    this.requestType,
  });

  factory UsageQuery.range(
    UsageRange range, {
    UsageGrain grain = UsageGrain.hour,
    DateTime? now,
  }) {
    final end = now ?? usageNow();
    return UsageQuery(
      end: end,
      grain: grain,
      start: switch (range) {
        UsageRange.today => DateTime.utc(end.year, end.month, end.day),
        UsageRange.day => end.subtract(const Duration(hours: 24)),
        UsageRange.week => end.subtract(const Duration(days: 7)),
        UsageRange.month => end.subtract(const Duration(days: 30)),
        UsageRange.all => null,
        UsageRange.custom => end.subtract(const Duration(hours: 24)),
      },
    );
  }

  final DateTime? start;
  final DateTime end;
  final UsageGrain grain;
  final String? sessionType, sessionId, model, task, provider, requestType;

  UsageQuery withRange(DateTime? start, DateTime end, UsageGrain grain) =>
      UsageQuery(
        start: start,
        end: end,
        grain: grain,
        sessionType: sessionType,
        sessionId: sessionId,
        model: model,
        task: task,
        provider: provider,
        requestType: requestType,
      );

  UsageQuery filter(String key, String? value) => UsageQuery(
    start: start,
    end: end,
    grain: grain,
    sessionType: key == 'type' ? value : sessionType,
    sessionId: key == 'session' || key == 'type'
        ? (key == 'session' ? value : null)
        : sessionId,
    model: key == 'model' ? value : model,
    task: key == 'task' ? value : task,
    provider: key == 'provider' ? value : provider,
    requestType: key == 'request' ? value : requestType,
  );
}

class UsageMetrics {
  const UsageMetrics({
    this.tokens = 0,
    this.input = 0,
    this.output = 0,
    this.calls = 0,
    this.cost = 0,
    this.hit = 0,
    this.miss = 0,
    this.seconds = 0,
    this.timedCalls = 0,
  });
  factory UsageMetrics.row(Map<String, Object?> r) => UsageMetrics(
    tokens: (r['tokens'] as num).toInt(),
    input: (r['input'] as num).toInt(),
    output: (r['output'] as num).toInt(),
    calls: (r['calls'] as num).toInt(),
    cost: (r['cost'] as num).toDouble(),
    hit: (r['hit'] as num).toInt(),
    miss: (r['miss'] as num).toInt(),
    seconds: (r['seconds'] as num).toDouble(),
    timedCalls: (r['timed_calls'] as num).toInt(),
  );
  final int tokens, input, output, calls, hit, miss, timedCalls;
  final double cost, seconds;
  double? get cacheRate => hit + miss == 0 ? null : hit / (hit + miss);
  double? get meanSeconds => timedCalls == 0 ? null : seconds / timedCalls;
}

class UsageGroup {
  const UsageGroup(this.key, this.label, this.metrics, {this.type});
  final String key, label;
  final String? type;
  final UsageMetrics metrics;
}

class UsagePoint {
  const UsagePoint(this.time, this.metrics);
  final DateTime time;
  final UsageMetrics metrics;
}

class UsageSnapshot {
  const UsageSnapshot({
    required this.query,
    required this.start,
    required this.metrics,
    required this.previous,
    required this.trend,
    required this.groups,
    required this.options,
    required this.heatmap,
    required this.highWater,
    required this.journalMode,
    required this.loadedAt,
  });
  final UsageQuery query;
  final DateTime start, loadedAt;
  final UsageMetrics metrics, previous;
  final List<UsagePoint> trend;
  final Map<String, List<UsageGroup>> groups, options;
  final List<int> heatmap;
  final int highWater;
  final String journalMode;
}

enum UsageSort { timestamp, tokens, input, output, cost, duration }

class UsagePage {
  const UsagePage(this.rows, this.total, this.page);
  final List<Map<String, Object?>> rows;
  final int total, page;
}

class UsageFailure implements Exception {
  const UsageFailure(this.code, this.message);
  final String code, message;
  @override
  String toString() => message;
}

String changeLabel(
  num? current,
  num? previous, {
  bool percentagePoints = false,
}) {
  if (current == null || previous == null) return '—';
  if (percentagePoints) {
    final delta = (current - previous) * 100;
    return '${delta >= 0 ? '+' : ''}${delta.toStringAsFixed(1)} 个百分点';
  }
  if (previous == 0) return current == 0 ? '—' : '新增';
  final delta = (current - previous) / previous.abs() * 100;
  return '${delta >= 0 ? '+' : ''}${delta.toStringAsFixed(1)}%';
}

String modelLabel(String key) {
  final values = (jsonDecode(key) as List).cast<String>();
  return '${values[0]}${values[1].isEmpty || values[1] == values[0] ? '' : ' / ${values[1]}'} · ${values[2]}';
}
