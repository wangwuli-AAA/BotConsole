import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import 'env_builder.dart';

/// 用 `dart:ffi` 直接调 kernel32 起子进程，**不使用** `Process.start`
/// （Dart 在 Windows 上会为子进程创建控制台窗口，也就是那两个黑框）。
///
/// 关键点：
/// * `CREATE_NO_WINDOW`：全程不出现控制台窗口；
/// * 每个服务一个 Job Object + `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`：
///   本应用退出/崩溃时句柄关闭，整个子进程树被系统一并结束，不留孤儿；
/// * stdout/stderr 直接以 `FILE_APPEND_DATA` 打开日志文件交给子进程继承，
///   Dart 侧只读文件增量（见 [LogTailer]），没有管道线程与编码问题。

/// 启动失败。
class ProcessLaunchException implements Exception {
  ProcessLaunchException(this.message, {this.errorCode});

  final String message;
  final int? errorCode;

  @override
  String toString() => errorCode == null ? message : '$message（错误码 $errorCode）';
}

/// 启动参数。
class LaunchSpec {
  const LaunchSpec({
    required this.name,
    required this.executable,
    this.arguments = const [],
    required this.workingDirectory,
    required this.environment,
    required this.stdoutPath,
    required this.stderrPath,
  });

  final String name;
  final String executable;
  final List<String> arguments;
  final String workingDirectory;
  final Map<String, String> environment;
  final String stdoutPath;
  final String stderrPath;
}

/// 已启动进程的句柄抽象（便于单元测试注入假实现）。
abstract class LaunchHandle {
  String get name;

  int get pid;

  bool get isAlive;

  /// 存活时为 null，退出后为退出码。
  int? get exitCode;

  /// 结束进程（连同通过 Job 关联的子进程）。
  Future<void> terminate({Duration grace});

  /// 释放句柄；若 Job 仍持有且未调用 terminate，关闭句柄也会结束进程树。
  void close();
}

/// 启动器抽象。
abstract class Launcher {
  LaunchHandle start(LaunchSpec spec);
}

// ---------------------------------------------------------------------------
// Win32 结构体与常量
// ---------------------------------------------------------------------------

final class _SecurityAttributes extends Struct {
  @Uint32()
  external int nLength;

  external Pointer<Void> lpSecurityDescriptor;

  @Int32()
  external int bInheritHandle;
}

final class _StartupInfo extends Struct {
  @Uint32()
  external int cb;

  external Pointer<Utf16> lpReserved;

  external Pointer<Utf16> lpDesktop;

  external Pointer<Utf16> lpTitle;

  @Uint32()
  external int dwX;

  @Uint32()
  external int dwY;

  @Uint32()
  external int dwXSize;

  @Uint32()
  external int dwYSize;

  @Uint32()
  external int dwXCountChars;

  @Uint32()
  external int dwYCountChars;

  @Uint32()
  external int dwFillAttribute;

  @Uint32()
  external int dwFlags;

  @Uint16()
  external int wShowWindow;

  @Uint16()
  external int cbReserved2;

  external Pointer<Uint8> lpReserved2;

  @IntPtr()
  external int hStdInput;

  @IntPtr()
  external int hStdOutput;

  @IntPtr()
  external int hStdError;
}

final class _ProcessInformation extends Struct {
  @IntPtr()
  external int hProcess;

  @IntPtr()
  external int hThread;

  @Uint32()
  external int dwProcessId;

  @Uint32()
  external int dwThreadId;
}

final class _JobBasicLimitInformation extends Struct {
  @Int64()
  external int perProcessUserTimeLimit;

  @Int64()
  external int perJobUserTimeLimit;

  @Uint32()
  external int limitFlags;

  @IntPtr()
  external int minimumWorkingSetSize;

  @IntPtr()
  external int maximumWorkingSetSize;

  @Uint32()
  external int activeProcessLimit;

  @IntPtr()
  external int affinity;

  @Uint32()
  external int priorityClass;

  @Uint32()
  external int schedulingClass;
}

final class _JobExtendedLimitInformation extends Struct {
  external _JobBasicLimitInformation basic;

