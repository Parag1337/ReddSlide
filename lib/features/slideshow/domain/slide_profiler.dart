// TEMPORARY INSTRUMENTATION — Phase 7.2A
// Remove this file and all SlideProfiler callsites after measurements collected.


class _ImageTimeline {
  final String url;
  String? assetId;
  int? queuedMs;
  int? preparingMs;
  int? downloadStartedMs;
  int? downloadCompletedMs;
  int? readyMs;
  int? widgetRequestedMs;
  int? firstPaintMs;
  bool wasCached = false;
  String? error;
  int? downloadSizeBytes;

  _ImageTimeline(this.url);

  Map<String, dynamic> toJson() => {
        'url': url,
        'assetId': assetId,
        'queuedMs': queuedMs,
        'preparingMs': preparingMs,
        'downloadStartedMs': downloadStartedMs,
        'downloadCompletedMs': downloadCompletedMs,
        'readyMs': readyMs,
        'widgetRequestedMs': widgetRequestedMs,
        'firstPaintMs': firstPaintMs,
        'wasCached': wasCached,
        'error': error,
        'downloadSizeBytes': downloadSizeBytes,
      };

  int? get queueWaitMs =>
      preparingMs != null && queuedMs != null ? preparingMs! - queuedMs! : null;

  int? get downloadDecodeMs =>
      downloadCompletedMs != null && downloadStartedMs != null
          ? downloadCompletedMs! - downloadStartedMs!
          : null;

  int? get readyLatencyMs =>
      readyMs != null && downloadCompletedMs != null
          ? readyMs! - downloadCompletedMs!
          : null;

  int? get totalLatencyMs =>
      readyMs != null && queuedMs != null ? readyMs! - queuedMs! : null;
}

class _Timestamp {
  final int ms;
  final int activeWorkers;
  final int queueLength;
  _Timestamp(this.ms, this.activeWorkers, this.queueLength);
}

class _VideoTiming {
  final String url;
  final int startMs;
  int? endMs;
  bool success = false;
  _VideoTiming(this.url, this.startMs);
}

class SlideProfiler {
  SlideProfiler._();

  static bool enabled = true;

  // === Source tagging ===
  static String _sourceType = 'unknown';
  static void setSourceType(String type) {
    _sourceType = type;
  }
  static String get sourceType => _sourceType;

  // === Worker utilization ===
  static int _workerSamples = 0;
  static int _workerAccumulator = 0;
  static int _workerMax = 0;
  static int _workerIdleSamples = 0;
  static final List<_Timestamp> _workerTimeline = [];

  static void sampleWorkers(int active, int maxWorkers) {
    if (!enabled) return;
    _workerSamples++;
    _workerAccumulator += active;
    if (active > _workerMax) _workerMax = active;
    if (active == 0) _workerIdleSamples++;
  }

  // === Queue metrics ===
  static int _queueLengthSamples = 0;
  static int _queueLengthAccumulator = 0;
  static int _queueLengthMax = 0;
  static final Map<String, int> _queueEntryMs = {};
  static final List<int> _queueWaitMs = [];
  static int _totalEnqueued = 0;
  static int _totalDequeued = 0;

  static void sampleQueueLength(int length) {
    if (!enabled) return;
    _queueLengthSamples++;
    _queueLengthAccumulator += length;
    if (length > _queueLengthMax) _queueLengthMax = length;
  }

  static void recordQueueEnter(String url) {
    if (!enabled) return;
    _queueEntryMs[url] = DateTime.now().millisecondsSinceEpoch;
    _totalEnqueued++;
  }

  static void recordQueueExit(String url) {
    if (!enabled) return;
    _totalDequeued++;
    final enter = _queueEntryMs.remove(url);
    if (enter != null) {
      _queueWaitMs.add(DateTime.now().millisecondsSinceEpoch - enter);
    }
  }

  // === Image timelines ===
  static final Map<String, _ImageTimeline> _timelines = {};
  static final List<String> _urlOrder = [];

  static _ImageTimeline _tl(String url) {
    final existing = _timelines[url];
    if (existing != null) return existing;
    final tl = _ImageTimeline(url);
    _timelines[url] = tl;
    _urlOrder.add(url);
    return tl;
  }

