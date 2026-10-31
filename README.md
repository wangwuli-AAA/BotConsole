# BotConsole

SnowLuma / MaiBot 的 Flutter Windows 桌面启动器，提供服务启停、健康状态、日志、白名单编辑与会话 Token 用量分析。

## 下载

在 GitHub 仓库的 **Releases** 页面下载 `BotConsole-windows-x64.zip`，完整解压后运行 `bot_console.exe`。请保留同目录中的 DLL 与 data 目录。程序不会附带 SnowLuma、MaiBot、Node 或 Python，需要自行安装并在设置中指定路径。

## 首次使用

1. 双击解压目录内的 `bot_console.exe`；从源码构建则运行 `build\windows\x64\runner\Release\bot_console.exe`。
2. 打开“设置”，确认 SnowLuma、MaiBot 目录及 Node、Python 路径。
3. SnowLuma 入口使用 `index.mjs`，MaiBot 入口使用 `bot.py`；端口需要与服务自身配置一致。
4. 在“总览”点击“一键启动”，然后查看端口、健康状态和日志。
5. “群聊白名单”会修改 MaiBot 的 `config\adapter_policy.toml`，保存前自动备份。

“启动时自动拉起服务”表示打开 BotConsole 后自动启动两个服务；不包含 Windows 开机自启。

## 配置与日志

- 配置：`%APPDATA%\BotConsole\settings.json`。
- 日志：优先 `%APPDATA%\BotConsole\logs`；四个日志中任一个无法打开时，依次尝试 `%LOCALAPPDATA%\BotConsole\logs`、系统临时目录下的 `BotConsole\logs`。
- 发生切换时界面显示提示；“设置 → 位置”和日志页显示实际位置。临时目录可能被系统清理。
- `BOTCONSOLE_HOME` 环境变量可覆盖配置根目录，适合隔离测试。日志仍按上述规则选择可写目录。
- 修改设置不会修改 SnowLuma / MaiBot 自身的端口配置。
- 初始目录探测应用旁及当前工作目录中的 `SnowLuma` / `MaiBot`，Node 优先从 PATH 查找；首次使用请检查设置。WebUI 令牌默认留空，按自己的部署填写。

## 启停与退出

启动器通过 Win32 `CreateProcessW` 和 `CREATE_NO_WINDOW` 启动服务。先挂起创建进程，加入配置了退出清理的 Job Object 后再恢复执行；创建或绑定 Job 失败时取消启动并显示错误。停止或退出应用会结束所属 Job 的进程树。

最小化或点击窗口关闭按钮会收进系统托盘，服务继续运行。点击托盘图标或菜单“显示窗口”恢复；菜单“退出”执行退出清理，服务运行时按设置询问确认。托盘图标注册失败时保留普通窗口行为。

## 用量分析

首页显示近 24 小时用量；侧边栏“用量分析”支持时间范围、小时/日/周/月聚合、会话类型和真实会话 ID、模型、任务、供应商及请求类型筛选。可查看指标环比、堆叠趋势、调用与费用趋势、会话排行、维度分布、星期/小时热力图和每页 100 条的可排序明细。点击排行或分布继续筛选。

- 默认读取已配置 MaiBot 目录下的 `data/MaiBot.db`；“设置 → MaiBot → 用量数据库”可覆盖路径，留空恢复默认。
- 数据来自 `llm_usage`，按原始 `session_id` 关联 `chat_sessions`；同名会话分开，空 ID 为“未归属（含后台任务）”，未关联的非空 ID 为独立未知会话。
- 总 token 汇总原始 `total_tokens`；输入/输出分别统计，缓存不额外计入总量。缓存按启用标记和命中/未命中补全规则统计，无可统计缓存显示“—”。
- “账面费用（元）”取数据库 `cost`，不按现价重算；平均耗时仅计算有耗时记录的调用。统计解读由规则生成，不调用模型。
- 时间为北京时间，区间为 `[开始, 结束)`；周从周一开始，月为自然月。环比取上一等长区间，零基数显示“新增”或“—”。
- 首页或分析页可见时每 60 秒刷新，支持手动刷新；切换到其他页面或收进托盘暂停自动统计。读取失败时保留旧结果并提示过期，切换数据库会清空原数据库结果。
- “导出 CSV”选择目标目录，生成带时间戳的 UTF-8 BOM 文件；可导出汇总或全部筛选明细，独立于当前明细页。导出保留快照的时间范围与记录 ID 上界，新增调用留到下一次刷新。汇总文件包含整体、时间和各维度分组，属于多组视角，不能跨维度再次相加。

数据库在后台 isolate 以只读模式打开，设置 `query_only` 和 3 秒 `busy_timeout`，复用现有 WAL，不改日志模式、表结构或聚合调度，也不修改 MaiBot。字段不兼容时明确提示。时间桶上限 5000 个，超过时请改用较粗粒度。只统计已记录用量，不补造历史或失败调用费用。

## 验证与构建

```bat
git clone https://github.com/wangwuli-AAA/BotConsole.git
cd BotConsole
flutter pub get --enforce-lockfile
flutter analyze --no-pub
flutter test --no-pub
flutter build windows --release --no-pub
```

使用 Flutter 3.44.2 和安装了“使用 C++ 的桌面开发”组件的 Visual Studio。测试包含真实 Node 进程探针，需要 Windows 和 PATH 中可用的 Node。分发时需复制整个 `build\windows\x64\runner\Release` 文件夹，不能只复制 exe。

依赖固定为 `sqlite3 3.5.2`、`fl_chart 1.3.0`。原计划的 sqlite3 3.8.0 依赖与当前 Flutter 固定的 meta 1.18.0 冲突，因此使用兼容版本，不覆盖 SDK 依赖。SQLite 通过 native assets 打包，分发必须包含 `sqlite3.dll` 和 `data/flutter_assets/NativeAssetsManifest.json`。

只读对账工具：`dart run tool/verify_usage.dart <数据库路径> [明细CSV路径]`。验证记录见 `VALIDATION.md`。

## GitHub Actions 与 Release

`.github/workflows/windows.yml` 在 main 推送、拉取请求或手动触发时执行分析、完整测试和 Windows x64 Release 编译，生成可下载的 zip artifact 与 SHA-256 校验文件。

正式发布先更新 `pubspec.yaml` 的版本号，再推送对应 `v版本号` 标签，例如 `version: 1.0.0+1` 对应 `v1.0.0`。标签构建成功后自动创建 GitHub Release 并附上 Windows 绿色包和校验文件。编译失败不会发布。发布使用内置 GITHUB_TOKEN，不需要添加个人访问令牌。

## 常见问题

- 启动失败：检查路径、入口文件以及 stderr 日志；若提示 Job 失败，检查启动环境的进程限制。
- 日志目录不可写：查看界面给出的实际备用目录；全部失败时修复目录权限后重新打开应用。
- 若从带 Windows 低完整性标签的目录构建，生成的 exe 也可能继承低标签：会导致日志/CSV 写入被拒绝、托盘图标注册失败。可用 `icacls build\windows\x64\runner\Release\bot_console.exe` 检查。对本工程生成的 Release 目录恢复普通用户完整性后重新启动：`icacls build\windows\x64\runner\Release /setintegritylevel "(OI)(CI)M" /T`；无需管理员方式运行应用，也无需修改数据库权限。
- 服务运行但状态未就绪：检查 QQ 登录、服务端口配置和日志；端口连通不能单独证明适配器已认证连接。
- 隔离临时服务的启动、托盘与退出清理已验证；真实 QQ 登录、实际服务重启和白名单热加载仍需按自己的部署验收，详见 `VALIDATION.md`。
