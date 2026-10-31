import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../core/app_paths.dart';
import '../core/env_builder.dart';
import '../core/log_tailer.dart';
import '../core/netstat.dart';
import '../core/port_probe.dart';
import '../core/proc_launcher.dart';
import '../core/settings.dart';

/// 受管理的两个服务。
enum ServiceKind {
  snowluma('SnowLuma'),
  maibot('MaiBot');

  const ServiceKind(this.label);

  final String label;
}

/// 服务状态。
enum ServiceState { stopped, starting, running, stopping, failed }

extension ServiceStateX on ServiceState {
  bool get isBusy => this == ServiceState.starting || this == ServiceState.stopping;

  bool get isActive => this == ServiceState.running || this == ServiceState.starting;

  String get label => switch (this) {
        ServiceState.stopped => '已停止',
        ServiceState.starting => '启动中',
        ServiceState.running => '运行中',
        ServiceState.stopping => '停止中',
        ServiceState.failed => '失败',
      };
}

/// 单个服务的当前状态快照。
@immutable
class ServiceStatus {
  const ServiceStatus({
    required this.state,
    this.pid,
    this.exitCode,
    this.error,
    this.note,
    this.startedAt,
  });

  final ServiceState state;
  final int? pid;
  final int? exitCode;
  final String? error;

  /// 非错误提示（例如“等待 QQ 登录”）。
  final String? note;
  final DateTime? startedAt;

  ServiceStatus copyWith({
    ServiceState? state,
    int? pid,
    int? exitCode,
    String? error,
    String? note,
    DateTime? startedAt,
    bool clearError = false,
    bool clearNote = false,
  }) {
    return ServiceStatus(
      state: state ?? this.state,
      pid: pid ?? this.pid,
      exitCode: exitCode ?? this.exitCode,
      error: clearError ? null : (error ?? this.error),
      note: clearNote ? null : (note ?? this.note),
      startedAt: startedAt ?? this.startedAt,
    );
  }
}

/// 启停编排与状态机。
///
/// 状态流：`stopped → starting → running → stopping → stopped`；
/// 失败进入 `failed` 并带中文原因。轮询（默认 2s）负责发现“进程自己退了”。
class ServiceController extends ChangeNotifier {
  ServiceController({
    required this.settings,
    Launcher? launcher,
    this.pollInterval = const Duration(seconds: 2),
  }) : _launcher = launcher ?? const FfiLauncher() {
    for (final kind in ServiceKind.values) {
      _statuses[kind] = const ServiceStatus(state: ServiceState.stopped);
    }
    if (pollInterval > Duration.zero) {
      _pollTimer = Timer.periodic(pollInterval, (_) => _tick());
    }
  }

  AppSettings settings;
  final Launcher _launcher;
  final Duration pollInterval;

  final Map<ServiceKind, ServiceStatus> _statuses = {};
  final Map<ServiceKind, LaunchHandle> _handles = {};
  Timer? _pollTimer;
  bool _disposed = false;
  bool _shuttingDown = false;

  static const Duration snowLumaReadyTimeout = Duration(seconds: 120);
  static const Duration maiBotReadyTimeout = Duration(seconds: 180);
  static const Duration stopGrace = Duration(seconds: 5);

  ServiceStatus statusOf(ServiceKind kind) =>
      _statuses[kind] ?? const ServiceStatus(state: ServiceState.stopped);

  bool get anyBusy => ServiceKind.values.any((k) => statusOf(k).state.isBusy);

  bool get allRunning => ServiceKind.values.every((k) => statusOf(k).state == ServiceState.running);

  bool get anyRunning => ServiceKind.values.any((k) => statusOf(k).state.isActive);

  int? get snowLumaPid => _handles[ServiceKind.snowluma]?.pid;

  int? get maiBotPid => _handles[ServiceKind.maibot]?.pid;

  /// 端口配置。
  List<int> portsOf(ServiceKind kind) => switch (kind) {
        ServiceKind.snowluma => [settings.hosts.snowlumaHttp, settings.hosts.snowlumaWs],
        ServiceKind.maibot => [settings.hosts.maibotWebui],
      };

  /// 当前设置的“所有”端口（概览页展示用）。
  List<int> get allPorts => [
        settings.hosts.snowlumaHttp,
        settings.hosts.snowlumaWs,
        settings.hosts.snowlumaWebui,
        settings.hosts.maibotWs,
        settings.hosts.maibotWebui,
      ];

  String outLogPath(ServiceKind kind) =>
      AppPaths.logFile('${kind == ServiceKind.snowluma ? 'snowluma' : 'maibot'}.out.log');

  String errLogPath(ServiceKind kind) =>
      AppPaths.logFile('${kind == ServiceKind.snowluma ? 'snowluma' : 'maibot'}.err.log');

  // -------------------------------------------------------------------------
  // 启动 / 停止
  // -------------------------------------------------------------------------