  static void recordQueueTimestamp(String url, String? assetId) {
    if (!enabled) return;
    final t = DateTime.now().millisecondsSinceEpoch;
    final tl = _tl(url);
    tl.assetId ??= assetId;
    tl.queuedMs = t;
    _queueEntryMs[url] = t;
    _totalEnqueued++;
  }

  static void recordPreparingTimestamp(String url, String? assetId) {
    if (!enabled) return;
    final t = DateTime.now().millisecondsSinceEpoch;
    final tl = _tl(url);
    tl.assetId ??= assetId;
    tl.preparingMs = t;
  }

  static void recordDownloadStart(String url) {
    if (!enabled) return;
    _tl(url).downloadStartedMs = DateTime.now().millisecondsSinceEpoch;
  }

  static void recordDownloadComplete(String url, {int? sizeBytes}) {
    if (!enabled) return;
    final t = DateTime.now().millisecondsSinceEpoch;
    final tl = _tl(url);
    tl.downloadCompletedMs = t;
    if (sizeBytes != null) tl.downloadSizeBytes = sizeBytes;
  }

  static void recordReady(String url, {bool fromWindowCheck = false}) {
    if (!enabled) return;
    _tl(url).readyMs = DateTime.now().millisecondsSinceEpoch;
  }

  static void recordWidgetRequest(String url) {
    if (!enabled) return;
    _tl(url).widgetRequestedMs = DateTime.now().millisecondsSinceEpoch;
  }

  static void recordFirstPaint(String url, {required bool wasCached}) {
    if (!enabled) return;
    final tl = _tl(url);
    tl.firstPaintMs = DateTime.now().millisecondsSinceEpoch;
    tl.wasCached = wasCached;
  }

  static void recordImageError(String url, String error) {
    if (!enabled) return;
    _tl(url).error = error;
  }

  static void recordDownloadSize(String url, int bytes) {
    if (!enabled) return;
    _tl(url).downloadSizeBytes = bytes;
  }

  // === ImageCache metrics ===
  static int _cacheHits = 0;
  static int _cacheMisses = 0;
  static final Set<String> _seenProviders = {};
  static int _duplicateProviders = 0;

  static void recordCacheHit(String url) {
    if (!enabled) return;
    _cacheHits++;
  }

  static void recordCacheMiss(String url) {
    if (!enabled) return;
    _cacheMisses++;
  }

  static void recordProviderCreated(String url) {
    if (!enabled) return;
    if (_seenProviders.contains(url)) {
      _duplicateProviders++;
    } else {
      _seenProviders.add(url);
    }
  }

  // === Widget rebuild tracking ===
  static int _imageViewerBuilds = 0;
  static int _pageViewBuilds = 0;
  static int _getPreparedHandleCalls = 0;
  static int _preparationRevisionChanges = 0;

  static void recordImageViewerBuild() {
    if (!enabled) return;
    _imageViewerBuilds++;
  }

  static void recordPageViewBuild() {
    if (!enabled) return;
    _pageViewBuilds++;
  }

  static void recordGetPreparedHandleCall() {
    if (!enabled) return;
    _getPreparedHandleCalls++;
  }

  static void recordPreparationRevisionChange() {
    if (!enabled) return;
    _preparationRevisionChanges++;
  }

  // === Pipeline overall timing ===
  static int? _pipelineStartMs;
  static int? _pipelineEndMs;
  static int _firstPageLoadMs = 0;

  static void recordPipelineStart() {
    if (!enabled) return;
    _pipelineStartMs = DateTime.now().millisecondsSinceEpoch;
  }

  static void recordPipelineEnd() {
    if (!enabled) return;
    _pipelineEndMs = DateTime.now().millisecondsSinceEpoch;
    if (_pipelineStartMs != null) {
      _firstPageLoadMs = _pipelineEndMs! - _pipelineStartMs!;
    }
  }

  // === Video metrics ===
  static final Map<String, _VideoTiming> _videoInits = {};
  static int _videoConcurrentPreps = 0;
  static int _videoMaxConcurrent = 0;
  static final List<int> _videoInitDurationsMs = [];
  static int _videoSuccessCount = 0;
  static int _videoFailedCount = 0;

