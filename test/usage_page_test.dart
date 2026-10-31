import 'package:bot_console/core/settings.dart';
import 'package:bot_console/ui/theme.dart';
import 'package:bot_console/ui/usage_page.dart';
import 'package:bot_console/usage/usage_controller.dart';
import 'package:bot_console/usage/usage_models.dart';
import 'package:bot_console/usage/usage_repository.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

UsageSnapshot fixture(UsageQuery q) {
  const m = UsageMetrics(
    tokens: 220,
    input: 200,
    output: 20,
    calls: 2,
    cost: 0.12,
    hit: 100,
    miss: 100,
    seconds: 4,
    timedCalls: 2,
  );
  final groups = {
    for (final key in ['session', 'model', 'task', 'provider', 'request'])
      key: [
        UsageGroup(
          key == 'session' ? 'g1' : key,
          key == 'session' ? '群 A · 群 1' : '测试 $key',
          m,
          type: 'group',
        ),
      ],
  };
  return UsageSnapshot(
    query: q,
    start: q.start!,
    metrics: m,
    previous: const UsageMetrics(),
    trend: [
      UsagePoint(q.start!, m),
      UsagePoint(q.start!.add(const Duration(hours: 1)), const UsageMetrics()),
    ],
    groups: groups,
    options: groups,
    heatmap: List.generate(168, (i) => i == 0 ? 220 : 0),
    highWater: 2,
    journalMode: 'wal',
    loadedAt: usageNow(),
  );
}

class FixtureRepository extends UsageRepository {
  @override
  Future<UsageSnapshot> snapshot(String path, UsageQuery query) async =>
      fixture(query);
}

void main() {
  test(
    'database override survives settings round trip and keeps unknown keys',
    () {
      final original = AppSettings.defaults();
      expect(original.usageDatabaseResolved, contains('MaiBot.db'));
      original.usageDatabasePath = r'D:\custom\usage.db';
      original.unknownKeys['futureKey'] = 42;
      final copy = original.copy();
      expect(copy.usageDatabaseResolved, r'D:\custom\usage.db');
      expect(copy.unknownKeys['futureKey'], 42);
      expect(copy.unknownKeys.containsKey('usageDatabasePath'), false);
      copy.usageDatabasePath = '';
      expect(copy.copy().usageDatabaseResolved, contains('MaiBot.db'));
    },
  );

  for (final width in [1100.0, 700.0]) {
    testWidgets(
      'analysis filters, charts, heatmap and details render at $width',
      (tester) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final c = UsageController('fixture', repository: FixtureRepository());
        c.snapshot = fixture(c.query);
        c.details = const UsagePage([], 2, 0);
        await tester.pumpWidget(
          MaterialApp(
            theme: buildTheme(),
            home: Scaffold(body: UsagePageView(controller: c)),
          ),
        );
        expect(find.text('用量分析'), findsOneWidget);
        expect(find.text('近 24 小时'), findsOneWidget);
        expect(tester.takeException(), null);
        await tester.scrollUntilVisible(
          find.text('星期 × 小时消耗热力图（北京时间）'),
          500,
          scrollable: find
              .descendant(
                of: find.byKey(const ValueKey('usage-scroll')),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.pump();
        expect(tester.takeException(), null);
        await tester.scrollUntilVisible(
          find.text('调用明细 · 每页 100 条'),
          300,
          scrollable: find
              .descendant(
                of: find.byKey(const ValueKey('usage-scroll')),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.pump();
        expect(find.text('共 2 条 · 第 1 / 1 页'), findsOneWidget);
        expect(tester.takeException(), null);
        await tester.pumpWidget(const SizedBox());
        c.dispose();
      },
    );
  }
}