  Future<void> start(ServiceKind kind) async {
    if (_disposed || _shuttingDown) return;
    final current = statusOf(kind);
    if (current.state.isBusy || _handles.containsKey(kind)) return;

    final errors = kind == ServiceKind.snowluma
        ? settings.validateSnowLuma()
        : settings.validateMaiBot();
    if (errors.isNotEmpty) {
      _set(kind, ServiceStatus(
        state: ServiceState.failed,
        error: errors.first,
        startedAt: DateTime.now(),
      ));
      return;
    }

    final outPath = outLogPath(kind);
    final errPath = errLogPath(kind);
    LogTailer.rotateIfLarge(outPath);
    LogTailer.rotateIfLarge(errPath);

    _set(kind, ServiceStatus(state: ServiceState.starting, startedAt: DateTime.now()));

    LaunchHandle? handle;
    try {
      final spec = _buildSpec(kind, outPath, errPath);
      handle = _launcher.start(spec);
      _handles[kind] = handle;
      _set(kind, ServiceStatus(
        state: ServiceState.starting,
        pid: handle.pid,
        startedAt: DateTime.now(),
        note: '进程已启动，等待端口就绪…',
      ));

      final ports = portsOf(kind);
      final timeout = kind == ServiceKind.snowluma ? snowLumaReadyTimeout : maiBotReadyTimeout;
      final ready = await _waitForPorts(handle, ports, timeout);

      // 停止/退出已接管句柄时，不让旧的启动任务覆盖状态或继续全启流程。
      if (_disposed || _shuttingDown || _handles[kind] != handle ||
          statusOf(kind).state != ServiceState.starting) {
        return;
      }

      if (!handle.isAlive) {
        final code = handle.exitCode;
        _handles.remove(kind);
        handle.close();
        _set(kind, ServiceStatus(
          state: ServiceState.failed,
          exitCode: code,
          error: '进程启动后立即退出（退出码 $code），请查看日志',
          startedAt: DateTime.now(),
        ));
        return;
      }

      _set(kind, ServiceStatus(
        state: ServiceState.running,
        pid: handle.pid,
        startedAt: DateTime.now(),
        note: ready
            ? null
            : (kind == ServiceKind.snowluma
                ? '进程运行中，但端口 ${ports.join('/')} 未在 ${timeout.inSeconds}s 内就绪（通常是 QQ 还没登录）'
                : '进程运行中，但端口 ${ports.join('/')} 未在 ${timeout.inSeconds}s 内就绪'),
      ));
    } on ProcessLaunchException catch (e) {
      _handles.remove(kind);
      handle?.close();
      _set(kind, ServiceStatus(
        state: ServiceState.failed,
        error: e.toString(),
        startedAt: DateTime.now(),
      ));
    } on Object catch (e) {
      _handles.remove(kind);
      handle?.close();
      _set(kind, ServiceStatus(
        state: ServiceState.failed,
        error: '启动失败：$e',
        startedAt: DateTime.now(),
      ));
    }
  }

  Future<void> stop(ServiceKind kind) async {
    final handle = _handles[kind];
    if (handle == null && !statusOf(kind).state.isActive) {
      _set(kind, const ServiceStatus(state: ServiceState.stopped));
      return;
    }
    final pid = handle?.pid ?? statusOf(kind).pid;
    _set(kind, ServiceStatus(
      state: ServiceState.stopping,
      pid: pid,
      startedAt: statusOf(kind).startedAt,
    ));

    if (handle != null) {
      await handle.terminate(grace: stopGrace);
      _handles.remove(kind);
    }

    final released = await _waitForPortsClosed(portsOf(kind), const Duration(seconds: 6));
    var note = '已停止';
    if (!released) {
      // 兜底：按端口找 PID 强杀
      final owners = await whoListensOnPorts(portsOf(kind));
      for (final ownerPid in owners.values.toSet()) {
        await terminateProcessById(ownerPid);
      }
      final releasedAfterKill =
          await _waitForPortsClosed(portsOf(kind), const Duration(seconds: 4));
      note = releasedAfterKill ? '已停止（强制结束残留进程）' : '已结束进程，但端口仍被占用，请手动检查';
    }
    _set(kind, ServiceStatus(state: ServiceState.stopped, note: note));
  }

  /// 一键启动：先 SnowLuma（MaiBot 的适配器要连它的 WS），再 MaiBot。
  Future<void> startAll() async {
    await start(ServiceKind.snowluma);
    if (_disposed || _shuttingDown ||
        statusOf(ServiceKind.snowluma).state != ServiceState.running) {
      return;
    }
    await start(ServiceKind.maibot);
  }

  /// 一键停止：先 MaiBot，再 SnowLuma。
  Future<void> stopAll() async {
    await stop(ServiceKind.maibot);
    await stop(ServiceKind.snowluma);
  }

  Future<void> restartAll() async {
    await stopAll();
    await startAll();
  }