  static void recordVideoInitStart(String url) {
    if (!enabled) return;
    _videoConcurrentPreps++;
    if (_videoConcurrentPreps > _videoMaxConcurrent) {
      _videoMaxConcurrent = _videoConcurrentPreps;
    }
    _videoInits[url] = _VideoTiming(url, DateTime.now().millisecondsSinceEpoch);
  }

  static void recordVideoInitEnd(String url, {required bool success}) {
    if (!enabled) return;
    _videoConcurrentPreps--;
    final timing = _videoInits.remove(url);
    if (timing != null) {
      timing.endMs = DateTime.now().millisecondsSinceEpoch;
      timing.success = success;
      _videoInitDurationsMs.add(timing.endMs! - timing.startMs);
      if (success) {
        _videoSuccessCount++;
      } else {
        _videoFailedCount++;
      }
    }
  }

  // === State transition tracking ===
  static int _stateQueuedCount = 0;
  static int _statePreparingCount = 0;
  static int _stateReadyCount = 0;
  static int _stateFailedCount = 0;
  static int _stateNotRequestedCount = 0;
  static final List<int> _preparingDurationsMs = [];

  static void recordStateTransition(String url, String state) {
    if (!enabled) return;
    switch (state) {
      case 'queued':
        _stateQueuedCount++;
        break;
      case 'preparing':
        _statePreparingCount++;
        break;
      case 'ready':
        _stateReadyCount++;
        final tl = _timelines[url];
        if (tl != null && tl.preparingMs != null) {
          _preparingDurationsMs
              .add(DateTime.now().millisecondsSinceEpoch - tl.preparingMs!);
        }
        break;
      case 'failed':
        _stateFailedCount++;
        break;
      case 'notRequested':
        _stateNotRequestedCount++;
        break;
    }
  }

  // === Search vs Feed comparison ===
  static final Map<String, _SourceStats> _sourceStats = {
    'subreddit': _SourceStats('subreddit'),
    'search': _SourceStats('search'),
    'multi': _SourceStats('multi'),
    'global': _SourceStats('global'),
    'group': _SourceStats('group'),
  };

  static _SourceStats _stats() =>
      _sourceStats.putIfAbsent(_sourceType, () => _SourceStats(_sourceType));

  static void recordSourceQueueWait(int ms) => _stats().queueWaitMs.add(ms);
  static void recordSourceDownloadMs(int ms) =>
      _stats().downloadMs.add(ms);
  static void recordSourceDecodeMs(int ms) => _stats().decodeMs.add(ms);
  static void recordSourceCacheHit() => _stats().cacheHits++;
  static void recordSourceCacheMiss() => _stats().cacheMisses++;

  // === Report generation ===
  static String _fmt(double v) => v.toStringAsFixed(1);

  static double _pct(double v) => double.parse((v * 100).toStringAsFixed(1));

  static double _median(List<int> sorted) {
    if (sorted.isEmpty) return 0;
    final mid = sorted.length ~/ 2;
    if (sorted.length.isOdd) return sorted[mid].toDouble();
    return (sorted[mid - 1] + sorted[mid]) / 2.0;
  }

  static double _p95(List<int> sorted) {
    if (sorted.isEmpty) return 0;
    final idx = (sorted.length * 0.95).ceil() - 1;
    return sorted[idx.clamp(0, sorted.length - 1)].toDouble();
  }

  static double _avg(List<int> values) {
    if (values.isEmpty) return 0;
    return values.reduce((a, b) => a + b) / values.length;
  }

