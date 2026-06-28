import 'dart:async' show TimeoutException, unawaited;
import 'dart:collection';
import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/display_quality/display_quality_mode.dart';
import '../../../core/display_quality/image_decode_policy.dart';
import '../../feed/domain/media_asset.dart';
import 'metrics_collector.dart';
import 'playlist_manager.dart';
import 'slide_profiler.dart'; // TEMPORARY — Phase 7.2A

enum _PreloadPriority { urgent, high, medium, background }

class _PreloadTask {
  final String url;
  final _PreloadPriority priority;
  const _PreloadTask({required this.url, required this.priority});
}

class _LruSet {
  final LinkedHashSet<String> _set = LinkedHashSet<String>();
  final int maxSize;

  _LruSet({required this.maxSize});

  bool contains(String value) => _set.contains(value);

  void add(String value) {
    if (_set.length >= maxSize) {
      _set.remove(_set.first);
    }
    _set.add(value);
  }

  void remove(String value) => _set.remove(value);
  bool get isNotEmpty => _set.isNotEmpty;
  int get length => _set.length;
  void clear() => _set.clear();

  void touch(String value) {
    if (_set.contains(value)) {
      _set.remove(value);
      _set.add(value);
    }
  }
}

typedef LoadMoreCallback = Future<void> Function();

class AdaptivePreloader {
  final PlaylistManager _playlist;
  final LoadMoreCallback _onLoadMore;
  final BuildContext _context;

  final _LruSet _preloadedUrls = _LruSet(maxSize: AppConstants.preloadedUrlSetMaxSize);
  final Set<String> _activeUrls = {};
  final Set<String> _failedUrls = {};
  int _inFlightPreloads = 0;
  final List<_PreloadTask> _preloadQueue = [];
  final Set<String> _queuedUrls = {};
  int _lastPreloadIndex = -1;
  static const int _maxConcurrentPreloads = AppConstants.maxConcurrentPreloads;

  MetricsCollector? metrics;
  void Function(String url)? onUrlReady;
  void Function(String url)? onUrlStarted;
  void Function(String url)? onUrlFailed;
  final DisplayQualityMode _displayQualityMode;
  final DecodeSize _decodeSize;

  AdaptivePreloader({
    required PlaylistManager playlist,
    required LoadMoreCallback onLoadMore,
    required BuildContext context,
    this.metrics,
    DisplayQualityMode displayQualityMode = DisplayQualityMode.smart,
  })  : _playlist = playlist,
        _onLoadMore = onLoadMore,
        _context = context,
        _displayQualityMode = displayQualityMode,
        _decodeSize = ImageDecodePolicy.fromContext(
          context: context,
          mode: displayQualityMode,
        ).getDecodeSize();

  void dispose() {
    _preloadedUrls.clear();
    _activeUrls.clear();
    _failedUrls.clear();
    _preloadQueue.clear();
    _queuedUrls.clear();
  }

  bool get isIdle => _inFlightPreloads == 0 && _preloadQueue.isEmpty;

  Set<String> get plannedUrls {
    final urls = <String>{};
    urls.addAll(_queuedUrls);
    urls.addAll(_activeUrls);
    return urls;
  }