  @Array(6)
  external Array<Uint64> ioCounters;

  @IntPtr()
  external int processMemoryLimit;

  @IntPtr()
  external int jobMemoryLimit;

  @IntPtr()
  external int peakProcessMemoryUsed;

  @IntPtr()
  external int peakJobMemoryUsed;
}

const int _genericRead = 0x80000000;
const int _genericWrite = 0x40000000;
const int _fileShareRead = 0x00000001;
const int _fileShareWrite = 0x00000002;
const int _fileAppendData = 0x00000004;
const int _openAlways = 4;
const int _openExisting = 3;
const int _createNoWindow = 0x08000000;
const int _createSuspended = 0x00000004;
const int _createUnicodeEnvironment = 0x00000400;
const int _startfUseStdHandles = 0x100;
const int _jobObjectLimitKillOnJobClose = 0x2000;
const int _jobObjectExtendedLimitInformationClass = 9;
const int _processTerminate = 0x0001;
const int _stillActive = 259;
const int _formatMessageFromSystem = 0x00001000;
const int _formatMessageIgnoreInserts = 0x00000200;
const int _invalidHandleValue = -1;

typedef _CreateJobObjectNative =
    IntPtr Function(Pointer<_SecurityAttributes>, Pointer<Utf16>);
typedef _CreateJobObjectDart =
    int Function(Pointer<_SecurityAttributes>, Pointer<Utf16>);

typedef _SetInformationJobObjectNative =
    Int32 Function(IntPtr, Uint32, Pointer, Uint32);
typedef _SetInformationJobObjectDart = int Function(int, int, Pointer, int);

typedef _AssignProcessToJobObjectNative = Int32 Function(IntPtr, IntPtr);
typedef _AssignProcessToJobObjectDart = int Function(int, int);

typedef _TerminateJobObjectNative = Int32 Function(IntPtr, Uint32);
typedef _TerminateJobObjectDart = int Function(int, int);

typedef _CreateProcessNative =
    Int32 Function(
      Pointer<Utf16>,
      Pointer<Utf16>,
      Pointer<_SecurityAttributes>,
      Pointer<_SecurityAttributes>,
      Int32,
      Uint32,
      Pointer,
      Pointer<Utf16>,
      Pointer<_StartupInfo>,
      Pointer<_ProcessInformation>,
    );
typedef _CreateProcessDart =
    int Function(
      Pointer<Utf16>,
      Pointer<Utf16>,
      Pointer<_SecurityAttributes>,
      Pointer<_SecurityAttributes>,
      int,
      int,
      Pointer,
      Pointer<Utf16>,
      Pointer<_StartupInfo>,
      Pointer<_ProcessInformation>,
    );

typedef _CreateFileNative =
    IntPtr Function(
      Pointer<Utf16>,
      Uint32,
      Uint32,
      Pointer<_SecurityAttributes>,
      Uint32,
      Uint32,
      IntPtr,
    );
typedef _CreateFileDart =
    int Function(
      Pointer<Utf16>,
      int,
      int,
      Pointer<_SecurityAttributes>,
      int,
      int,
      int,
    );

typedef _CloseHandleNative = Int32 Function(IntPtr);
typedef _CloseHandleDart = int Function(int);

typedef _ResumeThreadNative = Uint32 Function(IntPtr);
typedef _ResumeThreadDart = int Function(int);

typedef _GetExitCodeProcessNative = Int32 Function(IntPtr, Pointer<Uint32>);
typedef _GetExitCodeProcessDart = int Function(int, Pointer<Uint32>);

typedef _TerminateProcessNative = Int32 Function(IntPtr, Uint32);
typedef _TerminateProcessDart = int Function(int, int);

typedef _OpenProcessNative = IntPtr Function(Uint32, Int32, Uint32);
typedef _OpenProcessDart = int Function(int, int, int);

typedef _GetLastErrorNative = Uint32 Function();
typedef _GetLastErrorDart = int Function();