  static Map<String, dynamic> dumpJson() {
    if (!enabled) return {'enabled': false};

    final sortedQueueWait = List<int>.from(_queueWaitMs)..sort();
    final sortedPrepDuration = List<int>.from(_preparingDurationsMs)..sort();
    final sortedVideoInit = List<int>.from(_videoInitDurationsMs)..sort();

    // Slowest 10 images
    final withTotal = _urlOrder
        .map((url) {
          final tl = _timelines[url];
          if (tl == null) return null;
          return {
            'url': url,
            'assetId': tl.assetId,
            'queueWaitMs': tl.queueWaitMs,
            'downloadDecodeMs': tl.downloadDecodeMs,
            'readyLatencyMs': tl.readyLatencyMs,
            'totalLatencyMs': tl.totalLatencyMs,
            'firstPaintMs':
                tl.firstPaintMs != null && tl.readyMs != null
                    ? tl.firstPaintMs! - tl.readyMs!
                    : null,
            'wasCached': tl.wasCached,
            'error': tl.error,
            'downloadSizeBytes': tl.downloadSizeBytes,
          };
        })
        .whereType<Map<String, dynamic>>()
        .toList();
    withTotal.sort((a, b) {
      final at = (a['totalLatencyMs'] as int?) ?? 0;
      final bt = (b['totalLatencyMs'] as int?) ?? 0;
      return bt.compareTo(at);
    });

    return {
      'sourceType': _sourceType,
      'pipeline': {
        'firstPageLoadMs': _firstPageLoadMs,
        'pipelineDurationMs':
            _pipelineStartMs != null && _pipelineEndMs != null
                ? _pipelineEndMs! - _pipelineStartMs!
                : null,
      },
      'workers': {
        'samples': _workerSamples,
        'average': _workerSamples > 0
            ? _fmt(_workerAccumulator / _workerSamples)
            : '0',
        'peak': _workerMax,
        'maxConfigured': 3,
        'idlePercent': _workerSamples > 0
            ? _pct(_workerIdleSamples / _workerSamples)
            : 0,
        'utilizationPercent': _workerSamples > 0
            ? _pct(_workerAccumulator / (_workerSamples * 3))
            : 0,
      },
      'queue': {
        'totalEnqueued': _totalEnqueued,
        'totalDequeued': _totalDequeued,
        'lengthSamples': _queueLengthSamples,
        'lengthAverage': _queueLengthSamples > 0
            ? _fmt(_queueLengthAccumulator / _queueLengthSamples)
            : '0',
        'lengthMax': _queueLengthMax,
        'waitSamples': sortedQueueWait.length,
        'waitAverageMs': _fmt(_avg(sortedQueueWait)),
        'waitMedianMs': _fmt(_median(sortedQueueWait)),
        'waitP95Ms': _fmt(_p95(sortedQueueWait)),
        'waitMaxMs': sortedQueueWait.isNotEmpty
            ? sortedQueueWait.last.toString()
            : '0',
      },
      'images': {
        'timelines': _urlOrder.length,
        'stateTransitions': {
          'notRequested': _stateNotRequestedCount,
          'queued': _stateQueuedCount,
          'preparing': _statePreparingCount,
          'ready': _stateReadyCount,
          'failed': _stateFailedCount,
        },
        'preparingDurationMs': {
          'samples': sortedPrepDuration.length,
          'average': _fmt(_avg(sortedPrepDuration)),
          'median': _fmt(_median(sortedPrepDuration)),
          'p95': _fmt(_p95(sortedPrepDuration)),
          'max': sortedPrepDuration.isNotEmpty
              ? sortedPrepDuration.last.toString()
              : '0',
        },
      },
      'downloadDecode': {
        'totalImages': _urlOrder.length,
        'sizes': _urlOrder.isEmpty
            ? {}
            : {
                'samples': _urlOrder.length,
              },
      },
      'imageCache': {
        'hits': _cacheHits,
        'misses': _cacheMisses,
        'hitRate': (_cacheHits + _cacheMisses) > 0
            ? _pct(_cacheHits / (_cacheHits + _cacheMisses))
            : 0,
        'duplicateProviders': _duplicateProviders,
        'uniqueProviders': _seenProviders.length,
      },
      'widget': {
        'imageViewerBuilds': _imageViewerBuilds,
        'pageViewBuilds': _pageViewBuilds,
        'getPreparedHandleCalls': _getPreparedHandleCalls,
        'preparationRevisionChanges': _preparationRevisionChanges,
      },
      'video': {
        'initSamples': sortedVideoInit.length,
        'initAverageMs': _fmt(_avg(sortedVideoInit)),
        'initMedianMs': _fmt(_median(sortedVideoInit)),
        'initP95Ms': _fmt(_p95(sortedVideoInit)),
        'initMaxMs':
            sortedVideoInit.isNotEmpty ? sortedVideoInit.last.toString() : '0',
        'successCount': _videoSuccessCount,
        'failedCount': _videoFailedCount,
        'maxConcurrent': _videoMaxConcurrent,
      },
      'top10Slowest': withTotal.take(10).toList(),
      'bySource': _sourceStats.map((key, stats) => MapEntry(key, {
            'queueWaitSamples': stats.queueWaitMs.length,
            'queueWaitAvgMs': _fmt(_avg(stats.queueWaitMs)),
            'downloadAvgMs': _fmt(_avg(stats.downloadMs)),
            'decodeAvgMs': _fmt(_avg(stats.decodeMs)),
            'cacheHits': stats.cacheHits,
            'cacheMisses': stats.cacheMisses,
            'hitRate': (stats.cacheHits + stats.cacheMisses) > 0
                ? _pct(stats.cacheHits / (stats.cacheHits + stats.cacheMisses))
                : 0,
          })),
    };
  }

