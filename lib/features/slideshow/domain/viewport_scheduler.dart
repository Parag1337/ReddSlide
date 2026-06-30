import 'dart:collection';
import 'scheduler_task.dart';

enum Ring { immediate, critical, near, background }

enum SchedulerState { idle, active, satisfied, sleeping }

class ViewportScheduler {
  final Map<Ring, LinkedHashSet<SchedulerTask>> _rings = {
    for (final ring in Ring.values)
      ring: LinkedHashSet<SchedulerTask>(),
  };

  final Map<String, SchedulerTask> _inFlight = {};
  final Set<String> _completedOrFailed = {};
  SchedulerState _state = SchedulerState.idle;

  void enqueue({
    required List<SchedulerTask> tasks,
    required int currentIndex,
    required int horizon,
  }) {
    _clearPending();

    for (final task in tasks) {
      if (_isTracked(task)) continue;
      final ring = _computeRing(task, currentIndex, horizon);
      _rings[ring]!.add(task);
    }

    _updateState();
  }

  SchedulerTask? pickTask() {
    for (final ring in Ring.values) {
      for (final task in _rings[ring]!) {
        if (!_inFlight.containsKey(_taskKey(task))) {
          return task;
        }
      }
    }
    return null;
  }

  void markStarted(SchedulerTask task) {
    final key = _taskKey(task);
    _inFlight[key] = task;
    _removeFromRings(task);
  }

  void markCompleted(SchedulerTask task) {
    final key = _taskKey(task);
    if (!_inFlight.containsKey(key)) return;
    _inFlight.remove(key);
    _completedOrFailed.add(key);
    _updateState();
  }

  void markFailed(SchedulerTask task) {
    final key = _taskKey(task);
    if (!_inFlight.containsKey(key)) return;
    _inFlight.remove(key);
    _completedOrFailed.add(key);
    _updateState();
  }

  void cancelGeneration(int oldGeneration) {
    for (final ring in _rings.values) {
      ring.removeWhere((t) => t.generation == oldGeneration);
    }
    _completedOrFailed.removeWhere((key) {
      final sep = key.lastIndexOf('\x00');
      if (sep == -1) return false;
      return int.tryParse(key.substring(sep + 1)) == oldGeneration;
    });
    _updateState();
  }

  void clear() {
    for (final ring in _rings.values) ring.clear();
    _inFlight.clear();
    _completedOrFailed.clear();
    _state = SchedulerState.idle;
  }

  void sleep() {
    _state = SchedulerState.sleeping;
  }

  void wake() {
    _updateState();
  }

  bool get isEmpty => pendingCount == 0 && _inFlight.isEmpty;
  int get pendingCount =>
      _rings.values.fold(0, (sum, ring) => sum + ring.length);
  SchedulerState get state => _state;

  List<int> get ringCounts => [
    _rings[Ring.immediate]!.length,
    _rings[Ring.critical]!.length,
    _rings[Ring.near]!.length,
    _rings[Ring.background]!.length,
  ];

  String _taskKey(SchedulerTask task) => '${task.url}\x00${task.generation}';

  bool _isTracked(SchedulerTask task) {
    final key = _taskKey(task);
    if (_inFlight.containsKey(key)) return true;
    if (_completedOrFailed.contains(key)) return true;
    for (final ring in _rings.values) {
      if (ring.contains(task)) return true;
    }
    return false;
  }

  void _clearPending() {
    for (final ring in _rings.values) {
      ring.clear();
    }
  }

  void _removeFromRings(SchedulerTask task) {
    for (final ring in _rings.values) {
      ring.remove(task);
    }
  }

  Ring _computeRing(SchedulerTask task, int currentIndex, int horizon) {
    final distance = (task.index - currentIndex).abs();
    final base = _baseRing(distance, horizon);
    return _promoteIfGallery(task, base);
  }

  Ring _baseRing(int distance, int horizon) {
    if (distance <= 1) return Ring.immediate;
    if (distance <= 1 + horizon) return Ring.critical;
    if (distance <= 1 + horizon * 2) return Ring.near;
    return Ring.background;
  }

  Ring _promoteIfGallery(SchedulerTask task, Ring ring) {
    if (task.galleryPosition == null) return ring;
    if (ring == Ring.immediate) return ring;
    switch (ring) {
      case Ring.critical:
        return Ring.immediate;
      case Ring.near:
        return Ring.critical;
      case Ring.background:
        return Ring.near;
      default:
        return ring;
    }
  }

  void _updateState() {
    if (_rings.values.any((r) => r.isNotEmpty)) {
      _state = SchedulerState.active;
    } else {
      _state = SchedulerState.satisfied;
    }
  }
}
