import 'dart:collection';

enum MetricEventType {
  imagePreparationStarted,
  imagePreparationCompleted,
  imagePreparationFailed,
  imageCacheHit,
  imageCacheMiss,
  videoControllerCreated,
  videoControllerInitializing,
  videoControllerReady,
  videoControllerReused,
  videoControllerEvicted,
  videoControllerFailed,
  videoRetry,
  slideshowSwipeNext,
  slideshowSwipePrevious,
  slideshowSwipeJump,
  slideshowImageVisible,
  slideshowVideoVisible,
  slideshowOpened,
  firstImageRequested,
  firstImageVisible,
  imageDecoded,
  videoFirstFrameRendered,
  prepWindowReconciled,
  outsideWindowMiss,
  prepEviction,
  preparationCancelled,
  paginationTriggered,
  paginationCompleted,
  playlistStarvation,
  searchRequested,
  searchResponseReceived,
  memorySnapshot,
}

class MetricEvent {
  final MetricEventType type;
  final DateTime timestamp;
  final Map<String, dynamic> data;

  MetricEvent({
    required this.type,
    required DateTime timestamp,
    this.data = const {},
  }) : timestamp = timestamp;
}

class MetricSnapshot {
  final Map<String, dynamic> metrics;

  MetricSnapshot({required this.metrics});

  @override
  String toString() {
    final buf = StringBuffer('\n=== Metrics Snapshot ===\n');
    final keys = metrics.keys.toList()..sort();
    for (final key in keys) {
      buf.writeln('  $key: ${metrics[key]}');
    }
    buf.writeln('=======================');
    return buf.toString();
  }
}

class MetricsCollector {
  final Queue<MetricEvent> _events;
  final int _maxEvents;
  DateTime? _lastSwipeTimestamp;
  int _totalSwipeLatencyMs = 0;
  int _swipeLatencySamples = 0;
  bool _hasEmittedFirstVisible = false;

  MetricsCollector({int maxEvents = 10000})
      : _events = Queue<MetricEvent>(),
        _maxEvents = maxEvents;

  void recordEvent(MetricEventType type, {Map<String, dynamic>? data}) {
    final event = MetricEvent(type: type, timestamp: DateTime.now(), data: data ?? {});
    _events.add(event);

    switch (type) {
      case MetricEventType.slideshowImageVisible:
      case MetricEventType.slideshowVideoVisible:
        _recordSwipeLatency(event.timestamp);
      case MetricEventType.slideshowSwipeNext:
      case MetricEventType.slideshowSwipePrevious:
      case MetricEventType.slideshowSwipeJump:
        _lastSwipeTimestamp = event.timestamp;
      default:
        break;
    }

    if (!_hasEmittedFirstVisible &&
        (type == MetricEventType.slideshowImageVisible ||
         type == MetricEventType.slideshowVideoVisible)) {
      _hasEmittedFirstVisible = true;
      _events.add(MetricEvent(
        type: MetricEventType.firstImageVisible,
        timestamp: event.timestamp,
        data: event.data,
      ));
    }

    while (_events.length > _maxEvents) {
      _events.removeFirst();
    }
  }

  void _recordSwipeLatency(DateTime visibleTime) {
    if (_lastSwipeTimestamp == null) return;
    final ms = visibleTime.difference(_lastSwipeTimestamp!).inMilliseconds;
    if (ms >= 0) {
      _totalSwipeLatencyMs += ms;
      _swipeLatencySamples++;
    }
  }

  int _count(MetricEventType type) {
    return _events.where((e) => e.type == type).length;
  }

  double _prepSuccessRate() {
    final started = _count(MetricEventType.imagePreparationStarted);
    final completed = _count(MetricEventType.imagePreparationCompleted);
    return started > 0 ? completed / started : 0;
  }

  double _videoSuccessRate() {
    final created = _count(MetricEventType.videoControllerCreated);
    final ready = _count(MetricEventType.videoControllerReady);
    return created > 0 ? ready / created : 0;
  }

