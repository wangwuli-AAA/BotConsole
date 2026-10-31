import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'usage_models.dart';

const _session =
    "CASE WHEN u.session_id IS NULL OR trim(u.session_id) = '' THEN '' ELSE u.session_id END";
const _type =
    "CASE WHEN $_session = '' THEN 'unattributed' "
    "WHEN c.group_id IS NOT NULL AND trim(c.group_id) != '' THEN 'group' "
    "WHEN c.user_id IS NOT NULL AND trim(c.user_id) != '' THEN 'private' "
    "ELSE 'unknown' END";
const _from =
    " FROM llm_usage u LEFT JOIN chat_sessions c ON u.session_id = c.session_id AND ($_session) != '' ";
const _model =
    "json_array(coalesce(u.model_name,''), coalesce(u.model_assign_name,''), coalesce(u.model_api_provider_name,''))";
const _hit =
    'CASE WHEN coalesce(u.prompt_cache_enabled,0) != 0 THEN max(coalesce(u.prompt_cache_hit_tokens,0),0) ELSE 0 END';
const _rawMiss = 'max(coalesce(u.prompt_cache_miss_tokens,0),0)';
const _miss =
    'CASE WHEN coalesce(u.prompt_cache_enabled,0) = 0 THEN 0 '
    'WHEN $_rawMiss = 0 THEN max(coalesce(u.prompt_tokens,0) - ($_hit),0) ELSE $_rawMiss END';
const _metrics =
    'coalesce(sum(u.total_tokens),0) tokens, '
    'coalesce(sum(u.prompt_tokens),0) input, coalesce(sum(u.completion_tokens),0) output, '
    'count(*) calls, coalesce(sum(u.cost),0) cost, coalesce(sum($_hit),0) hit, '
    'coalesce(sum($_miss),0) miss, coalesce(sum(u.time_cost),0) seconds, '
    'count(u.time_cost) timed_calls';
const _dimensions = {
  'session': _session,
  'model': _model,
  'task': "coalesce(u.task_name,'')",
  'provider': "coalesce(u.model_api_provider_name,'')",
  'request': "coalesce(u.request_type,'')",
};

/// Opens only existing databases. Neither schema nor journal mode is changed.
Database openUsageDatabase(String path) {
  if (!File(path).existsSync()) {
    throw const UsageFailure('missing', '找不到用量数据库，请在设置中检查 MaiBot 目录或数据库路径。');
  }
  final db = sqlite3.open(path, mode: OpenMode.readOnly);
  try {
    db.execute('PRAGMA query_only = ON');
    db.execute('PRAGMA busy_timeout = 3000');
    const required = {
      'llm_usage': {
        'id',
        'model_name',
        'model_assign_name',
        'model_api_provider_name',
        'session_id',
        'task_name',
        'request_type',
        'time_cost',
        'timestamp',
        'prompt_tokens',
        'completion_tokens',
        'total_tokens',
        'prompt_cache_enabled',
        'prompt_cache_hit_tokens',
        'prompt_cache_miss_tokens',
        'cost',
      },
      'chat_sessions': {
        'session_id',
        'user_id',
        'user_nickname',
        'user_cardname',
        'group_id',
        'group_name',
      },
    };
    for (final entry in required.entries) {
      final columns = db
          .select('PRAGMA table_info(${entry.key})')
          .map((r) => r['name'] as String)
          .toSet();
      final missing = entry.value.difference(columns);
      if (missing.isNotEmpty) {
        throw UsageFailure(
          'schema',
          '数据库字段不兼容：${entry.key} 缺少 ${missing.join(', ')}',
        );
      }
    }
    return db;
  } catch (_) {
    db.close();
    rethrow;
  }
}

class UsageRepository {
  const UsageRepository();

  Future<UsageSnapshot> snapshot(String path, UsageQuery query) =>
      _run('snapshot', path, query);

  Future<UsagePage> details(
    String path,
    UsageSnapshot snapshot, {
    int page = 0,
    UsageSort sort = UsageSort.timestamp,
    bool ascending = false,
  }) => _run(
    'details',
    path,
    snapshot.query,
    snapshot: snapshot,
    page: page,
    sort: sort,
    ascending: ascending,
  );