typedef _FormatMessageNative =
    Uint32 Function(
      Uint32,
      Pointer,
      Uint32,
      Uint32,
      Pointer<Utf16>,
      Uint32,
      Pointer,
    );
typedef _FormatMessageDart =
    int Function(int, Pointer, int, int, Pointer<Utf16>, int, Pointer);

class _Kernel32 {
  _Kernel32() : _lib = DynamicLibrary.open('kernel32.dll');

  final DynamicLibrary _lib;

  late final _CreateJobObjectDart createJobObject = _lib
      .lookupFunction<_CreateJobObjectNative, _CreateJobObjectDart>(
        'CreateJobObjectW',
      );

  late final _SetInformationJobObjectDart setInformationJobObject = _lib
      .lookupFunction<
        _SetInformationJobObjectNative,
        _SetInformationJobObjectDart
      >('SetInformationJobObject');

  late final _AssignProcessToJobObjectDart assignProcessToJobObject = _lib
      .lookupFunction<
        _AssignProcessToJobObjectNative,
        _AssignProcessToJobObjectDart
      >('AssignProcessToJobObject');

  late final _TerminateJobObjectDart terminateJobObject = _lib
      .lookupFunction<_TerminateJobObjectNative, _TerminateJobObjectDart>(
        'TerminateJobObject',
      );

  late final _CreateProcessDart createProcess = _lib
      .lookupFunction<_CreateProcessNative, _CreateProcessDart>(
        'CreateProcessW',
      );

  late final _CreateFileDart createFile = _lib
      .lookupFunction<_CreateFileNative, _CreateFileDart>('CreateFileW');

  late final _CloseHandleDart closeHandle = _lib
      .lookupFunction<_CloseHandleNative, _CloseHandleDart>('CloseHandle');

  late final _ResumeThreadDart resumeThread = _lib
      .lookupFunction<_ResumeThreadNative, _ResumeThreadDart>('ResumeThread');

  late final _GetExitCodeProcessDart getExitCodeProcess = _lib
      .lookupFunction<_GetExitCodeProcessNative, _GetExitCodeProcessDart>(
        'GetExitCodeProcess',
      );

  late final _TerminateProcessDart terminateProcess = _lib
      .lookupFunction<_TerminateProcessNative, _TerminateProcessDart>(
        'TerminateProcess',
      );

  late final _OpenProcessDart openProcess = _lib
      .lookupFunction<_OpenProcessNative, _OpenProcessDart>('OpenProcess');

  late final _GetLastErrorDart getLastError = _lib
      .lookupFunction<_GetLastErrorNative, _GetLastErrorDart>('GetLastError');

  late final _FormatMessageDart formatMessage = _lib
      .lookupFunction<_FormatMessageNative, _FormatMessageDart>(
        'FormatMessageW',
      );
}

final _Kernel32 _kernel32 = _Kernel32();

/// 把 Win32 错误码转成可读文本（失败时返回空串）。
String win32ErrorMessage(int code) {
  if (code == 0) return '';
  final buffer = calloc<Uint16>(1024);
  try {
    final len = _kernel32.formatMessage(
      _formatMessageFromSystem | _formatMessageIgnoreInserts,
      nullptr,
      code,
      0,
      buffer.cast<Utf16>(),
      1024,
      nullptr,
    );
    if (len == 0) return '';
    return buffer.cast<Utf16>().toDartString().trim();
  } finally {
    calloc.free(buffer);
  }
}

/// FFI 启动器实现。
class FfiLauncher implements Launcher {
  const FfiLauncher();

