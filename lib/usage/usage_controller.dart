import 'dart:async';

import 'package:flutter/foundation.dart';

import 'usage_models.dart';
import 'usage_repository.dart';

/// Statistics have their own loading/error state, independent of bot services.
class UsageController extends ChangeNotifier {
  UsageController(
    this.path, {
    this.includeDetails = true,
    this.repository = const UsageRepository(),
  }) : query = UsageQuery.range(UsageRange.day);

  String path;
  final bool includeDetails;
  final UsageRepository repository;
  UsageQuery query;
  UsageRange range = UsageRange.day;
  UsageSnapshot? snapshot;
  UsagePage? details;
  UsageFailure? error, detailsError;
  bool loading = false, detailsLoading = false, exporting = false;
  UsageSort sort = UsageSort.timestamp;
  bool ascending = false;
  bool _visible = false, _disposed = false;
  Timer? _timer, _debounce;
  int _generation = 0, _detailGeneration = 0;

  void setVisible(bool visible) {
    if (_visible == visible || _disposed) return;
    _visible = visible;
    _timer?.cancel();
    if (visible) {
      if (snapshot == null ||
          error != null ||
          snapshot!.query != query ||
          usageNow().difference(snapshot!.loadedAt).inSeconds >= 60) {
        unawaited(refresh());
      } else if (includeDetails && details == null) {
        unawaited(loadDetails());
      }
      _timer = Timer.periodic(const Duration(seconds: 60), (_) {
        if (!loading && !exporting) unawaited(refresh());
      });
    } else {
      _debounce?.cancel();
      // Discard in-flight results after hiding; no subsequent detail query is started.
      _generation++;
      _detailGeneration++;
      loading = false;
      detailsLoading = false;
    }
    notifyListeners();
  }

  void setPath(String value) {
    if (value == path) return;
    path = value;
    _generation++;
    _detailGeneration++;
    snapshot = null;
    details = null;
    error = null;
    detailsError = null;
    loading = false;
    detailsLoading = false;
    notifyListeners();
    if (_visible) unawaited(refresh());
  }

  void update(UsageQuery value, {UsageRange? selectedRange}) {
    query = value;
    if (selectedRange != null) range = selectedRange;
    _generation++;
    _detailGeneration++;
    detailsLoading = false;
    loading = true;
    details = null;
    detailsError = null;
    error = null;
    notifyListeners();
    _debounce?.cancel();
    _debounce = Timer(
      const Duration(milliseconds: 180),
      () => unawaited(refresh()),
    );
  }

  Future<void> refresh() async {
    if (_disposed) return;
    _debounce?.cancel();
    if (range != UsageRange.custom) {
      final fresh = UsageQuery.range(range, grain: query.grain);
      query = query.withRange(fresh.start, fresh.end, fresh.grain);
    }
    final generation = ++_generation;
    _detailGeneration++;
    detailsLoading = false;
    loading = true;
    error = null;
    notifyListeners();
    try {
      final result = await repository.snapshot(path, query);
      if (_disposed || generation != _generation) return;
      snapshot = result;
      details = null;
      detailsError = null;
      if (includeDetails && _visible) unawaited(loadDetails());
    } catch (e) {
      if (_disposed || generation != _generation) return;
      error = e is UsageFailure ? e : UsageFailure('read', '$e');
    } finally {
      if (!_disposed && generation == _generation) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<void> loadDetails({int page = 0, UsageSort? order, bool? asc}) async {
    final current = snapshot;
    if (current == null || _disposed) return;
    sort = order ?? sort;
    ascending = asc ?? ascending;
    final generation = ++_detailGeneration;
    detailsLoading = true;
    detailsError = null;
    notifyListeners();
    try {
      final result = await repository.details(
        path,
        current,
        page: page,
        sort: sort,
        ascending: ascending,
      );
      if (_disposed || generation != _detailGeneration || current != snapshot) {
        return;
      }
      details = result;
    } catch (e) {
      if (_disposed || generation != _detailGeneration) return;
      detailsError = e is UsageFailure ? e : UsageFailure('read', '$e');
    } finally {
      if (!_disposed && generation == _detailGeneration) {
        detailsLoading = false;
        notifyListeners();
      }
    }
  }

  Future<int> export(String destination, {required bool summary}) async {
    final current = snapshot;
    if (current == null || loading || error != null || exporting) {
      throw const UsageFailure('export', '请等待当前筛选读取成功后再导出。');
    }
    exporting = true;
    notifyListeners();
    try {
      return await repository.export(
        path,
        current,
        destination,
        summary: summary,
      );
    } finally {
      if (!_disposed) {
        exporting = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _detailGeneration++;
    _timer?.cancel();
    _debounce?.cancel();
    super.dispose();
  }
}
