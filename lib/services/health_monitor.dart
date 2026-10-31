import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/app_paths.dart';
import '../core/log_tailer.dart';
import '../core/port_probe.dart';
import '../core/settings.dart';
import 'service_controller.dart';

/// 一次健康检查的结果。
@immutable
class HealthSnapshot {
  const HealthSnapshot({
    this.ports = const {},
    this.snowlumaWebuiOk = false,
    this.maibotWebuiOk = false,
    this.qqUin,
    this.onebotHttpListening = false,
    this.onebotWsListening = false,
    this.warmupLoaded,
    this.warmupTotal,
    this.adapterConnected = false,
    this.adapterEndpoint,
    this.updatedAt,
    this.error,
  });

  /// 端口 → 是否可连。
  final Map<int, bool> ports;
  final bool snowlumaWebuiOk;
  final bool maibotWebuiOk;

  /// 从 SnowLuma 日志解析出的已登录 QQ 号。
  final String? qqUin;
  final bool onebotHttpListening;
  final bool onebotWsListening;

  /// 群成员预热进度（`groups=8/8`）。
  final int? warmupLoaded;
  final int? warmupTotal;

  /// MaiBot 日志中的“适配器已连接”。
  final bool adapterConnected;
  final String? adapterEndpoint;

  final DateTime? updatedAt;

  /// 最近一次探测的异常信息（探测失败时非空，用于界面排查）。
  final String? error;

  static const HealthSnapshot empty = HealthSnapshot();

  HealthSnapshot copyWith({
    Map<int, bool>? ports,
    bool? snowlumaWebuiOk,
    bool? maibotWebuiOk,
    String? qqUin,
    bool? onebotHttpListening,
    bool? onebotWsListening,
    int? warmupLoaded,
    int? warmupTotal,
    bool? adapterConnected,
    String? adapterEndpoint,
    DateTime? updatedAt,
    String? error,
    bool clearError = false,
  }) {
    return HealthSnapshot(
      ports: ports ?? this.ports,
      snowlumaWebuiOk: snowlumaWebuiOk ?? this.snowlumaWebuiOk,
      maibotWebuiOk: maibotWebuiOk ?? this.maibotWebuiOk,
      qqUin: qqUin ?? this.qqUin,
      onebotHttpListening: onebotHttpListening ?? this.onebotHttpListening,
      onebotWsListening: onebotWsListening ?? this.onebotWsListening,
      warmupLoaded: warmupLoaded ?? this.warmupLoaded,
      warmupTotal: warmupTotal ?? this.warmupTotal,
      adapterConnected: adapterConnected ?? this.adapterConnected,
      adapterEndpoint: adapterEndpoint ?? this.adapterEndpoint,
      updatedAt: updatedAt ?? this.updatedAt,
      error: clearError ? null : (error ?? this.error),
    );
  }

  bool portOpen(int port) => ports[port] ?? false;
}

/// 周期性健康探测：端口、WebUI、日志关键行。
class HealthMonitor extends ChangeNotifier {
  HealthMonitor({
    required this.settings,
    required this.controller,
    this.interval = const Duration(seconds: 2),
    String Function(String name)? logPathResolver,
  }) : _logPath = logPathResolver ?? AppPaths.logFile {
    _snowOut = LogTailer(_logPath('snowluma.out.log'));
    _snowErr = LogTailer(_logPath('snowluma.err.log'));
    _maiOut = LogTailer(_logPath('maibot.out.log'));
    _maiErr = LogTailer(_logPath('maibot.err.log'));
  }

  AppSettings settings;
  final ServiceController controller;
  final Duration interval;
  final String Function(String name) _logPath;

  late final LogTailer _snowOut;
  late final LogTailer _snowErr;
  late final LogTailer _maiOut;
  late final LogTailer _maiErr;

  HealthSnapshot _snapshot = HealthSnapshot.empty;
  HealthSnapshot get snapshot => _snapshot;

  Timer? _timer;
  bool _checking = false;
  bool _disposed = false;

  /// 设置变化后同步（端口/主机可能变了）。
  void updateSettings(AppSettings next) {
    settings = next;
    unawaited(refresh());
  }

