import 'dart:io';

import 'package:bot_console/app.dart';
import 'package:bot_console/core/settings.dart';
import 'package:bot_console/services/service_controller.dart';
import 'package:bot_console/ui/logs_page.dart';
import 'package:bot_console/ui/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class TestLogController extends ServiceController {
  TestLogController(this.file)
    : super(settings: AppSettings.defaults(), pollInterval: Duration.zero);
  final File file;

  @override
  String outLogPath(ServiceKind kind) => file.path;

  @override
  String errLogPath(ServiceKind kind) => file.path;
}

void main() {
  testWidgets('logs build visible rows and stop reading while in tray', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1360, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final state = AppState();
    state.settings = AppSettings.defaults();
    final temp = Directory.systemTemp.createTempSync('botconsole-log-ui-');
    final file = File('${temp.path}/service.log');
    state.controller = TestLogController(file);
    addTearDown(() {
      state.controller.dispose();
      temp.deleteSync(recursive: true);
    });
    file.writeAsStringSync(List.generate(400, (i) => 'log-row-$i').join('\n'));
    Widget page(bool active) => AppScope(
      state: state,
      child: MaterialApp(
        theme: buildTheme(),
        home: Scaffold(body: LogsPage(active: active)),
      ),
    );
    await tester.pumpWidget(page(true));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('log-row-').evaluate().length, lessThan(100));
    await tester.pumpWidget(page(false));
    file.writeAsStringSync('new-content-after-hide\n');
    await tester.pump(const Duration(seconds: 5));
    expect(find.text('new-content-after-hide'), findsNothing);
    await tester.pumpWidget(page(true));
    await tester.pump();
    expect(find.text('new-content-after-hide'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
