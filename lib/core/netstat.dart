import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// 端口占用查询。
///
/// 主路径走 Win32 `GetExtendedTcpTable`（纯 FFI，不弹控制台窗口），
/// 失败时退回解析 `netstat -ano`（解析函数单独暴露，便于单元测试）。
class PortOwner {
  const PortOwner({required this.port, required this.pid, required this.address});

  final int port;
  final int pid;
  final String address;

  @override
  String toString() => '$address:$port (PID $pid)';
}

final RegExp _linePattern = RegExp(
  r'^\s*(TCP|UDP)\s+(\S+):(\d+)\s+\S+\s+(\S+)\s+(\d+)\s*$',
  caseSensitive: false,
);

/// 解析 `netstat -ano` 输出。[port] 为 null 时返回所有监听记录。
List<PortOwner> parseNetstat(String output, {int? port}) {
  final owners = <PortOwner>[];
  for (final rawLine in output.split(RegExp(r'\r?\n'))) {
    final match = _linePattern.firstMatch(rawLine);
    if (match == null) continue;
    final protocol = match.group(1)!.toUpperCase();
    final address = match.group(2)!;
    final localPort = int.tryParse(match.group(3)!);
    final state = match.group(4)!.toUpperCase();
    final pid = int.tryParse(match.group(5)!);
    if (localPort == null || pid == null) continue;
    if (port != null && localPort != port) continue;
    if (protocol == 'TCP' && state != 'LISTENING') continue;
    owners.add(PortOwner(port: localPort, pid: pid, address: address));
  }
  return owners;
}

/// 查询监听某端口的 PID（找不到返回 null）。优先 FFI，其次 netstat。
Future<int?> whoListensOnPort(int port) async {
  final viaFfi = lookupListeningPids();
  if (viaFfi.isNotEmpty) {
    final hit = viaFfi[port];
    if (hit != null) return hit;
  }
  final output = await _runNetstat();
  if (output == null) return null;
  final owners = parseNetstat(output, port: port);
  if (owners.isEmpty) return null;
  return owners.first.pid;
}

/// 批量查询这些端口的监听 PID。
Future<Map<int, int>> whoListensOnPorts(Iterable<int> ports) async {
  final wanted = ports.toSet();
  final result = <int, int>{};
  final table = lookupListeningPids();
  for (final entry in table.entries) {
    if (wanted.contains(entry.key)) result[entry.key] = entry.value;
  }
  if (result.length == wanted.length) return result;
  final output = await _runNetstat();
  if (output == null) return result;
  for (final owner in parseNetstat(output)) {
    if (wanted.contains(owner.port) && !result.containsKey(owner.port)) {
      result[owner.port] = owner.pid;
    }
  }
  return result;
}

// ---------------------------------------------------------------------------
// Win32: GetExtendedTcpTable
// ---------------------------------------------------------------------------

final class _MibTcpRowOwnerPid extends Struct {
  @Uint32()
  external int state;

  @Uint32()
  external int localAddr;

  @Uint32()
  external int localPort;

  @Uint32()
  external int remoteAddr;

  @Uint32()
  external int remotePort;

  @Uint32()
  external int owningPid;
}

typedef _GetExtendedTcpTableNative = Uint32 Function(
    Pointer<Void>, Pointer<Uint32>, Int32, Uint32, Uint32, Uint32);
typedef _GetExtendedTcpTableDart = int Function(
    Pointer<Void>, Pointer<Uint32>, int, int, int, int);

const int _afInet = 2;
const int _tcpTableOwnerPidListener = 3;
const int _errorInsufficientBuffer = 122;

class _Iphlpapi {
  _Iphlpapi() : _lib = DynamicLibrary.open('iphlpapi.dll');

  final DynamicLibrary _lib;

  late final _GetExtendedTcpTableDart getExtendedTcpTable =
      _lib.lookupFunction<_GetExtendedTcpTableNative,
          _GetExtendedTcpTableDart>('GetExtendedTcpTable');
}

_Iphlpapi? _iphlpapiInstance;

_Iphlpapi? get _iphlpapi {
  try {
    return _iphlpapiInstance ??= _Iphlpapi();
  } on Object {
    return null;
  }
}

/// 用 FFI 读取当前所有 TCP LISTENING 的 端口 → PID 映射（失败返回空表）。
Map<int, int> lookupListeningPids() {
  final api = _iphlpapi;
  if (api == null) return const {};
  var size = 0;
  final sizePtr = calloc<Uint32>();
  try {
    var ret = api.getExtendedTcpTable(
        nullptr, sizePtr, 0, _afInet, _tcpTableOwnerPidListener, 0);
    if (ret != _errorInsufficientBuffer) return const {};
    for (var attempt = 0; attempt < 3; attempt++) {
      size = sizePtr.value;
      final buffer = calloc<Uint8>(size);
      try {
        ret = api.getExtendedTcpTable(buffer.cast<Void>(), sizePtr, 0, _afInet,
            _tcpTableOwnerPidListener, 0);
        if (ret == 0) {
          return _parseTcpTable(buffer, size);
        }
        if (ret != _errorInsufficientBuffer) return const {};
      } finally {
        calloc.free(buffer);
      }
    }
    return const {};
  } finally {
    calloc.free(sizePtr);
  }
}

Map<int, int> _parseTcpTable(Pointer<Uint8> buffer, int size) {
  final countPtr = buffer.cast<Uint32>();
  final count = countPtr.value;
  const rowSize = 24; // sizeof(MIB_TCPROW_OWNER_PID)
  final base = buffer + 4;
  final result = <int, int>{};
  for (var i = 0; i < count; i++) {
    final rows = base.cast<_MibTcpRowOwnerPid>();
    final row = (rows + i).ref;
    final rawPort = row.localPort & 0xFFFF;
    final port = ((rawPort & 0xFF) << 8) | ((rawPort >> 8) & 0xFF);
    if (port > 0 && !result.containsKey(port)) {
      result[port] = row.owningPid;
    }
    // 防御：若结构体尺寸假设有误，避免越界读取
    if ((i + 1) * rowSize + 4 > size) break;
  }
  return result;
}

Future<String?> _runNetstat() async {
  try {
    final result = await Process.run(
      'netstat',
      const ['-ano'],
      runInShell: false,
      stdoutEncoding: const SystemEncoding(),
      stderrEncoding: const SystemEncoding(),
    );
    if (result.exitCode != 0) return null;
    return result.stdout as String;
  } on ProcessException {
    return null;
  }
}