  Future<int> export(
    String path,
    UsageSnapshot snapshot,
    String destination, {
    bool summary = false,
  }) async {
    final source = p.normalize(p.absolute(path)).toLowerCase();
    final target = p.normalize(p.absolute(destination)).toLowerCase();
    if ([source, '$source-wal', '$source-shm'].contains(target)) {
      throw const UsageFailure('export', '导出文件不能覆盖用量数据库或其日志文件。');
    }
    final temporary =
        '$destination.botconsole-${DateTime.now().microsecondsSinceEpoch}.part';
    try {
      return await _run(
        'export',
        path,
        snapshot.query,
        snapshot: snapshot,
        destination: destination,
        temporary: temporary,
        summary: summary,
      );
    } finally {
      final file = File(temporary);
      if (file.existsSync()) file.deleteSync();
    }
  }

  Future<T> _run<T>(
    String action,
    String path,
    UsageQuery query, {
    UsageSnapshot? snapshot,
    int page = 0,
    UsageSort sort = UsageSort.timestamp,
    bool ascending = false,
    String? destination,
    String? temporary,
    bool summary = false,
  }) async {
    final port = ReceivePort();
    Isolate? worker;
    try {
      worker = await Isolate.spawn(_worker, (
        port.sendPort,
        action,
        path,
        query,
        snapshot,
        page,
        sort,
        ascending,
        destination,
        temporary,
        summary,
      ), onError: port.sendPort);
      final message = await port.first.timeout(
        Duration(seconds: action == 'export' ? 120 : 20),
      );
      if (message is List && message.length == 2 && message.first is bool) {
        if (message.first == true) return message[1] as T;
        throw message[1] as UsageFailure;
      }
      throw const UsageFailure('read', '统计后台查询异常，请重试。');
    } on TimeoutException {
      throw const UsageFailure('timeout', '读取超时，请缩小时间范围后重试。');
    } finally {
      worker?.kill(priority: Isolate.immediate);
      port.close();
    }
  }
}

typedef _Request = (
  SendPort,
  String,
  String,
  UsageQuery,
  UsageSnapshot?,
  int,
  UsageSort,
  bool,
  String?,
  String?,
  bool,
);

void _worker(_Request request) {
  final (
    port,
    action,
    path,
    query,
    snapshot,
    page,
    sort,
    ascending,
    destination,
    temporary,
    summary,
  ) = request;
  Database? db;
  late List<Object?> response;
  try {
    db = openUsageDatabase(path);
    db.execute('BEGIN');
    // Fail rather than multiplying records if an incompatible DB has duplicate identities.
    if (db
        .select(
          'SELECT session_id FROM chat_sessions WHERE session_id IS NOT NULL '
          "AND session_id != '' GROUP BY session_id HAVING count(*) > 1 LIMIT 1",
        )
        .isNotEmpty) {
      throw const UsageFailure('schema', '数据库会话 ID 不唯一，无法安全汇总。');
    }
    final Object result = switch (action) {
      'snapshot' => _snapshot(db, query),
      'details' => _details(db, snapshot!, page, sort, ascending),
      'export' => _export(db, snapshot!, destination!, temporary!, summary),
      _ => throw StateError('Unknown usage action'),
    };
    response = [true, result];
  } catch (error) {
    final UsageFailure failure;
    if (error is UsageFailure) {
      failure = error;
    } else if (error is SqliteException && [5, 6].contains(error.resultCode)) {
      failure = const UsageFailure('timeout', '数据库繁忙，已等待 3 秒，请稍后刷新。');
    } else {
      failure = UsageFailure(
        action == 'export' ? 'export' : 'read',
        '读取或导出失败：$error',
      );
    }
    response = [false, failure];
  } finally {
    if (db != null) {
      db.execute('ROLLBACK');
      db.close();
    }
  }
  // Close native resources before the caller disposes this worker isolate.
  port.send(response);
}

(String, List<Object?>) _where(
  UsageQuery q,
  DateTime start,
  int highWater, {
  bool filters = true,
}) {
  final clauses = ['u.timestamp >= ?', 'u.timestamp < ?', 'u.id <= ?'];
  final args = <Object?>[sqlTime(start), sqlTime(q.end), highWater];
  if (filters) {
    for (final entry in <String, String?>{
      _type: q.sessionType,
      _session: q.sessionId,
      _model: q.model,
      _dimensions['task']!: q.task,
      _dimensions['provider']!: q.provider,
      _dimensions['request']!: q.requestType,
    }.entries) {
      if (entry.value != null) {
        clauses.add('${entry.key} = ?');
        args.add(entry.value);
      }
    }
  }
  return (' WHERE ${clauses.join(' AND ')}', args);
}

UsageMetrics _summary(
  Database db,
  UsageQuery q,
  DateTime start,
  int highWater,
) {
  final (where, args) = _where(q, start, highWater);
  return UsageMetrics.row(
    db.select('SELECT $_metrics $_from $where', args).single,
  );
}

