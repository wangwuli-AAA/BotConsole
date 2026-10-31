import 'dart:io';

import 'package:bot_console/core/proc_launcher.dart';
import 'package:bot_console/core/settings.dart';
import 'package:bot_console/services/health_monitor.dart';
import 'package:bot_console/services/service_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

class _Handle implements LaunchHandle {
  bool alive = true;

  @override
  String get name => 'test';
  @override
  int get pid => 123;
  @override
  bool get isAlive => alive;
  @override
  int? get exitCode => alive ? null : 1;
  @override
  void close() => alive = false;
  @override
  Future<void> terminate({Duration grace = Duration.zero}) async => close();
}

class _Launcher implements Launcher {
  int starts = 0;

  @override
  LaunchHandle start(LaunchSpec spec) {
    starts++;
    return _Handle();
  }
}

void main() {
  test('启动中退出不会覆盖已停止状态或启动第二个服务', () async {
    final dir = Directory.systemTemp.createTempSync('bc_shutdown_');
    final launcher = _Launcher();
    final settings = AppSettings.defaults();
    settings.snowluma
      ..dir = dir.path
      ..nodeExe = Platform.resolvedExecutable
      ..entry = 'index.mjs';
    settings.maibot
      ..dir = dir.path
      ..pythonExe = Platform.resolvedExecutable
      ..entry = 'bot.py';
    File(p.join(dir.path, 'index.mjs')).writeAsStringSync('');
    File(p.join(dir.path, 'bot.py')).writeAsStringSync('');
    final controller = ServiceController(
      settings: settings,
      launcher: launcher,
      pollInterval: Duration.zero,
    );
    try {
      final starting = controller.startAll();
      expect(launcher.starts, 1);
      await controller.shutdown();
      await starting.timeout(const Duration(seconds: 5));
      expect(launcher.starts, 1);
      for (final kind in ServiceKind.values) {
        expect(controller.statusOf(kind).state, ServiceState.stopped);
      }
    } finally {
      controller.dispose();
      dir.deleteSync(recursive: true);
    }
  });

  test('健康探测尚未完成时释放监视器，不再通知已释放的界面', () async {
    final controller = ServiceController(
      settings: AppSettings.defaults(),
      pollInterval: Duration.zero,
    );
    final monitor = HealthMonitor(
      settings: controller.settings,
      controller: controller,
    );
    var notifications = 0;
    monitor.addListener(() => notifications++);
    final checking = monitor.refresh();
    monitor.dispose();
    try {
      await expectLater(checking, completes);
      expect(notifications, 0);
    } finally {
      controller.dispose();
    }
  });
}
