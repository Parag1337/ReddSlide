import 'dart:async' show unawaited;
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
  int _inFlightPreloads = 0;
  final List<_PreloadTask> _preloadQueue = [];
  final Set<String> _queuedUrls = {};
  int _lastPreloadIndex = -1;
  static const int _maxConcurrentPreloads = AppConstants.maxConcurrentPreloads;

  MetricsCollector? metrics;
  void Function(String url)? onUrlReady;
  void Function(String url)? onUrlStarted;
  final DisplayQualityMode _displayQualityMode;

  AdaptivePreloader({
    required PlaylistManager playlist,
    required LoadMoreCallback onLoadMore,
    required BuildContext context,
    this.metrics,
    DisplayQualityMode displayQualityMode = DisplayQualityMode.smart,
  })  : _playlist = playlist,
        _onLoadMore = onLoadMore,
        _context = context,
        _displayQualityMode = displayQualityMode;

  void dispose() {
    _preloadedUrls.clear();
    _activeUrls.clear();
    _preloadQueue.clear();
    _queuedUrls.clear();
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
    for (final url in _allAssetUrls(current, includeVideo: true)) {
      _enqueueUrl(url, _PreloadPriority.urgent);
    }
    if (current.isGallery && current.galleryUrls != null) {
      for (final url in current.galleryUrls!) {
        _enqueueUrl(url, _PreloadPriority.high);
      }
    }

    int urgentCount = 0;
    for (int i = currentIndex + 1; i <= currentIndex + highRange && i < items.length; i++) {
      final asset = items[i];
      for (final url in _imageUrls(asset)) {
        _enqueueUrl(url, _PreloadPriority.urgent);
        urgentCount++;
      }
    }

    final medRangeTop = currentIndex + highRange + (windowWide ? 10 : 6);
    int highCount = 0;
    for (int i = currentIndex + highRange + 1; i <= medRangeTop && i < items.length; i++) {
      final asset = items[i];
      for (final url in _imageUrls(asset)) {
        _enqueueUrl(url, _PreloadPriority.high);
        highCount++;
      }
    }

    int medCount = 0;
    final farEnd = currentIndex + AppConstants.tier1PreloadCount + AppConstants.tier2PreloadCount;
    for (int i = medRangeTop + 1; i <= farEnd && i < items.length; i++) {
      final asset = items[i];
      for (final url in _imageUrls(asset)) {
        _enqueueUrl(url, _PreloadPriority.medium);
        medCount++;
      }
    }

    int histCount = 0;
    final histStart = currentIndex - AppConstants.historyCount;
    for (int i = currentIndex - 1; i >= histStart && i >= 0; i--) {
      final asset = items[i];
      for (final url in _imageUrls(asset)) {
        _enqueueUrl(url, _PreloadPriority.background);
        histCount++;
      }
    }

    log('[PRELOAD_QUEUE] window=${windowWide ? "wide" : (remaining < 15 ? "tight" : "normal")} '
        'queued=${_preloadQueue.length} urgent=$urgentCount high=$highCount medium=$medCount history=$histCount');

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

  void _enqueueUrl(String url, _PreloadPriority priority) {
    if (_preloadedUrls.contains(url)) {
      onUrlReady?.call(url);
      return;
    }
    if (_activeUrls.contains(url)) return;
    if (_queuedUrls.contains(url)) return;
    _queuedUrls.add(url);
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
    while (_inFlightPreloads < _maxConcurrentPreloads && _preloadQueue.isNotEmpty) {
      final task = _preloadQueue.removeAt(0);
      _queuedUrls.remove(task.url);
      _activeUrls.add(task.url);
      _inFlightPreloads++;
      unawaited(_executePreload(task.url));
    }
    log('[PRELOAD_STATS] queued=${_queuedUrls.length} '
        'active=$_inFlightPreloads completed=${_preloadedUrls.length}');
  }

  Future<void> _executePreload(String url) async {
    log('[PRELOAD_START] url=$url active=$_inFlightPreloads');
    onUrlStarted?.call(url);
    try {
      metrics?.recordEvent(MetricEventType.imagePreparationStarted, data: {'url': url});
      final policy = ImageDecodePolicy.fromContext(
        context: _context,
        mode: _displayQualityMode,
      );
      final decodeSize = policy.getDecodeSize();
      await precacheImage(
        ResizeImage.resizeIfNeeded(
          decodeSize.width,
          decodeSize.height,
          CachedNetworkImageProvider(url),
        ),
        _context,
      );
      _preloadedUrls.add(url);
      onUrlReady?.call(url);
      metrics?.recordEvent(MetricEventType.imagePreparationCompleted, data: {'url': url});
      log('[PRELOAD_DONE] url=$url');
    } catch (e) {
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