List<UsageGroup> _groups(
  Database db,
  String dimension,
  String where,
  List<Object?> args,
) {
  final expression = _dimensions[dimension]!;
  final extra = dimension == 'session'
      ? ", $_type kind, c.group_name, c.group_id, c.user_cardname, c.user_nickname, c.user_id"
      : '';
  return db
      .select(
        'SELECT $expression dimension $extra, $_metrics $_from $where '
        'GROUP BY $expression ORDER BY tokens DESC, dimension',
        args,
      )
      .map((r) {
        final key = r['dimension'] as String;
        String label = key.isEmpty ? '未记录' : key;
        String? type;
        if (dimension == 'session') {
          type = r['kind'] as String;
          String first(List<String> keys) => keys
              .map((k) => '${r[k] ?? ''}')
              .firstWhere((s) => s.isNotEmpty, orElse: () => '');
          label = switch (type) {
            'unattributed' => '未归属（含后台任务）',
            'group' =>
              '${first(['group_name', 'group_id'])} · 群 ${r['group_id']}',
            'private' =>
              '${first(['user_cardname', 'user_nickname', 'user_id'])} · 用户 ${r['user_id']}',
            _ => '未知会话 · $key',
          };
        } else if (dimension == 'model') {
          label = modelLabel(key);
        }
        return UsageGroup(key, label, UsageMetrics.row(r), type: type);
      })
      .toList();
}

UsageSnapshot _snapshot(Database db, UsageQuery query) {
  final highWater =
      (db.select('SELECT coalesce(max(id),0) n FROM llm_usage').single['n']
              as num)
          .toInt();
  final minimum =
      db.select('SELECT min(timestamp) t FROM llm_usage WHERE timestamp < ?', [
            sqlTime(query.end),
          ]).single['t']
          as String?;
  final start =
      query.start ??
      (minimum == null
          ? query.end.subtract(const Duration(hours: 24))
          : DateTime.parse('${minimum.replaceAll(' ', 'T')}Z'));
  if (!start.isBefore(query.end)) {
    throw const UsageFailure('range', '开始时间必须早于结束时间（北京时间）。');
  }
  final metrics = _summary(db, query, start, highWater);
  final previousQuery = query.withRange(
    start.subtract(query.end.difference(start)),
    start,
    query.grain,
  );
  final previous = _summary(db, previousQuery, previousQuery.start!, highWater);
  final (where, args) = _where(query, start, highWater);
  final bucket = switch (query.grain) {
    UsageGrain.hour => "strftime('%Y-%m-%d %H:00:00',u.timestamp)",
    UsageGrain.day => "strftime('%Y-%m-%d 00:00:00',u.timestamp)",
    UsageGrain.week => "date(u.timestamp,'weekday 0','-6 days') || ' 00:00:00'",
    UsageGrain.month => "strftime('%Y-%m-01 00:00:00',u.timestamp)",
  };
  final indexed = {
    for (final r in db.select(
      'SELECT $bucket bucket, $_metrics $_from $where GROUP BY bucket',
      args,
    ))
      r['bucket'] as String: UsageMetrics.row(r),
  };
  final trend = <UsagePoint>[];
  for (
    var t = bucketStart(start, query.grain);
    t.isBefore(query.end);
    t = nextBucket(t, query.grain)
  ) {
    if (trend.length >= 5000) {
      throw const UsageFailure('range', '时间桶超过 5000 个，请改用日、周或月聚合。');
    }
    trend.add(UsagePoint(t, indexed[sqlTime(t)] ?? const UsageMetrics()));
  }
  final groups = {
    for (final key in _dimensions.keys) key: _groups(db, key, where, args),
  };
  final (optionsWhere, optionsArgs) = _where(
    query,
    start,
    highWater,
    filters: false,
  );
  final options = {
    for (final key in _dimensions.keys)
      key: _groups(db, key, optionsWhere, optionsArgs),
  };
  final heatmap = List<int>.filled(168, 0);
  for (final r in db.select(
    "SELECT (cast(strftime('%w',u.timestamp) AS INTEGER)+6)%7 weekday, "
    "cast(strftime('%H',u.timestamp) AS INTEGER) hour, sum(u.total_tokens) tokens $_from $where GROUP BY weekday,hour",
    args,
  )) {
    heatmap[(r['weekday'] as int) * 24 + (r['hour'] as int)] =
        (r['tokens'] as num).toInt();
  }
  return UsageSnapshot(
    query: query,
    start: start,
    metrics: metrics,
    previous: previous,
    trend: trend,
    groups: groups,
    options: options,
    heatmap: heatmap,
    highWater: highWater,
    journalMode: '${db.select('PRAGMA journal_mode').single.values.first}',
    loadedAt: usageNow(),
  );
}

