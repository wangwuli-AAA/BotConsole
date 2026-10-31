import 'dart:convert';
import 'dart:io';

import 'package:bot_console/usage/usage_models.dart';
import 'package:bot_console/usage/usage_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';

void main() {
  late Directory temp;
  late String path;
  late Database writer;
  const repository = UsageRepository();
  final start = DateTime.utc(2026, 10, 31);
  UsageQuery query({UsageGrain grain = UsageGrain.hour}) =>
      UsageQuery(start: start, end: DateTime.utc(2026, 11, 2), grain: grain);

  setUp(() {
    temp = Directory.systemTemp.createTempSync('botconsole-usage-');
    path = '${temp.path}/usage.db';
    writer = sqlite3.open(path);
    writer.execute('PRAGMA journal_mode=WAL');
    writer.execute(
      'CREATE TABLE chat_sessions (session_id TEXT, user_id TEXT, '
      'user_nickname TEXT, user_cardname TEXT, group_id TEXT, group_name TEXT)',
    );
    writer.execute(
      'CREATE TABLE llm_usage (id INTEGER PRIMARY KEY, model_name TEXT, '
      'model_assign_name TEXT, model_api_provider_name TEXT, session_id TEXT, '
      'task_name TEXT, request_type TEXT, time_cost REAL, timestamp TEXT, '
      'prompt_tokens INTEGER, completion_tokens INTEGER, total_tokens INTEGER, '
      'prompt_cache_enabled INTEGER, prompt_cache_hit_tokens INTEGER, '
      'prompt_cache_miss_tokens INTEGER, cost REAL)',
    );
    writer.execute(
      "INSERT INTO chat_sessions VALUES ('g1','','','','101','同名'),"
      "('g2','','','','102','同名'),('p1','201','朋友','','','')",
    );
  });
  tearDown(() {
    writer.close();
    temp.deleteSync(recursive: true);
  });

  void add(
    int id,
    String time, {
    String? session = 'g1',
    String model = 'm',
    String provider = 'p',
    String task = '回复',
    String request = 'chat',
    int input = 100,
    int output = 10,
    int? tokens,
    int enabled = 1,
    int hit = 60,
    int miss = 0,
    double cost = 0.1,
    double? duration = 2,
  }) {
    writer.execute(
      'INSERT INTO llm_usage VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)',
      [
        id,
        model,
        'alias',
        provider,
        session,
        task,
        request,
        duration,
        time,
        input,
        output,
        tokens ?? input + output,
        enabled,
        hit,
        miss,
        cost,
      ],
    );
  }

  test(
    'half-open range, midnight/month buckets, empty buckets and previous interval',
    () async {
      add(1, '2026-10-30 23:59:59.999999');
      add(2, '2026-10-31 00:00:00');
      add(3, '2026-11-01 00:00:00.000000', tokens: 500);
      add(4, '2026-11-02 00:00:00.000000');
      final s = await repository.snapshot(path, query());
      expect(s.metrics.tokens, 610);
      expect(s.previous.tokens, 110);
      expect(s.trend.length, 48);
      expect(s.trend.first.metrics.tokens, 110);
      expect(s.trend[1].metrics.tokens, 0);
      expect(s.trend[24].metrics.tokens, 500);
      expect(s.trend.fold(0, (int n, p) => n + p.metrics.tokens), 610);
      final months = await repository.snapshot(
        path,
        query(grain: UsageGrain.month),
      );
      expect(months.trend.map((p) => p.time), [
        DateTime.utc(2026, 10),
        DateTime.utc(2026, 11),
      ]);
      final weeks = await repository.snapshot(
        path,
        UsageQuery(
          start: start,
          end: DateTime.utc(2026, 11, 3),
          grain: UsageGrain.week,
        ),
      );
      expect(weeks.trend.map((p) => p.time), [
        DateTime.utc(2026, 10, 26),
        DateTime.utc(2026, 11, 2),
      ]);
      expect(weeks.trend.last.metrics.tokens, 110);
    },
  );

  test(
    'session identities, unresolved associations, combined filters and dimension reconciliation',
    () async {
      add(1, '2026-10-31 12:00:00', session: 'g1');
      add(2, '2026-10-31 12:00:00', session: 'g2', provider: 'p2');
      add(3, '2026-10-31 12:00:00', session: 'p1');
      add(4, '2026-10-31 12:00:00', session: null);
      add(5, '2026-10-31 12:00:00', session: '');
      add(6, '2026-10-31 12:00:00', session: 'lost', task: '后台');
      final s = await repository.snapshot(path, query());
      expect(s.groups['session']!.length, 5);
      expect(s.groups['session']!.where((g) => g.type == 'group').length, 2);
      expect(
        s.groups['session']!.singleWhere((g) => g.key == '').metrics.calls,
        2,
      );
      expect(
        s.groups['session']!.singleWhere((g) => g.key == 'lost').type,
        'unknown',
      );
      for (final groups in s.groups.values) {
        expect(
          groups.fold(0, (int n, g) => n + g.metrics.tokens),
          s.metrics.tokens,
        );
        expect(groups.fold(0, (int n, g) => n + g.metrics.calls), 6);
      }
      final model = s.groups['model']!
          .singleWhere((g) => g.key.contains('p2'))
          .key;
      final filtered = await repository.snapshot(
        path,
        query()
            .filter('type', 'group')
            .filter('session', 'g2')
            .filter('provider', 'p2')
            .filter('model', model)
            .filter('task', '回复')
            .filter('request', 'chat'),
      );
      expect(filtered.metrics.calls, 1);
      expect(filtered.options['session']!.length, 5);
      expect(
        (await repository.details(path, filtered)).rows.single['session_key'],
        'g2',
      );
    },
  );

  test(
    'cache rules, original total, cost precision and zero baseline',
    () async {
      add(1, '2026-10-31 12:00:00', tokens: 999, enabled: 0, hit: 99, miss: 99);
      add(2, '2026-10-31 12:00:00', hit: 60, miss: 0, cost: 0.2);
      add(3, '2026-10-31 12:00:00', hit: -10, miss: -1, duration: null);
      add(4, '2026-10-31 12:00:00', hit: 30, miss: 80);
      final s = await repository.snapshot(path, query());
      expect(s.metrics.tokens, 1329);
      expect(s.metrics.input, 400);
      expect(s.metrics.hit, 90);
      expect(s.metrics.miss, 220);
      expect(s.metrics.cacheRate, closeTo(90 / 310, 1e-10));
      expect(s.metrics.cost, closeTo(0.5, 1e-12));
      expect(s.metrics.meanSeconds, 2);
      expect(changeLabel(s.metrics.tokens, s.previous.tokens), '新增');
      expect(changeLabel(0, 0), '—');
      expect(const UsageMetrics().cacheRate, null);
    },
  );

  test(
    'read-only/WAL writer coexistence and duplicate session guard',
    () async {
      add(1, '2026-10-31 12:00:00');
      final db = openUsageDatabase(path);
      expect(
        () => db.execute('DELETE FROM llm_usage'),
        throwsA(isA<SqliteException>()),
      );
      expect(db.select('PRAGMA query_only').single.values.first, 1);
      db.close();
      writer.execute('BEGIN IMMEDIATE');
      add(2, '2026-10-31 12:00:01');
      final s = await repository.snapshot(path, query());
      expect(s.metrics.calls, 1);
      expect(s.journalMode, 'wal');
      writer.execute('COMMIT');
      expect((await repository.snapshot(path, query())).metrics.calls, 2);
      writer.execute(
        "INSERT INTO chat_sessions VALUES ('g1','','','','103','同名')",
      );
      await expectLater(
        repository.snapshot(path, query()),
        throwsA(isA<UsageFailure>()),
      );
    },
  );

  test('pagination, full filtered CSV and snapshot append boundary', () async {
    writer.execute('BEGIN');
    for (var i = 1; i <= 250; i++) {
      add(i, '2026-10-31 12:00:00', task: '引号"，逗号,\n换行', tokens: i);
    }
    writer.execute('COMMIT');
    final s = await repository.snapshot(path, query());
    add(251, '2026-10-31 12:00:00');
    final page = await repository.details(
      path,
      s,
      page: 2,
      sort: UsageSort.tokens,
      ascending: true,
    );
    expect(page.total, 250);
    expect(page.rows.length, 50);
    expect(page.rows.first['total_tokens'], 201);
    final output = '${temp.path}/detail.csv';
    expect(await repository.export(path, s, output), 250);
    final bytes = File(output).readAsBytesSync();
    expect(bytes.take(3), [239, 187, 191]);
    final text = utf8.decode(bytes.skip(3).toList());
    expect(text, contains('"引号""，逗号,\n换行"'));
    expect(text, contains('250,2026-10-31'));
    expect(text, isNot(contains('251,2026-10-31')));
    expect(
      await repository.export(
        path,
        s,
        '${temp.path}/summary.csv',
        summary: true,
      ),
      1 +
          s.trend.length +
          s.groups.values.fold<int>(0, (n, groups) => n + groups.length),
    );
    await expectLater(
      repository.export(path, s, path),
      throwsA(isA<UsageFailure>()),
    );
  });

  test('missing/incompatible/empty database are distinct', () async {
    await expectLater(
      repository.snapshot('$path-missing', query()),
      throwsA(isA<UsageFailure>().having((e) => e.code, 'code', 'missing')),
    );
    final s = await repository.snapshot(path, query());
    expect(s.metrics.calls, 0);
    expect(s.trend.length, 48);
    writer.execute('ALTER TABLE llm_usage RENAME COLUMN cost TO old_cost');
    await expectLater(
      repository.snapshot(path, query()),
      throwsA(isA<UsageFailure>().having((e) => e.code, 'code', 'schema')),
    );
  });

  test(
    '100k records stay in background and charts/details/export reconcile',
    () async {
      writer.execute('CREATE INDEX timestamp_idx ON llm_usage(timestamp)');
      writer.execute(
        "WITH RECURSIVE numbers(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM numbers WHERE n<100000) "
        "INSERT INTO llm_usage SELECT n,'m','a','p',CASE WHEN n%2=0 THEN 'g1' ELSE 'g2' END,"
        "'reply','chat',1.25,'2026-10-31 12:00:00',20,9,29,1,10,0,0.001 FROM numbers",
      );
      var heartbeat = false;
      final future = repository.snapshot(path, query());
      await Future<void>.delayed(Duration.zero, () => heartbeat = true);
      final s = await future;
      expect(heartbeat, true);
      expect(s.metrics.calls, 100000);
      expect(s.metrics.tokens, 2900000);
      expect(s.metrics.cost, closeTo(100, 1e-7));
      expect(s.groups['session']!.map((g) => g.metrics.calls), [50000, 50000]);
      expect((await repository.details(path, s, page: 999)).rows.length, 100);
      expect(
        await repository.export(path, s, '${temp.path}/large.csv'),
        100000,
      );
    },
  );

  test('exclusive writer yields a distinct busy timeout', () async {
    writer.execute('PRAGMA journal_mode=DELETE');
    writer.execute('BEGIN EXCLUSIVE');
    try {
      await expectLater(
        repository.snapshot(path, query()),
        throwsA(isA<UsageFailure>().having((e) => e.code, 'code', 'timeout')),
      );
    } finally {
      writer.execute('ROLLBACK');
    }
  });

  test(
    'empty chat metadata never multiplies unattributed records; raw IDs stay intact',
    () async {
      writer.execute(
        "INSERT INTO chat_sessions VALUES ('','','','','',''),('','','','','','')",
      );
      add(1, '2026-10-31 12:00:00', session: '');
      add(2, '2026-10-31 12:00:00', session: ' spaced ');
      add(3, '2026-10-31 12:00:00', session: 'spaced');
      final s = await repository.snapshot(path, query());
      expect(s.metrics.calls, 3);
      expect(s.groups['session']!.map((g) => g.key).toSet(), {
        '',
        ' spaced ',
        'spaced',
      });
    },
  );
}