  void onIndexChanged(int currentIndex) {
    if (currentIndex == _lastPreloadIndex) return;
    _lastPreloadIndex = currentIndex;

    final items = _playlist.items;
    if (items.isEmpty) return;

    final remaining = items.length - currentIndex;
    log('[PRELOAD] index=$currentIndex remaining=$remaining active=$_inFlightPreloads queued=${_preloadQueue.length} completed=${_preloadedUrls.length}');

    final windowWide = remaining >= 40;
    final highRange = windowWide ? 12 : (remaining < 15 ? 6 : 8);

    final current = items[currentIndex];
    for (final url in _imageUrls(current)) {
      _enqueueUrl(url, _PreloadPriority.urgent, assetId: current.id);
    }
    if (current.isGallery && current.galleryUrls != null) {
      for (final url in current.galleryUrls!) {
        _enqueueUrl(url, _PreloadPriority.high, assetId: current.id);
      }
    }

    int urgentCount = 0;
    for (int i = currentIndex + 1; i <= currentIndex + highRange && i < items.length; i++) {
      final asset = items[i];
      for (final url in _imageUrls(asset)) {
        _enqueueUrl(url, _PreloadPriority.urgent, assetId: asset.id);
        urgentCount++;
      }
    }

    final medRangeTop = currentIndex + highRange + (windowWide ? 10 : 6);
    int highCount = 0;
    for (int i = currentIndex + highRange + 1; i <= medRangeTop && i < items.length; i++) {
      final asset = items[i];
      for (final url in _imageUrls(asset)) {
        _enqueueUrl(url, _PreloadPriority.high, assetId: asset.id);
        highCount++;
      }
    }

    int medCount = 0;
    final farEnd = currentIndex + AppConstants.tier1PreloadCount + AppConstants.tier2PreloadCount;
    for (int i = medRangeTop + 1; i <= farEnd && i < items.length; i++) {
      final asset = items[i];
      for (final url in _imageUrls(asset)) {
        _enqueueUrl(url, _PreloadPriority.medium, assetId: asset.id);
        medCount++;
      }
    }

    int histCount = 0;
    final histStart = currentIndex - AppConstants.historyCount;
    for (int i = currentIndex - 1; i >= histStart && i >= 0; i--) {
      final asset = items[i];
      for (final url in _imageUrls(asset)) {
        _enqueueUrl(url, _PreloadPriority.background, assetId: asset.id);
        histCount++;
      }
    }

    log('[PRELOAD_QUEUE] window=${windowWide ? "wide" : (remaining < 15 ? "tight" : "normal")} '
        'queued=${_preloadQueue.length} urgent=$urgentCount high=$highCount medium=$medCount history=$histCount');

    _pruneQueue(currentIndex);
    _processQueue();
    _checkLoadMore(currentIndex);
  }

  void _checkLoadMore(int currentIndex) {
    final remaining = _playlist.remainingCount;
    if (remaining <= AppConstants.preloadTriggerRemaining) {
      log('[PRELOAD_TRIGGER] remaining=$remaining threshold=${AppConstants.preloadTriggerRemaining} triggering loadMore');
      unawaited(_onLoadMore());
    }
  }

  void _enqueueUrl(String url, _PreloadPriority priority, {String? assetId}) {
    if (_preloadedUrls.contains(url)) {
      onUrlReady?.call(url);
      return;
    }
    if (_failedUrls.contains(url)) return;
    if (_activeUrls.contains(url)) return;
    if (_queuedUrls.contains(url)) return;
    _queuedUrls.add(url);
    SlideProfiler.recordQueueTimestamp(url, assetId); // TEMPORARY — Phase 7.2A
    final task = _PreloadTask(url: url, priority: priority);
    int insertAt = _preloadQueue.length;
    for (int i = 0; i < _preloadQueue.length; i++) {
      if (_preloadQueue[i].priority.index > priority.index) {
        insertAt = i;
        break;
      }
    }
    _preloadQueue.insert(insertAt, task);
  }

  void _processQueue() {
    SlideProfiler.sampleWorkers(_inFlightPreloads, _maxConcurrentPreloads); // TEMPORARY — Phase 7.2A
    SlideProfiler.sampleQueueLength(_preloadQueue.length); // TEMPORARY — Phase 7.2A
    while (_inFlightPreloads < _maxConcurrentPreloads && _preloadQueue.isNotEmpty) {
      final task = _preloadQueue.removeAt(0);
      _queuedUrls.remove(task.url);
      SlideProfiler.recordQueueExit(task.url); // TEMPORARY — Phase 7.2A
      _activeUrls.add(task.url);
      _inFlightPreloads++;
      unawaited(_executePreload(task.url));
    }
    log('[PRELOAD_STATS] queued=${_queuedUrls.length} '
        'active=$_inFlightPreloads completed=${_preloadedUrls.length}');
  }