  @override
  LaunchHandle start(LaunchSpec spec) {
    final executable = File(spec.executable);
    if (!executable.existsSync()) {
      throw ProcessLaunchException('可执行文件不存在：${spec.executable}');
    }
    final workingDir = Directory(spec.workingDirectory);
    if (!workingDir.existsSync()) {
      throw ProcessLaunchException('工作目录不存在：${spec.workingDirectory}');
    }
    Directory(p.dirname(spec.stdoutPath)).createSync(recursive: true);
    Directory(p.dirname(spec.stderrPath)).createSync(recursive: true);

    final sa = calloc<_SecurityAttributes>();
    final si = calloc<_StartupInfo>();
    final pi = calloc<_ProcessInformation>();
    Pointer<Utf16> appName = nullptr;
    Pointer<Utf16> cmdLine = nullptr;
    Pointer<Utf16> cwd = nullptr;
    Pointer<Utf16> nulName = nullptr;
    Pointer<Uint16> envBlock = nullptr;
    var job = 0;
    var hStdOut = 0;
    var hStdErr = 0;
    var hStdIn = 0;

    try {
      sa.ref.nLength = sizeOf<_SecurityAttributes>();
      sa.ref.bInheritHandle = 1;

      hStdOut = _openInheritableFile(spec.stdoutPath, append: true, sa: sa);
      hStdErr = _openInheritableFile(spec.stderrPath, append: true, sa: sa);
      nulName = 'NUL'.toNativeUtf16();
      hStdIn = _kernel32.createFile(
        nulName,
        _genericRead | _genericWrite,
        _fileShareRead | _fileShareWrite,
        sa,
        _openExisting,
        0,
        0,
      );
      if (hStdIn == 0 || hStdIn == _invalidHandleValue) {
        throw ProcessLaunchException(
          '无法打开标准输入 NUL',
          errorCode: _kernel32.getLastError(),
        );
      }

      si.ref.cb = sizeOf<_StartupInfo>();
      si.ref.dwFlags = _startfUseStdHandles;
      si.ref.hStdInput = hStdIn;
      si.ref.hStdOutput = hStdOut;
      si.ref.hStdError = hStdErr;

      final units = encodeEnvironmentBlock(spec.environment);
      envBlock = calloc<Uint16>(units.length + 1);
      envBlock.asTypedList(units.length + 1).setAll(0, units);

      appName = spec.executable.toNativeUtf16();
      cmdLine = buildCommandLine(
        spec.executable,
        spec.arguments,
      ).toNativeUtf16();
      cwd = spec.workingDirectory.toNativeUtf16();

      job = _createJob();

      final ok = _kernel32.createProcess(
        appName,
        cmdLine,
        nullptr,
        nullptr,
        1,
        _createNoWindow | _createUnicodeEnvironment | _createSuspended,
        envBlock.cast<Void>(),
        cwd,
        si,
        pi,
      );

      if (ok == 0) {
        final code = _kernel32.getLastError();
        throw ProcessLaunchException(
          'CreateProcessW 失败：${win32ErrorMessage(code)}',
          errorCode: code,
        );
      }

      final pid = pi.ref.dwProcessId;
      final processHandle = pi.ref.hProcess;

      // 先纳入 Job 再执行，避免子进程在绑定之前派生出不受管理的进程。
      if (_kernel32.assignProcessToJobObject(job, processHandle) == 0) {
        throw ProcessLaunchException(
          '无法将进程加入 Job，已取消启动以避免残留进程',
          errorCode: _kernel32.getLastError(),
        );
      }
      if (_kernel32.resumeThread(pi.ref.hThread) == 0xffffffff) {
        throw ProcessLaunchException(
          '无法恢复进程执行',
          errorCode: _kernel32.getLastError(),
        );
      }

      // 子进程已经拿到句柄副本，父进程这几个句柄可以关掉。
      _closeQuietly(pi.ref.hThread);
      _closeQuietly(hStdIn);
      _closeQuietly(hStdOut);
      _closeQuietly(hStdErr);
      hStdIn = hStdOut = hStdErr = 0;

      return _Win32Process(
        name: spec.name,
        pid: pid,
        job: job,
        processHandle: processHandle,
      );
    } catch (_) {
      if (pi.ref.hProcess != 0) {
        _kernel32.terminateProcess(pi.ref.hProcess, 1);
        _closeQuietly(pi.ref.hProcess);
        _closeQuietly(pi.ref.hThread);
      }
      _closeQuietly(hStdIn);
      _closeQuietly(hStdOut);
      _closeQuietly(hStdErr);
      if (job != 0) _closeQuietly(job);
      rethrow;
    } finally {
      if (envBlock != nullptr) calloc.free(envBlock);
      if (appName != nullptr) calloc.free(appName);
      if (cmdLine != nullptr) calloc.free(cmdLine);
      if (cwd != nullptr) calloc.free(cwd);
      if (nulName != nullptr) calloc.free(nulName);
      calloc.free(sa);
      calloc.free(si);
      calloc.free(pi);
    }
  }

