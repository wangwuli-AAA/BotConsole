import 'dart:async';

import 'package:bot_console/usage/usage_controller.dart';
import 'package:bot_console/usage/usage_models.dart';
import 'package:bot_console/usage/usage_repository.dart';
import 'package:flutter_test/flutter_test.dart';

class PendingRepository extends UsageRepository {
  final requests = <(String, UsageQuery, Completer<UsageSnapshot>)>[];
  int detailRequests = 0;
  @override
  Future<UsageSnapshot> snapshot(String path, UsageQuery query) {
    final result = Completer<UsageSnapshot>();
    requests.add((path, query, result));
    return result.future;
  }

  @override
  Future<UsagePage> details(
    String path,
    UsageSnapshot snapshot, {
    int page = 0,
    UsageSort sort = UsageSort.timestamp,
    bool ascending = false,
  }) async {
    detailRequests++;
    return UsagePage([], 0, page);
  }
}

UsageSnapshot result(UsageQuery q, int tokens) => UsageSnapshot(
  query: q,
  start: q.start!,
  metrics: UsageMetrics(tokens: tokens),
  previous: const UsageMetrics(),
  trend: [],
  groups: const {},
  options: const {},
  heatmap: List.filled(168, 0),
  highWater: 1,
  journalMode: 'wal',
  loadedAt: usageNow(),
);

void main() {
  testWidgets(
    'new filters win; failure preserves prior data; source change discards it',
    (tester) async {
      final repo = PendingRepository();
      final c = UsageController('one', repository: repo, includeDetails: false);
      c.setVisible(true);
      expect(repo.requests.length, 1);
      c.update(c.query.filter('task', 'new'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(repo.requests.length, 2);
      repo.requests[1].$3.complete(result(repo.requests[1].$2, 200));
      await tester.pump();
      repo.requests[0].$3.complete(result(repo.requests[0].$2, 100));
      await tester.pump();
      expect(c.snapshot!.metrics.tokens, 200);
      final refresh = c.refresh();
      repo.requests.last.$3.completeError(const UsageFailure('timeout', '繁忙'));
      await refresh;
      expect(c.snapshot!.metrics.tokens, 200);
      expect(c.error!.code, 'timeout');
      expect(c.loading, false);
      c.setPath('two');
      expect(c.snapshot, null);
      expect(repo.requests.last.$1, 'two');
      c.dispose();
      repo.requests.last.$3.complete(result(repo.requests.last.$2, 300));
      await tester.pump();
    },
  );

  testWidgets(
    '60 second refresh stops while hidden and stale results start no details',
    (tester) async {
      final repo = PendingRepository();
      final c = UsageController('one', repository: repo);
      c.setVisible(true);
      repo.requests[0].$3.complete(result(repo.requests[0].$2, 100));
      await tester.pump();
      expect(repo.detailRequests, 1);
      await tester.pump(const Duration(seconds: 60));
      expect(repo.requests.length, 2);
      c.setVisible(false);
      repo.requests[1].$3.complete(result(repo.requests[1].$2, 200));
      await tester.pump(const Duration(seconds: 180));
      expect(repo.requests.length, 2);
      expect(repo.detailRequests, 1);
      expect(c.snapshot!.metrics.tokens, 100);
      c.setVisible(true);
      // A pending filter is retried on restore.
      expect(repo.requests.length, 3);
      repo.requests.last.$3.complete(result(repo.requests.last.$2, 300));
      await tester.pump();
      expect(c.snapshot!.metrics.tokens, 300);
      c.dispose();
    },
  );

  testWidgets('restore reloads a filter that was pending when hidden', (
    tester,
  ) async {
    final repo = PendingRepository();
    final c = UsageController('one', repository: repo, includeDetails: false);
    c.setVisible(true);
    repo.requests[0].$3.complete(result(repo.requests[0].$2, 100));
    await tester.pump();
    c.update(c.query.filter('task', 'pending'));
    c.setVisible(false);
    await tester.pump(const Duration(seconds: 1));
    expect(repo.requests.length, 1);
    c.setVisible(true);
    expect(repo.requests.length, 2);
    expect(repo.requests.last.$2.task, 'pending');
    c.dispose();
    repo.requests.last.$3.complete(result(repo.requests.last.$2, 200));
    await tester.pump();
  });
}
