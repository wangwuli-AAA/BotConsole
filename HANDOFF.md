# BotConsole 开发交接

最后更新：2026-10-31。Windows Flutter 桌面应用，控制 SnowLuma/MaiBot 并只读分析用量。

## 构建与验证

使用 Flutter 3.44.2、Dart 3.12.2、Windows Visual Studio C++ 桌面开发环境和 PATH 中的 Node。

```bat
flutter pub get --enforce-lockfile
flutter analyze --no-pub
flutter test --no-pub
flutter build windows --release --no-pub
```

当前完整测试 29 项。统计、只读/WAL 并发、10 万条记录导出、托盘及子进程清理详见 VALIDATION.md。

## 代码入口

- lib/app.dart：应用状态、导航、退出确认、托盘通道。
- lib/core/settings.dart：配置持久化；真实配置位于用户 APPDATA，不随源码分发。
- lib/core/proc_launcher.dart：CreateProcessW 无控制台启动、挂起加入 Job、进程树清理。
- lib/services/：服务状态机、健康探测、白名单 TOML 编辑。
- lib/usage/：统计模型、只读数据库查询、独立查询状态。
- lib/ui/usage_page.dart：指标、筛选、图表、明细和 CSV 入口。
- windows/runner/flutter_window.*：Windows 托盘与原生消息处理。
- tool/verify_usage.dart：手动只读对账工具，输出可能含真实会话信息，不应提交仓库。

## 公开发布

GitHub Actions 在 main/PR 推送及手动运行时分析、测试、编译；推送与 pubspec.yaml 对应的 v版本标签时发布 GitHub Release。Windows runner 安装 Node，测试不依赖开发者本机安装路径。Actions 固定 Flutter 版本与依赖锁文件。云端构建、29 项测试以及下载包的 SQLite/托盘实机回归已通过，记录见 VALIDATION.md。

首次启动不预设 WebUI 令牌；默认服务目录探测应用旁或当前目录，可在设置覆盖。旧安装配置继续读取，不改外部服务或用户已有配置。

仓库不包含真实 settings.json、数据库、白名单、调用明细导出或带真实数据的截图。早期内部交接历史及本机令牌已移出公开版本。

## 托盘与会话用量分析（最新交接，2026-10-31）

- 新增 `lib/usage/usage_models.dart`、`usage_repository.dart`、`usage_controller.dart`、`lib/ui/usage_page.dart`。服务启停与统计独立维护状态；首页与分析各有控制器，首页始终为近 24 小时摘要。
- 侧边栏新增“用量分析”（索引 4，原设置仍为索引 3）；设置增加 `usageDatabasePath`，旧配置缺失时默认 `<maibot.dir>/data/MaiBot.db`，保存保留未知键。
- 后台 isolate 参数化 SQL、只读连接、`query_only=ON`、`busy_timeout=3000`；同一统计快照使用读取事务。检查现有 journal_mode，不改 WAL/表结构/聚合服务。
- 原始总 token、缓存补全、数据库账面费用、北京半开区间、上一等长区间、真实会话 ID 等口径见 README。会话、模型、任务、供应商与请求类型都可筛选和汇总；缓存无分母显示“—”。
- 明细独立分页（100 条）、可排序；CSV 带 UTF-8 BOM、完整转义，后台每批 1000 条导出全部匹配记录。汇总导出包含多个维度视角。快照记录 ID 上界防止新增调用导致分页/导出混入新记录；MaiBot 已有历史记录如被外部修改，后续刷新才保证重新对齐。
- 查询代次防止过期结果覆盖；刷新失败保留旧值并提示过期；更换数据库清空旧源结果。页面可见时 60 秒刷新，其他页面或托盘隐藏暂停；恢复时刷新已过期结果。
- 原生托盘位于 `windows/runner/flutter_window.*`，`bot_console/tray` 通道处理 `requestExit` / `visibilityChanged`。最小化与关闭收起，点击/菜单恢复，菜单退出经过 Dart 确认与 shutdown；Explorer 重启重新注册，注册失败恢复窗口避免丢失入口。
- 初始窗口按显示器工作区限制大小，避免高 DPI 下窗口按钮和内容超出屏幕。
- 依赖实际采用 `sqlite3 3.5.2`、`fl_chart 1.3.0`，锁文件已更新。sqlite3 3.8.0 的 hooks/record_use 要求 meta >=1.19，与 Flutter SDK 固定 1.18 冲突，未强行覆盖。Release 包含 SQLite DLL 和 `data/flutter_assets/NativeAssetsManifest.json`；干净构建不依赖根目录旧格式 `native_assets.json`。
- **早期“仅是沙箱令牌限制”的推断已更正**：实测 shell 为中完整性（8192），旧 Release exe 继承低完整性文件标签，进程为低完整性（4096）。它会拒绝目录/日志写入，也无法注册托盘图标。仅将生成的 Release 目录标签设为 `(OI)(CI)M` 后，日志初始化、托盘隐藏与恢复均正常。后续重新生成产物时检查标签；未调整系统安全策略或 MaiBot 文件。
- 临时数据库回归包含边界、归属、缓存、费用、组合筛选、只读/WAL 并发、独占写超时、100k 记录和全量导出；状态测试包含快速切换筛选与隐藏暂停；页面测试覆盖 1100 / 700 宽度。完整测试 **29 项通过**。
- 隔离实机回归已通过：两个临时 Node 服务和子进程共六端口；最小化/关闭隐藏保持服务、托盘恢复、实际菜单、取消退出，以及确认退出后六端口全部释放，退出码 0。真实外部服务未被停止。
- 只读对账工具：`tool/verify_usage.dart`；本机数据库仅只读查询，真实 SnowLuma/MaiBot 配置、白名单及服务未修改。