  /// 应用退出时调用：结束所有子进程并释放句柄。
  Future<void> shutdown() async {
    _shuttingDown = true;
    _pollTimer?.cancel();
    _pollTimer = null;
    for (final kind in ServiceKind.values) {
      final handle = _handles.remove(kind);
      if (handle == null) continue;
      try {
        await handle.terminate(grace: const Duration(seconds: 2));
      } on Object {
        handle.close();
      }
    }
    for (final kind in ServiceKind.values) {
      _statuses[kind] = const ServiceStatus(state: ServiceState.stopped);
    }
  }

  // -------------------------------------------------------------------------
  // 探测
  // -------------------------------------------------------------------------

  Future<Map<int, bool>> probeAllPorts() => probePorts(settings.hosts.host, allPorts);

  Future<Map<int, int>> occupiedPorts() => whoListensOnPorts(allPorts);

  /// 端口被“非本应用”的进程占用时，返回提示文本。
  Future<String?> externalOccupancyHint() async {
    if (anyRunning) return null;
    final owners = await whoListensOnPorts(allPorts);
    if (owners.isEmpty) return null;
    final parts = owners.entries.map((e) => '${e.key}=PID ${e.value}').join('、');
    return '检测到端口已被占用：$parts（可能由 start_mai.bat 启动）。可直接点“接管并重启”。';
  }

  /// 结束占用本应用端口的进程（接管外部启动的服务）。
  Future<void> killExternalOccupants() async {
    final owners = await whoListensOnPorts(allPorts);
    for (final pid in owners.values.toSet()) {
      await terminateProcessById(pid);
    }
  }

  // -------------------------------------------------------------------------
  // 内部
  // -------------------------------------------------------------------------

  LaunchSpec _buildSpec(ServiceKind kind, String outPath, String errPath) {
    final useProxy = settings.proxy.autoDetect
        ? _proxyLikelyAvailable
        : settings.proxy.url.trim().isNotEmpty;
    final env = buildEnvironment(
      base: Platform.environment,
      useProxy: useProxy,
      proxyUrl: settings.proxy.url,
      pythonUtf8: kind == ServiceKind.maibot,
      extraEnvText: settings.extraEnv.join('\n'),
    );
    return switch (kind) {
      ServiceKind.snowluma => LaunchSpec(
          name: kind.label,
          executable: settings.snowluma.nodeExe,
          arguments: [settings.snowluma.entry],
          workingDirectory: settings.snowluma.dir,
          environment: env,
          stdoutPath: outPath,
          stderrPath: errPath,
        ),
      ServiceKind.maibot => LaunchSpec(
          name: kind.label,
          executable: settings.maibot.pythonExeResolved,
          arguments: [settings.maibot.entry],
          workingDirectory: settings.maibot.dir,
          environment: env,
          stdoutPath: outPath,
          stderrPath: errPath,
        ),
    };
  }

  bool _proxyLikelyAvailable = true;

  /// 代理探测在启动前异步刷新（避免启动流程里额外阻塞）。
  Future<void> refreshProxyAvailability() async {
    final url = settings.proxy.url.trim();
    if (!settings.proxy.autoDetect || url.isEmpty) {
      _proxyLikelyAvailable = false;
      return;
    }
    try {
      final uri = Uri.parse(url);
      final host = uri.host.isEmpty ? '127.0.0.1' : uri.host;
      final port = uri.hasPort ? uri.port : 80;
      _proxyLikelyAvailable = await isTcpOpen(host, port, timeout: const Duration(milliseconds: 300));
    } on Object {
      _proxyLikelyAvailable = false;
    }
  }

  Future<bool> _waitForPorts(LaunchHandle handle, List<int> ports, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (!handle.isAlive) return false;
      final probe = await probePorts(settings.hosts.host, ports);
      if (probe.values.every((open) => open)) return true;
      await Future<void>.delayed(const Duration(milliseconds: 700));
    }
    return false;
  }

  Future<bool> _waitForPortsClosed(List<int> ports, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final probe = await probePorts(settings.hosts.host, ports);
      if (probe.values.every((open) => !open)) return true;
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    return false;
  }

  void _tick() {
    if (_disposed) return;
    var changed = false;
    for (final kind in ServiceKind.values) {
      final handle = _handles[kind];
      if (handle == null) continue;
      final status = statusOf(kind);
      if (status.state != ServiceState.running) continue;
      if (!handle.isAlive) {
        final code = handle.exitCode;
        _handles.remove(kind);
        handle.close();
        _statuses[kind] = ServiceStatus(
          state: ServiceState.failed,
          exitCode: code,
          error: '进程已退出（退出码 $code），详情见日志',
          startedAt: status.startedAt,
        );
        changed = true;
      }
    }
    if (changed) _notify();
  }

  void _set(ServiceKind kind, ServiceStatus status) {
    _statuses[kind] = status;
    _notify();
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _pollTimer?.cancel();
    _pollTimer = null;
    for (final handle in _handles.values) {
      handle.close();
    }
    _handles.clear();
    super.dispose();
  }
}
