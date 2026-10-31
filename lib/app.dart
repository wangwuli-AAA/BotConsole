import 'dart:async';
import 'dart:ui' show AppExitResponse;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/app_paths.dart';
import 'core/settings.dart';
import 'services/health_monitor.dart';
import 'services/service_controller.dart';
import 'services/whitelist_store.dart';
import 'usage/usage_controller.dart';
import 'ui/dashboard_page.dart';
import 'ui/logs_page.dart';
import 'ui/settings_page.dart';
import 'ui/theme.dart';
import 'ui/whitelist_page.dart';
import 'ui/usage_page.dart';

/// 全局状态：配置、控制器、健康监测、白名单。
class AppState extends ChangeNotifier {
  AppState({SettingsStore? store})
    : store = store ?? SettingsStore(AppPaths.settingsFile);

  final SettingsStore store;
  late AppSettings settings;
  late ServiceController controller;
  late HealthMonitor health;
  late WhitelistStore whitelist;
  late UsageController usage;
  late UsageController dashboardUsage;
  bool windowVisible = true;
  int selectedPage = 0;

  void updateUsageVisibility({bool? visible, int? page}) {
    windowVisible = visible ?? windowVisible;
    selectedPage = page ?? selectedPage;
    dashboardUsage.setVisible(windowVisible && selectedPage == 0);
    usage.setVisible(windowVisible && selectedPage == 4);
  }

  String? lastError;

  void initialize() {
    AppPaths.ensureDirs();
    settings = store.load();
    usage = UsageController(settings.usageDatabaseResolved);
    dashboardUsage = UsageController(settings.usageDatabaseResolved, includeDetails: false);
    controller = ServiceController(settings: settings);
    health = HealthMonitor(settings: settings, controller: controller);
    whitelist = WhitelistStore(
      WhitelistStore.defaultPathFor(settings.maibot.dir),
    );
  }

  /// 保存配置（路径变化时重建白名单句柄）。
  Future<void> applySettings(AppSettings next) async {
    final maiBotDirChanged = next.maibot.dir != settings.maibot.dir;
    settings = next;
    store.save(next);
    controller.settings = next;
    health.updateSettings(next);
    usage.setPath(next.usageDatabaseResolved);
    dashboardUsage.setPath(next.usageDatabaseResolved);
    if (maiBotDirChanged) {
      whitelist = WhitelistStore(
        WhitelistStore.defaultPathFor(next.maibot.dir),
      );
    }
    notifyListeners();
  }

  /// 停止所有服务并释放资源。
  Future<void> shutdown() async {
    health.stop();
    updateUsageVisibility(visible: false);
    await controller.shutdown();
  }

  @override
  void dispose() {
    controller.dispose();
    health.dispose();
    usage.dispose();
    dashboardUsage.dispose();
    super.dispose();
  }
}

/// 向下传递 [AppState]。
class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child})
    : super(notifier: state);

  static AppState of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope 未挂载');
    return scope!.notifier!;
  }
}

/// 应用根组件。
class BotConsoleApp extends StatefulWidget {
  const BotConsoleApp({super.key});

  @override
  State<BotConsoleApp> createState() => _BotConsoleAppState();
}

class _BotConsoleAppState extends State<BotConsoleApp> {
  static const _trayChannel = MethodChannel('bot_console/tray');
  late final AppState _state;
  late final AppLifecycleListener _lifecycle;
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    _state = AppState()..initialize();
    _state.health.start();
    _lifecycle = AppLifecycleListener(onExitRequested: _onExitRequested);
    _trayChannel.setMethodCallHandler((call) async {
      if (call.method == 'requestExit') {
        return await _onExitRequested() == AppExitResponse.exit;
      }
      if (call.method == 'visibilityChanged') {
        _state.updateUsageVisibility(visible: call.arguments as bool);
        return null;
      }
      throw MissingPluginException('未知托盘操作：${call.method}');
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _state.updateUsageVisibility();
    });
    if (_state.settings.ui.autoStart) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        unawaited(_state.controller.startAll());
      });
    }
  }

  Future<AppExitResponse> _onExitRequested() async {
    final running = _state.controller.anyRunning;
    if (running && _state.settings.ui.confirmOnClose) {
      final context = _navigatorKey.currentContext;
      if (context != null) {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: const Text('退出 BotConsole？'),
            content: const Text('正在运行的服务会被一并结束，确定退出吗？'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: const Text('退出并停止'),
              ),
            ],
          ),
        );
        if (confirmed != true) return AppExitResponse.cancel;
      }
    }
    await _state.shutdown();
    return AppExitResponse.exit;
  }

  @override
  void dispose() {
    _trayChannel.setMethodCallHandler(null);
    _lifecycle.dispose();
    _state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: _state,
      child: MaterialApp(
        navigatorKey: _navigatorKey,
        title: 'BotConsole',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        home: const _Shell(),
      ),
    );
  }
}