  void _pruneQueue(int currentIndex) {
    final items = _playlist.items;
    if (items.isEmpty) return;

    final farEnd = currentIndex + AppConstants.tier1PreloadCount + AppConstants.tier2PreloadCount;
    final histStart = (currentIndex - AppConstants.historyCount - 5).clamp(0, items.length);
    final keepEnd = (farEnd + 5).clamp(0, items.length);

    final keepUrls = <String>{};
    for (int i = histStart; i < keepEnd && i < items.length; i++) {
      keepUrls.addAll(_imageUrls(items[i]));
    }

    final before = _preloadQueue.length;
    _preloadQueue.removeWhere((task) {
      if (keepUrls.contains(task.url)) return false;
      if (_preloadedUrls.contains(task.url)) return false;
      if (_activeUrls.contains(task.url)) return false;
      _queuedUrls.remove(task.url);
      return true;
    });
    final pruned = before - _preloadQueue.length;
    if (pruned > 0) {
      log('[PRELOAD_PRUNE] removed=$pruned keepEnd=$keepEnd histStart=$histStart');
    }
  }

  Future<void> _executePreload(String url) async {
    log('[PRELOAD_START] url=$url active=$_inFlightPreloads');
    SlideProfiler.recordPreparingTimestamp(url, null); // TEMPORARY — Phase 7.2A
    onUrlStarted?.call(url);
    try {
      metrics?.recordEvent(MetricEventType.imagePreparationStarted, data: {'url': url});
      SlideProfiler.recordDownloadStart(url); // TEMPORARY — Phase 7.2A
      await precacheImage(
        ResizeImage.resizeIfNeeded(
          _decodeSize.width,
          _decodeSize.height,
          CachedNetworkImageProvider(url),
        ),
        _context,
      ).timeout(Duration(milliseconds: AppConstants.imagePreloadTimeoutMs));
      SlideProfiler.recordDownloadComplete(url); // TEMPORARY — Phase 7.2A
      _preloadedUrls.add(url);
      SlideProfiler.recordReady(url); // TEMPORARY — Phase 7.2A
      onUrlReady?.call(url);
      metrics?.recordEvent(MetricEventType.imagePreparationCompleted, data: {'url': url});
      log('[PRELOAD_DONE] url=$url');
    } on TimeoutException catch (e) {
      _failedUrls.add(url);
      SlideProfiler.recordImageError(url, 'Timeout: $e'); // TEMPORARY — Phase 7.2A
      onUrlFailed?.call(url);
      metrics?.recordEvent(MetricEventType.imagePreparationFailed, data: {
        'url': url,
        'error': 'timeout',
        'timeoutMs': AppConstants.imagePreloadTimeoutMs,
      });
      log('[PRELOAD_TIMEOUT] url=$url timeout=${AppConstants.imagePreloadTimeoutMs}ms');
    } catch (e) {
      _failedUrls.add(url);
      SlideProfiler.recordImageError(url, e.toString()); // TEMPORARY — Phase 7.2A
      onUrlFailed?.call(url);
      metrics?.recordEvent(MetricEventType.imagePreparationFailed, data: {'url': url, 'error': e.toString()});
      log('[PRELOAD_FAILED] url=$url error=$e');
    } finally {
      _activeUrls.remove(url);
      _inFlightPreloads--;
      _processQueue();
    }
  }

  List<String> _allAssetUrls(MediaAsset asset, {bool includeVideo = false}) {
    final urls = <String>[
      asset.mediaUrl,
      if (asset.isGallery && asset.galleryUrls != null) ...asset.galleryUrls!,
      if (includeVideo && asset.videoUrl != null) asset.videoUrl!,
    ];
    return urls;
  }

  List<String> _imageUrls(MediaAsset asset) {
    if (asset.isGallery && asset.galleryUrls != null) {
      return [...asset.galleryUrls!];
    }
    if (asset.isVideo && asset.thumbnailUrl != null) {
      return [asset.thumbnailUrl!];
    }
    return [asset.mediaUrl];
  }
}