  int _openInheritableFile(
    String path, {
    required bool append,
    required Pointer<_SecurityAttributes> sa,
  }) {
    final name = path.toNativeUtf16();
    try {
      final handle = _kernel32.createFile(
        name,
        append ? _fileAppendData : _genericWrite,
        _fileShareRead | _fileShareWrite,
        sa,
        _openAlways,
        0,
        0,
      );
      if (handle == 0 || handle == _invalidHandleValue) {
        final code = _kernel32.getLastError();
        throw ProcessLaunchException(
          '无法打开日志文件：$path（${win32ErrorMessage(code)}）',
          errorCode: code,
        );
      }
      return handle;
    } finally {
      calloc.free(name);
    }
  }

  int _createJob() {
    final job = _kernel32.createJobObject(nullptr, nullptr);
    if (job == 0) {
      throw ProcessLaunchException(
        '无法创建 Job',
        errorCode: _kernel32.getLastError(),
      );
    }
    final info = calloc<_JobExtendedLimitInformation>();
    try {
      info.ref.basic.limitFlags = _jobObjectLimitKillOnJobClose;
      final ok = _kernel32.setInformationJobObject(
        job,
        _jobObjectExtendedLimitInformationClass,
        info.cast<Void>(),
        sizeOf<_JobExtendedLimitInformation>(),
      );
      if (ok == 0) {
        final code = _kernel32.getLastError();
        _closeQuietly(job);
        throw ProcessLaunchException('无法配置 Job 进程树清理', errorCode: code);
      }
      return job;
    } finally {
      calloc.free(info);
    }
  }
}

/// 结束指定 PID（端口兜底清理用）。
Future<bool> terminateProcessById(int pid) async {
  final handle = _kernel32.openProcess(_processTerminate, 0, pid);
  if (handle == 0) return false;
  try {
    return _kernel32.terminateProcess(handle, 1) != 0;
  } finally {
    _closeQuietly(handle);
  }
}

void _closeQuietly(int handle) {
  if (handle != 0 && handle != _invalidHandleValue) {
    _kernel32.closeHandle(handle);
  }
}

class _Win32Process implements LaunchHandle {
  _Win32Process({
    required this.name,
    required this.pid,
    required this.job,
    required this.processHandle,
  });

  @override
  final String name;

  @override
  final int pid;

  final int job;
  final int processHandle;

  bool _closed = false;

  @override
  bool get isAlive {
    if (_closed || processHandle == 0) return false;
    final code = calloc<Uint32>();
    try {
      final ok = _kernel32.getExitCodeProcess(processHandle, code);
      if (ok == 0) return false;
      return code.value == _stillActive;
    } finally {
      calloc.free(code);
    }
  }

  @override
  int? get exitCode {
    if (_closed || processHandle == 0) return null;
    final code = calloc<Uint32>();
    try {
      final ok = _kernel32.getExitCodeProcess(processHandle, code);
      if (ok == 0) return null;
      return code.value == _stillActive ? null : code.value;
    } finally {
      calloc.free(code);
    }
  }

  @override
  Future<void> terminate({Duration grace = const Duration(seconds: 3)}) async {
    if (!isAlive) {
      close();
      return;
    }
    if (job != 0) {
      _kernel32.terminateJobObject(job, 1);
    } else {
      _kernel32.terminateProcess(processHandle, 1);
    }
    final deadline = DateTime.now().add(grace);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      if (!isAlive) break;
    }
    if (isAlive) {
      _kernel32.terminateProcess(processHandle, 1);
    }
    close();
  }

  @override
  void close() {
    if (_closed) return;
    _closed = true;
    _closeQuietly(processHandle);
    if (job != 0) _closeQuietly(job);
  }
}