class _Shell extends StatefulWidget {
  const _Shell();

  @override
  State<_Shell> createState() => _ShellState();
}

class _ShellState extends State<_Shell> {
  int _index = 0;

  static const List<_NavItem> _items = [
    _NavItem('总览', Icons.dashboard_outlined, Icons.dashboard),
    _NavItem('群聊白名单', Icons.rule_outlined, Icons.rule),
    _NavItem('日志', Icons.article_outlined, Icons.article),
    _NavItem('设置', Icons.settings_outlined, Icons.settings),
    _NavItem('用量分析', Icons.insights_outlined, Icons.insights),
  ];

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return Scaffold(
      body: Column(
        children: [
          if (AppPaths.logsWarning != null)
            MaterialBanner(
              content: Tooltip(
                message: AppPaths.logsWarning!,
                child: Text(AppPaths.logsWarning!, maxLines: 2, overflow: TextOverflow.ellipsis),
              ),
              leading: const Icon(Icons.warning_amber_rounded),
              actions: [
                TextButton(
                  onPressed: () {
                    setState(() => _index = 3);
                    state.updateUsageVisibility(page: 3);
                  },
                  child: const Text('查看位置'),
                ),
              ],
            ),
          Expanded(
            child: Row(
              children: [
                _Sidebar(
                  items: _items,
                  index: _index,
                  onSelect: (i) {
                    setState(() => _index = i);
                    state.updateUsageVisibility(page: i);
                  },
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  child: ListenableBuilder(
                    listenable: Listenable.merge([
                      state.controller,
                      state.health,
                      state,
                    ]),
                    builder: (context, _) => IndexedStack(
                      index: _index,
                      children: [
                        DashboardPage(onOpenUsage: () {
                          setState(() => _index = 4);
                          state.updateUsageVisibility(page: 4);
                        }),
                        const WhitelistPage(),
                        const LogsPage(),
                        const SettingsPage(),
                        UsagePageView(controller: state.usage),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _NavItem {
  const _NavItem(this.label, this.icon, this.selectedIcon);

  final String label;
  final IconData icon;
  final IconData selectedIcon;
}

class _Sidebar extends StatelessWidget {
  const _Sidebar({
    required this.items,
    required this.index,
    required this.onSelect,
  });

  final List<_NavItem> items;
  final int index;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 208,
      color: AppColors.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 22, 20, 18),
            child: Row(
              children: [
                _LogoMark(),
                const SizedBox(width: 10),
                const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'BotConsole',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.4,
                      ),
                    ),
                    Text(
                      'SnowLuma / MaiBot',
                      style: TextStyle(
                        fontSize: 11,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const Divider(),
          const SizedBox(height: 8),
          for (var i = 0; i < items.length; i++)
            _SidebarTile(
              item: items[i],
              selected: i == index,
              onTap: () => onSelect(i),
            ),
          const Spacer(),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Windows · 本地控制台',
              style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _SidebarTile extends StatelessWidget {
  const _SidebarTile({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final _NavItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
      child: Material(
        color: selected ? AppColors.accentSoft : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            child: Row(
              children: [
                Icon(
                  selected ? item.selectedIcon : item.icon,
                  size: 18,
                  color: selected ? AppColors.accent : AppColors.textSecondary,
                ),
                const SizedBox(width: 10),
                Text(
                  item.label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    color: selected
                        ? AppColors.textPrimary
                        : AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _LogoMark extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        gradient: const LinearGradient(
          colors: [AppColors.accent, Color(0xFF43D9AD)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: const Icon(
        Icons.smart_toy_outlined,
        size: 19,
        color: Colors.white,
      ),
    );
  }
}

/// 简单的错误提示。
void showError(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message), backgroundColor: const Color(0xFF3A2020)),
  );
}

/// 简单的成功提示。
void showInfo(BuildContext context, String message) {
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}

Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  required String content,
  String confirmLabel = '确定',
  bool danger = false,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: Text(title),
      content: Text(content),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('取消'),
        ),
        FilledButton(
          style: danger
              ? FilledButton.styleFrom(backgroundColor: AppColors.danger)
              : null,
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: Text(confirmLabel),
        ),
      ],
    ),
  );
  return result ?? false;
}

/// 打开系统文件/目录选择器返回的路径是否是目录。
bool isDirectoryPath(String path) => Directory(path).existsSync();
