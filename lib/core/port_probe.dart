import 'dart:async';
import 'dart:io';

/// 端口 / HTTP 探测。全部异步、失败不抛异常。

/// TCP 能否连上（默认 300ms 超时）。
Future<bool> isTcpOpen(
  String host,
  int port, {
  Duration timeout = const Duration(milliseconds: 300),
}) async {
  Socket? socket;
  try {
    socket = await Socket.connect(host, port, timeout: timeout);
    return true;
  } on Object {
    return false;
  } finally {
    socket?.destroy();
  }
}

/// HTTP 是否就绪（返回状态码，异常返回 null）。
Future<int?> httpStatus(
  Uri uri, {
  Duration timeout = const Duration(milliseconds: 1500),
}) async {
  final client = HttpClient()
    ..connectionTimeout = timeout
    ..idleTimeout = const Duration(seconds: 2)
    // 不经过系统/环境代理，直连目标。
    ..findProxy = ((_) => 'DIRECT');
  try {
    final request = await client.getUrl(uri).timeout(timeout);
    final response = await request.close().timeout(timeout);
    await response.drain<void>().timeout(timeout);
    return response.statusCode;
  } on Object {
    return null;
  } finally {
    client.close(force: true);
  }
}

/// 批量探测端口。
Future<Map<int, bool>> probePorts(String host, Iterable<int> ports) async {
  final result = <int, bool>{};
  final futures = ports.map((port) async {
    result[port] = await isTcpOpen(host, port);
  });
  await Future.wait(futures);
  return result;
}