const _detailColumns =
    'u.*, $_session session_key, $_type session_type, '
    'c.group_name, c.group_id, c.user_cardname, c.user_nickname, c.user_id, '
    '($_hit) cache_hit_normalized, ($_miss) cache_miss_normalized';

UsagePage _details(
  Database db,
  UsageSnapshot s,
  int page,
  UsageSort sort,
  bool ascending,
) {
  if (page < 0) throw ArgumentError.value(page);
  final column = switch (sort) {
    UsageSort.timestamp => 'timestamp',
    UsageSort.tokens => 'total_tokens',
    UsageSort.input => 'prompt_tokens',
    UsageSort.output => 'completion_tokens',
    UsageSort.cost => 'cost',
    UsageSort.duration => 'time_cost',
  };
  final (where, args) = _where(s.query, s.start, s.highWater);
  final rows = db.select(
    'SELECT $_detailColumns $_from $where '
    'ORDER BY u.$column ${ascending ? 'ASC' : 'DESC'}, u.id DESC LIMIT ? OFFSET ?',
    [...args, 100, page * 100],
  );
  final total =
      db.select('SELECT count(*) n $_from $where', args).single['n'] as int;
  return UsagePage(
    rows.map((r) => Map<String, Object?>.from(r)).toList(),
    total,
    page,
  );
}

String csvLine(Iterable<Object?> cells) =>
    '${cells.map((cell) {
      final value = '${cell ?? ''}';
      return RegExp('[,"\r\n]').hasMatch(value) ? '"${value.replaceAll('"', '""')}"' : value;
    }).join(',')}\r\n';

int _export(
  Database db,
  UsageSnapshot s,
  String destination,
  String temporary,
  bool summary,
) {
  final file = File(temporary).openSync(mode: FileMode.write);
  var count = 0;
  try {
    file.writeFromSync([0xef, 0xbb, 0xbf]);
    void line(Iterable<Object?> values) =>
        file.writeFromSync(utf8.encode(csvLine(values)));
    if (summary) {
      line([
        '维度',
        '标识',
        '名称',
        '开始（北京时间，含）',
        '结束（北京时间，不含）',
        '总token',
        '输入',
        '输出',
        '调用次数',
        '账面费用（元）',
        '缓存命中',
        '缓存未命中',
        '平均耗时（秒）',
      ]);
      void entry(String dimension, String key, String label, UsageMetrics m) {
        line([
          dimension,
          key,
          label,
          sqlTime(s.start),
          sqlTime(s.query.end),
          m.tokens,
          m.input,
          m.output,
          m.calls,
          m.cost,
          m.hit,
          m.miss,
          m.meanSeconds,
        ]);
        count++;
      }

      entry('整体', '', '当前筛选', s.metrics);
      for (final point in s.trend) {
        entry('时间', sqlTime(point.time), '', point.metrics);
      }
      for (final dimension in s.groups.entries) {
        for (final group in dimension.value) {
          entry(dimension.key, group.key, group.label, group.metrics);
        }
      }
    } else {
      const columns = [
        'id',
        'timestamp',
        'session_key',
        'session_type',
        'group_name',
        'group_id',
        'user_cardname',
        'user_nickname',
        'user_id',
        'model_name',
        'model_assign_name',
        'model_api_provider_name',
        'task_name',
        'request_type',
        'prompt_tokens',
        'completion_tokens',
        'total_tokens',
        'cost',
        'time_cost',
        'prompt_cache_enabled',
        'prompt_cache_hit_tokens',
        'prompt_cache_miss_tokens',
        'cache_hit_normalized',
        'cache_miss_normalized',
      ];
      line(columns);
      final (where, args) = _where(s.query, s.start, s.highWater);
      var lastId = -1;
      while (true) {
        final rows = db.select(
          'SELECT $_detailColumns $_from $where AND u.id > ? ORDER BY u.id LIMIT 1000',
          [...args, lastId],
        );
        if (rows.isEmpty) break;
        for (final row in rows) {
          line(columns.map((key) => row[key]));
          count++;
        }
        lastId = rows.last['id'] as int;
      }
    }
    file.flushSync();
  } finally {
    file.closeSync();
  }
  File(temporary).renameSync(destination);
  return count;
}