  static String dumpReport() {
    if (!enabled) return 'SlideProfiler: disabled';
    final d = dumpJson();
    final buf = StringBuffer();
    buf.writeln('══════════════════════════════════════════');
    buf.writeln('  SLIDESHOW PROFILER REPORT');
    buf.writeln('  Source: ${d['sourceType']}');
    buf.writeln('══════════════════════════════════════════');

    // Pipeline
    final p = d['pipeline'] as Map;
    buf.writeln('\n── Pipeline ──');
    buf.writeln('  First page load:  ${p['firstPageLoadMs']}ms');
    if (p['pipelineDurationMs'] != null) {
      buf.writeln('  Total duration:   ${p['pipelineDurationMs']}ms');
    }

    // Workers
    final w = d['workers'] as Map;
    buf.writeln('\n── Workers ──');
    buf.writeln(
        '  ${w['average']} / ${w['maxConfigured']} avg (peak: ${w['peak']})');
    buf.writeln('  Utilization:  ${w['utilizationPercent']}%');
    buf.writeln('  Idle:         ${w['idlePercent']}%');
    buf.writeln('  Samples:      ${w['samples']}');

    // Queue
    final q = d['queue'] as Map;
    buf.writeln('\n── Queue ──');
    buf.writeln('  Avg length:   ${q['lengthAverage']} (max: ${q['lengthMax']})');
    buf.writeln('  Total enq:    ${q['totalEnqueued']}');
    buf.writeln('  Wait avg:     ${q['waitAverageMs']}ms');
    buf.writeln('  Wait median:  ${q['waitMedianMs']}ms');
    buf.writeln('  Wait p95:     ${q['waitP95Ms']}ms');
    buf.writeln('  Wait max:     ${q['waitMaxMs']}ms');

    // State transitions
    final st = d['images']['stateTransitions'] as Map;
    buf.writeln('\n── State Transitions ──');
    for (final entry in st.entries) {
      buf.writeln('  ${entry.key}: ${entry.value}');
    }

    // Preparing duration
    final pd = d['images']['preparingDurationMs'] as Map;
    buf.writeln('\n── Preparing Duration (download + decode) ──');
    buf.writeln('  Samples:  ${pd['samples']}');
    buf.writeln('  Avg:      ${pd['average']}ms');
    buf.writeln('  Median:   ${pd['median']}ms');
    buf.writeln('  P95:      ${pd['p95']}ms');
    buf.writeln('  Max:      ${pd['max']}ms');

    // Cache
    final ic = d['imageCache'] as Map;
    buf.writeln('\n── ImageCache ──');
    buf.writeln('  Hits:       ${ic['hits']}');
    buf.writeln('  Misses:     ${ic['misses']}');
    buf.writeln('  Hit rate:   ${ic['hitRate']}%');
    buf.writeln('  Duplicate providers: ${ic['duplicateProviders']}');

    // Widget
    final wd = d['widget'] as Map;
    buf.writeln('\n── Widget Rebuilds ──');
    buf.writeln('  PageView builds:       ${wd['pageViewBuilds']}');
    buf.writeln('  ImageViewer builds:    ${wd['imageViewerBuilds']}');
    buf.writeln('  getPreparedHandle:     ${wd['getPreparedHandleCalls']}');
    buf.writeln('  preparationRevision:   ${wd['preparationRevisionChanges']}');

    // Video
    final vd = d['video'] as Map;
    buf.writeln('\n── Video ──');
    buf.writeln('  Init avg:  ${vd['initAverageMs']}ms');
    buf.writeln('  Init p95:  ${vd['initP95Ms']}ms');
    buf.writeln('  Init max:  ${vd['initMaxMs']}ms');
    buf.writeln('  Success:   ${vd['successCount']}');
    buf.writeln('  Failed:    ${vd['failedCount']}');
    buf.writeln('  Max concurrent: ${vd['maxConcurrent']}');

    // Top 10 slowest
    final top = d['top10Slowest'] as List;
    buf.writeln('\n── Top 10 Slowest Images ──');
    buf.writeln(
        '  #  queueMs  dlDecodeMs  readyLat  totalMs  cached  size  assetId');
    for (int i = 0; i < top.length; i++) {
      final t = top[i] as Map;
      buf.writeln(
        '  ${i + 1}. ${_pad(t['queueWaitMs']?.toString() ?? '-', 7)}  '
        '${_pad(t['downloadDecodeMs']?.toString() ?? '-', 10)}  '
        '${_pad(t['readyLatencyMs']?.toString() ?? '-', 8)}  '
        '${_pad(t['totalLatencyMs']?.toString() ?? '-', 7)}  '
        '${t['wasCached'] == true ? "YES" : "NO "}  '
        '${_pad(t['downloadSizeBytes']?.toString() ?? '-', 6)}  '
        '${t['assetId'] ?? "?"}',
      );
    }

    // By source comparison
    final bs = d['bySource'] as Map;
    buf.writeln('\n── By Source Type ──');
    for (final entry in bs.entries) {
      final v = entry.value as Map;
      buf.writeln('  ${entry.key}:');
      buf.writeln(
          '    queueWait=${v['queueWaitAvgMs']}ms  download=${v['downloadAvgMs']}ms  '
          'decode=${v['decodeAvgMs']}ms  hitRate=${v['hitRate']}%');
    }

    buf.writeln('\n══════════════════════════════════════════');
    return buf.toString();
  }