  double _cacheHitRate() {
    final hits = _count(MetricEventType.imageCacheHit);
    final misses = _count(MetricEventType.imageCacheMiss);
    final total = hits + misses;
    return total > 0 ? hits / total : 0;
  }

  double _swapLatencyMs() {
    return _swipeLatencySamples > 0
        ? _totalSwipeLatencyMs / _swipeLatencySamples
        : 0;
  }

  MetricSnapshot snapshot() {
    return MetricSnapshot(metrics: {
      'image.preparations.started': _count(MetricEventType.imagePreparationStarted),
      'image.preparations.completed': _count(MetricEventType.imagePreparationCompleted),
      'image.preparations.failed': _count(MetricEventType.imagePreparationFailed),
      'image.preparations.successRate': _formatPercent(_prepSuccessRate()),
      'image.cache.hits': _count(MetricEventType.imageCacheHit),
      'image.cache.misses': _count(MetricEventType.imageCacheMiss),
      'image.cache.hitRate': _formatPercent(_cacheHitRate()),
      'image.decoded': _count(MetricEventType.imageDecoded),
      'video.controllers.created': _count(MetricEventType.videoControllerCreated),
      'video.controllers.initializing': _count(MetricEventType.videoControllerInitializing),
      'video.controllers.ready': _count(MetricEventType.videoControllerReady),
      'video.controllers.reused': _count(MetricEventType.videoControllerReused),
      'video.controllers.evicted': _count(MetricEventType.videoControllerEvicted),
      'video.controllers.failed': _count(MetricEventType.videoControllerFailed),
      'video.retries': _count(MetricEventType.videoRetry),
      'video.successRate': _formatPercent(_videoSuccessRate()),
      'video.firstFrames': _count(MetricEventType.videoFirstFrameRendered),
      'slideshow.navigation.next': _count(MetricEventType.slideshowSwipeNext),
      'slideshow.navigation.previous': _count(MetricEventType.slideshowSwipePrevious),
      'slideshow.navigation.jump': _count(MetricEventType.slideshowSwipeJump),
      'slideshow.images.visible': _count(MetricEventType.slideshowImageVisible),
      'slideshow.videos.visible': _count(MetricEventType.slideshowVideoVisible),
      'slideshow.opened': _count(MetricEventType.slideshowOpened),
      'slideshow.firstImageRequested': _count(MetricEventType.firstImageRequested),
      'slideshow.firstImageVisible': _count(MetricEventType.firstImageVisible),
      'slideshow.navigation.swipeLatencyMs': _swapLatencyMs().toStringAsFixed(1),
      'slideshow.navigation.swipeLatencySamples': _swipeLatencySamples,
      'prepWindow.reconciliations': _count(MetricEventType.prepWindowReconciled),
      'prepWindow.misses': _count(MetricEventType.outsideWindowMiss),
      'prepWindow.evictions': _count(MetricEventType.prepEviction),
      'prepWindow.cancelled': _count(MetricEventType.preparationCancelled),
      'pagination.triggers': _count(MetricEventType.paginationTriggered),
      'pagination.completions': _count(MetricEventType.paginationCompleted),
      'pagination.starvation': _count(MetricEventType.playlistStarvation),
      'search.requests': _count(MetricEventType.searchRequested),
      'search.responses': _count(MetricEventType.searchResponseReceived),
      'memory.snapshots': _count(MetricEventType.memorySnapshot),
      'general.totalEvents': _events.length,
    });
  }

  List<Map<String, dynamic>> export() {
    return _events.map((e) => {
      'type': e.type.name,
      'timestamp': e.timestamp.toIso8601String(),
      'data': Map<String, dynamic>.from(e.data),
    }).toList();
  }

  void reset() {
    _events.clear();
    _lastSwipeTimestamp = null;
    _totalSwipeLatencyMs = 0;
    _swipeLatencySamples = 0;
    _hasEmittedFirstVisible = false;
  }

  void dispose() {
    reset();
  }

  static String _formatPercent(double value) {
    return '${(value * 100).toStringAsFixed(1)}%';
  }
}
