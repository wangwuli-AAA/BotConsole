import 'package:bot_console/core/settings.dart';
import 'package:bot_console/services/health_monitor.dart';
import 'package:bot_console/services/service_controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('健康探测能在合理时间内完成', () async {
    final settings = AppSettings.defaults();
    final controller = ServiceController(settings: settings);
    final monitor = HealthMonitor(settings: settings, controller: controller);
    await monitor.refresh().timeout(const Duration(seconds: 15));
    final snap = monitor.snapshot;
    // ignore: avoid_print
    print('updatedAt=${snap.updatedAt} error=${snap.error} ports=${snap.ports} '
        'http=${snap.onebotHttpListening} ws=${snap.onebotWsListening} '
        'adapter=${snap.adapterConnected} snowui=${snap.snowlumaWebuiOk} maiui=${snap.maibotWebuiOk}');
    expect(snap.updatedAt, isNotNull);
    monitor.dispose();
    controller.dispose();
  });
}