  static String _pad(String s, int width) {
    if (s.length >= width) return s;
    return ' ' * (width - s.length) + s;
  }

  static void reset() {
    _workerSamples = 0;
    _workerAccumulator = 0;
    _workerMax = 0;
    _workerIdleSamples = 0;
    _workerTimeline.clear();
    _queueLengthSamples = 0;
    _queueLengthAccumulator = 0;
    _queueLengthMax = 0;
    _queueEntryMs.clear();
    _queueWaitMs.clear();
    _totalEnqueued = 0;
    _totalDequeued = 0;
    _timelines.clear();
    _urlOrder.clear();
    _cacheHits = 0;
    _cacheMisses = 0;
    _seenProviders.clear();
    _duplicateProviders = 0;
    _imageViewerBuilds = 0;
    _pageViewBuilds = 0;
    _getPreparedHandleCalls = 0;
    _preparationRevisionChanges = 0;
    _pipelineStartMs = null;
    _pipelineEndMs = null;
    _firstPageLoadMs = 0;
    _videoInits.clear();
    _videoConcurrentPreps = 0;
    _videoMaxConcurrent = 0;
    _videoInitDurationsMs.clear();
    _videoSuccessCount = 0;
    _videoFailedCount = 0;
    _stateQueuedCount = 0;
    _statePreparingCount = 0;
    _stateReadyCount = 0;
    _stateFailedCount = 0;
    _stateNotRequestedCount = 0;
    _preparingDurationsMs.clear();
    for (final stats in _sourceStats.values) {
      stats.reset();
    }
  }
}

class _SourceStats {
  final String label;
  final List<int> queueWaitMs = [];
  final List<int> downloadMs = [];
  final List<int> decodeMs = [];
  int cacheHits = 0;
  int cacheMisses = 0;

  _SourceStats(this.label);

  void reset() {
    queueWaitMs.clear();
    downloadMs.clear();
    decodeMs.clear();
    cacheHits = 0;
    cacheMisses = 0;
  }
}