  void start() {
    _timer?.cancel();
    for (final tailer in [_snowOut, _snowErr, _maiOut, _maiErr]) {
      tailer.seekToEnd();
    }
    _timer = Timer.periodic(interval, (_) => refresh());
    unawaited(refresh());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> refresh() async {
    if (_checking || _disposed) return;
    _checking = true;
    try {
      final host = settings.hosts.host;
      final ports = await probePorts(host, controller.allPorts);

      // 面板探测并发执行；连不通的端口直接跳过，避免每次白等超时。
      final snowUiPort = settings.hosts.snowlumaWebui;
      final maiUiPort = settings.hosts.maibotWebui;
      final results = await Future.wait<int?>([
        if (ports[snowUiPort] ?? false)
          httpStatus(Uri.parse(settings.hosts.snowlumaWebuiUrl))
        else
          Future<int?>.value(),
        if (ports[maiUiPort] ?? false)
          httpStatus(Uri.parse(settings.hosts.maibotWebuiUrl))
        else
          Future<int?>.value(),
      ]);
      final snowWebui = results[0];
      final maiWebui = results[1];
      if (_disposed) return;

      var next = _snapshot.copyWith(
        ports: ports,
        snowlumaWebuiOk: snowWebui != null && snowWebui < 500,
        maibotWebuiOk: maiWebui != null && maiWebui < 500,
        updatedAt: DateTime.now(),
        clearError: true,
      );

      for (final line in _snowOut.readNew()) {
        next = _applySnowLumaLine(next, line);
      }
      for (final line in _snowErr.readNew()) {
        next = _applySnowLumaLine(next, line);
      }
      for (final line in _maiOut.readNew()) {
        next = _applyMaiBotLine(next, line);
      }
      for (final line in _maiErr.readNew()) {
        next = _applyMaiBotLine(next, line);
      }

      // 日志只覆盖本应用启动的服务；外部引入的实例用端口状态兜底。
      final snowHttp = ports[settings.hosts.snowlumaHttp] ?? false;
      final snowWs = ports[settings.hosts.snowlumaWs] ?? false;
      final maiWs = ports[settings.hosts.maibotWs] ?? false;
      if (!next.onebotHttpListening && snowHttp) {
        next = next.copyWith(onebotHttpListening: true);
      }
      if (!next.onebotWsListening && snowWs) {
        next = next.copyWith(onebotWsListening: true);
      }
      if (!next.adapterConnected && snowWs && maiWs) {
        next = next.copyWith(
          adapterConnected: true,
          adapterEndpoint: 'ws://$host:${settings.hosts.snowlumaWs}',
        );
      }

      _snapshot = next;
      notifyListeners();
    } on Object catch (e) {
      if (_disposed) return;
      _snapshot = _snapshot.copyWith(
        updatedAt: DateTime.now(),
        error: e.toString(),
      );
      notifyListeners();
    } finally {
      _checking = false;
    }
  }

  static final RegExp _loginPattern = RegExp(
    r'login detected: PID=(\d+) UIN=(\d+)',
  );
  static final RegExp _warmupPattern = RegExp(
    r'member warmup completed:.*groups=(\d+)/(\d+)',
  );
  static final RegExp _onebotHttpPattern = RegExp(
    r'\[OneBot\.HTTP\].*listening',
  );
  static final RegExp _onebotWsPattern = RegExp(
    r'\[OneBot\.WS-Server\].*listening',
  );
  static final RegExp _adapterPattern = RegExp(r'适配器已连接\s*(ws://\S+)');

  HealthSnapshot _applySnowLumaLine(HealthSnapshot snapshot, String line) {
    final login = _loginPattern.firstMatch(line);
    if (login != null) {
      return snapshot.copyWith(qqUin: login.group(2));
    }
    if (_onebotHttpPattern.hasMatch(line)) {
      return snapshot.copyWith(onebotHttpListening: true);
    }
    if (_onebotWsPattern.hasMatch(line)) {
      return snapshot.copyWith(onebotWsListening: true);
    }
    final warmup = _warmupPattern.firstMatch(line);
    if (warmup != null) {
      return snapshot.copyWith(
        warmupLoaded: int.tryParse(warmup.group(1)!),
        warmupTotal: int.tryParse(warmup.group(2)!),
      );
    }
    return snapshot;
  }

  HealthSnapshot _applyMaiBotLine(HealthSnapshot snapshot, String line) {
    final adapter = _adapterPattern.firstMatch(line);
    if (adapter != null) {
      return snapshot.copyWith(
        adapterConnected: true,
        adapterEndpoint: adapter.group(1),
      );
    }
    return snapshot;
  }

  @override
  void dispose() {
    _disposed = true;
    stop();
    super.dispose();
  }
}
