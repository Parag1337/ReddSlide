import 'dart:developer';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import '../../feed/domain/media_asset.dart';
import '../../../core/debug/trace.dart';
import '../../../core/display_quality/display_quality_mode.dart';
import '../../../core/display_quality/image_decode_policy.dart';
import 'adaptive_preloader.dart';
import 'adaptive_preloader_scheduler.dart';
import 'metrics_collector.dart';
import 'playlist_manager.dart';
import 'preparation_policy.dart';
import 'preparation_scheduler.dart';
import 'prepared_media_handle.dart';
import 'readiness_state.dart';
import 'scheduler_mode.dart';
import 'shadow_scheduler.dart';
import 'slide_profiler.dart';
import 'video_preparation_service.dart';
import 'viewport_scheduler_adapter.dart';

class MediaPreparationEngine {
  final PlaylistManager _playlist;
  final LoadMoreCallback _onLoadMore;
  final PreparationPolicy _policy;
  final VideoPreparationService _videoService = VideoPreparationService();
  PreparationScheduler? _activeScheduler;
  AdaptivePreloaderScheduler? _adaptiveScheduler;
  ViewportSchedulerAdapter? _viewportScheduler;
  DecodeSize? _defaultDecodeSize;
  MetricsCollector? metrics;

  int _lastReconciledIndex = -1;
  final Set<String> _preparedItemIds = {};
  final Set<String> _confirmedReadyUrls = {};
  final Set<String> _preparingUrls = {};
  final Set<String> _failedUrls = {};
  static const int _maxConfirmedReadyUrls = 1000;
  VoidCallback? _onReadinessChanged;
  Set<String>? _pendingEvictionUrls;
  bool _evictionScheduled = false;

  final ShadowScheduler _shadowScheduler = ShadowScheduler();
  final ShadowMetricsAggregator shadowAggregator = ShadowMetricsAggregator();

  void _onUrlStarted(String url) {
    _preparingUrls.add(url);
    Trace.t('MPE._onUrlStarted', ['url', url.substring(0, url.length.clamp(0, 60)), 'preparing', _preparingUrls.length]);
    _onReadinessChanged?.call();
  }

  void _onUrlReady(String url) {
    _preparingUrls.remove(url);
    _confirmedReadyUrls.add(url);
    if (_confirmedReadyUrls.length > _maxConfirmedReadyUrls) {
      final excess = _confirmedReadyUrls.length - _maxConfirmedReadyUrls;
      final toRemove = _confirmedReadyUrls.take(excess).toList();
      _confirmedReadyUrls.removeAll(toRemove);
    }
    Trace.t('MPE._onUrlReady', ['url', url.substring(0, url.length.clamp(0, 60)), 'confirmed', _confirmedReadyUrls.length]);
    _onReadinessChanged?.call();
  }

  void _onUrlFailed(String url) {
    _preparingUrls.remove(url);
    _failedUrls.add(url);
    Trace.t('MPE._onUrlFailed', ['url', url.substring(0, url.length.clamp(0, 60)), 'failed', _failedUrls.length]);
    _onReadinessChanged?.call();
  }

  MediaPreparationEngine({
    required PlaylistManager playlist,
    required LoadMoreCallback onLoadMore,
    PreparationPolicy? policy,
  })  : _playlist = playlist,
        _onLoadMore = onLoadMore,
        _policy = policy ?? const PreparationPolicy();

  void attachContext(
    BuildContext context, {
    VoidCallback? onReadinessChanged,
    DisplayQualityMode displayQualityMode = DisplayQualityMode.smart,
  }) {
    _videoService.metrics = metrics;
    final policy = ImageDecodePolicy.fromContext(
      context: context,
      mode: displayQualityMode,
    );
    _defaultDecodeSize = policy.getDecodeSize();
    _onReadinessChanged = onReadinessChanged;

    _wireSchedulerCallbacks(_adaptiveScheduler = AdaptivePreloaderScheduler(
      playlist: _playlist,
      onLoadMore: _onLoadMore,
      context: context,
      displayQualityMode: displayQualityMode,
    ));

    _wireSchedulerCallbacks(_viewportScheduler = ViewportSchedulerAdapter(
      playlist: _playlist,
      onLoadMore: _onLoadMore,
      context: context,
      measureWindow: measureWindow,
    ));

    if (isViewportSchedulerEnabled) {
      _activeScheduler = _viewportScheduler;
    } else {
      _activeScheduler = _adaptiveScheduler;
    }

    if (onReadinessChanged != null) {
      _videoService.onReadinessChanged = onReadinessChanged;
    }
  }

  void _wireSchedulerCallbacks(PreparationScheduler scheduler) {
    scheduler.onUrlStarted = _onUrlStarted;
    scheduler.onUrlReady = _onUrlReady;
    scheduler.onUrlFailed = _onUrlFailed;
  }

  void onPlaylistChanged() {
    if (_lastReconciledIndex >= 0) {
      _reconcilePreparationWindow(_lastReconciledIndex);
    }
  }

  void onPlaylistReplaced() {
    _activeScheduler?.onPlaylistReplaced();
    _lastReconciledIndex = -1;
  }

  void onIndexChanged(int currentIndex, {int galleryIndex = 0}) {
    Trace.t('MPE.onIndexChanged', ['index', currentIndex, 'gallery', galleryIndex]);
    _checkFallback();

    try {
      _activeScheduler?.onIndexChanged(
        currentIndex,
        galleryIndex: galleryIndex,
      );
    } catch (e) {
      log('[MediaPreparationEngine] Scheduler error: $e');
      _fallbackToAdaptive();
      _activeScheduler?.onIndexChanged(currentIndex);
    }

    SlideProfiler.recordSchedulerInfo(
      currentScheduler: _activeScheduler == _viewportScheduler
          ? 'viewport'
          : 'adaptive',
      schedulerMode: isViewportSchedulerEnabled ? 'viewport' : 'adaptive',
      needCount: 0,
      readyHorizon: 0,
      prepBudget: 0,
      generation: 0,
      pendingTasks: 0,
      completedTasks: 0,
      cancelledTasks: 0,
      ring0: 0,
      ring1: 0,
      ring2: 0,
      ring3: 0,
      isActive: _activeScheduler == _viewportScheduler,
      isSatisfied: false,
      isSleeping: false,
      isResuming: false,
    );

    _runShadowCycle(currentIndex);

    if (currentIndex == _lastReconciledIndex) return;
    _lastReconciledIndex = currentIndex;
    _reconcilePreparationWindow(currentIndex);
  }

  void _checkFallback() {
    if (_activeScheduler == _viewportScheduler &&
        _viewportScheduler != null &&
        _viewportScheduler!.hasFailed) {
      _fallbackToAdaptive();
    }
  }

  void _fallbackToAdaptive() {
    log('[MediaPreparationEngine] Falling back to AdaptivePreloader');
    _activeScheduler = _adaptiveScheduler;
  }

  void _runShadowCycle(int currentIndex) {
    if (_adaptiveScheduler == null) return;
    final states = measureWindow(currentIndex, _shadowScheduler.config.horizon);
    if (states.isEmpty) return;
    final result = _shadowScheduler.runCycle(
      states: states,
      items: _playlist.items,
      currentIndex: currentIndex,
      adaptivePlannedUrls: _adaptiveScheduler!.plannedUrls,
    );
    shadowAggregator.record(result);
    if (result.adaptiveUrls.isNotEmpty || result.viewportUrls.isNotEmpty) {
      final union = result.adaptiveUrls.union(result.viewportUrls);
      final intersection = result.adaptiveUrls.intersection(result.viewportUrls);
      final agreement = union.isEmpty ? 1.0 : intersection.length / union.length;
      SlideProfiler.recordSchedulerAgreement(agreement);
    }
  }

  void _reconcilePreparationWindow(int currentIndex) {
    final items = _playlist.items;
    Trace.t('MPE._reconcilePreparationWindow', ['index', currentIndex, 'items', items.length]);
    if (items.isEmpty) return;

    final windowStart = (currentIndex - _policy.decodedBehind).clamp(0, items.length);
    final windowEnd = (currentIndex + _policy.decodedAhead + 1).clamp(0, items.length);

    final inWindow = <String>{};
    final videoUrlsInWindow = <String>{};

    for (int i = windowStart; i < windowEnd && i < items.length; i++) {
      final item = items[i];
      inWindow.add(item.id);
      if (item.isVideo && item.videoUrl != null) {
        final distance = (i - currentIndex).abs();
        videoUrlsInWindow.add(item.videoUrl!);
        Trace.t('MPE._reconcilePreparationWindow.video', ['i', i, 'url', item.videoUrl!.substring(0, item.videoUrl!.length.clamp(0, 60)), 'dist', distance]);
        _videoService.prepare(item.videoUrl!, headers: item.mediaHeaders, priority: distance).then((_) {}, onError: (_) {});
      }
    }

    final beforeRetain = _preparedItemIds.length;
    _preparedItemIds.retainWhere(inWindow.contains);
    final evictedCount = beforeRetain - _preparedItemIds.length;
    _preparedItemIds.addAll(inWindow);

    _pendingEvictionUrls = videoUrlsInWindow;
    _scheduleEviction();

    metrics?.recordEvent(MetricEventType.prepWindowReconciled, data: {
      'currentIndex': currentIndex,
      'windowStart': windowStart,
      'windowEnd': windowEnd,
      'inWindowSize': inWindow.length,
      'preparedItemIds': _preparedItemIds.length,
      'evictedFromIds': evictedCount,
    });
  }

  void _scheduleEviction() {
    if (_evictionScheduled) return;
    _evictionScheduled = true;
    try {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _evictionScheduled = false;
        final urls = _pendingEvictionUrls;
        _pendingEvictionUrls = null;
        if (urls != null) {
          _videoService.evictOutsideWindow(urls);
        }
      });
    } catch (_) {
      _evictionScheduled = false;
      final urls = _pendingEvictionUrls;
      _pendingEvictionUrls = null;
      if (urls != null) {
        _videoService.evictOutsideWindow(urls);
      }
    }
  }

  PreparedMediaHandle prepare(MediaAsset asset, {int galleryIndex = 0}) {
    String resolvedUrl;
    if (asset.isGallery && asset.galleryUrls != null && asset.galleryUrls!.isNotEmpty) {
      resolvedUrl = asset.galleryUrls![galleryIndex.clamp(0, asset.galleryUrls!.length - 1)];
    } else {
      resolvedUrl = asset.mediaUrl;
    }

    if (!_preparedItemIds.contains(asset.id)) {
      metrics?.recordEvent(MetricEventType.outsideWindowMiss, data: {
        'assetId': asset.id,
        'preparedItemIds': _preparedItemIds.length,
      });
    }

    VideoPlayerController? controller;
    bool preparationFailed = false;
    MediaState state;

    if (asset.isVideo && asset.videoUrl != null) {
      controller = _videoService.getController(asset.videoUrl!);
      Trace.t('MPE.prepare.video', ['assetId', asset.id, 'ctrl', '${controller?.hashCode}', 'ctrlInit', '${controller?.value.isInitialized}', 'state', '${controller != null ? (_videoService.isReady(asset.videoUrl!) ? "ready" : _videoService.isPreparing(asset.videoUrl!) ? "preparing" : "unknown") : "no-entry"}']);
      preparationFailed = _videoService.hasFailed(asset.videoUrl!);
      if (preparationFailed) {
        state = MediaState.failed;
      } else if (controller != null) {
        state = MediaState.ready;
      } else if (_videoService.isPreparing(asset.videoUrl!)) {
        state = MediaState.preparing;
      } else {
        state = _preparedItemIds.contains(asset.id)
            ? MediaState.queued
            : MediaState.notRequested;
      }
    } else {
      final url = asset.isGallery && asset.galleryUrls != null && asset.galleryUrls!.isNotEmpty
          ? resolvedUrl
          : asset.mediaUrl;
      SlideProfiler.recordWidgetRequest(url); // TEMPORARY — Phase 7.2A
      if (_confirmedReadyUrls.contains(url)) {
        state = MediaState.ready;
      } else if (_preparingUrls.contains(url)) {
        state = MediaState.preparing;
      } else if (_failedUrls.contains(url)) {
        state = MediaState.failed;
      } else if (_preparedItemIds.contains(asset.id)) {
        state = MediaState.queued;
      } else {
        state = MediaState.notRequested;
      }
    }

    SlideProfiler.recordStateTransition(resolvedUrl, state.name); // TEMPORARY — Phase 7.2A

    return PreparedMediaHandle(
      asset: asset.copyWith(mediaUrl: resolvedUrl),
      state: state,
      controller: controller,
      preparationFailed: preparationFailed,
      decodeSize: _defaultDecodeSize,
    );
  }

  bool isReady(MediaAsset asset) {
    if (!_preparedItemIds.contains(asset.id)) return false;

    if (asset.isVideo) {
      return asset.videoUrl != null && _videoService.isReady(asset.videoUrl!);
    }

    if (asset.isGallery && asset.galleryUrls != null && asset.galleryUrls!.isNotEmpty) {
      return asset.galleryUrls!.every(_confirmedReadyUrls.contains);
    }

    return _confirmedReadyUrls.contains(asset.mediaUrl);
  }

  List<ReadinessState> measureWindow(int currentIndex, int horizon) {
    final items = _playlist.items;
    if (items.isEmpty || currentIndex >= items.length) return [];

    final end = (currentIndex + horizon + 1).clamp(0, items.length);
    return [for (int i = currentIndex; i < end; i++) _readinessOf(items[i])];
  }

  ReadinessState _readinessOf(MediaAsset asset) {
    if (asset.isVideo && asset.videoUrl != null) {
      if (_videoService.isReady(asset.videoUrl!)) return ReadinessState.ready;
      if (_videoService.isPreparing(asset.videoUrl!)) return ReadinessState.likelyReady;
      if (_videoService.hasFailed(asset.videoUrl!)) return ReadinessState.unavailable;
    }

    final urls = <String>[
      if (asset.isGallery && asset.galleryUrls != null) ...asset.galleryUrls!
      else if (asset.isVideo && asset.thumbnailUrl != null) asset.thumbnailUrl!
      else asset.mediaUrl,
    ];

    bool hasReady = false;
    bool hasLikely = false;

    for (final url in urls) {
      if (_confirmedReadyUrls.contains(url)) {
        hasReady = true;
      } else if (_preparingUrls.contains(url)) {
        hasLikely = true;
      } else if (_failedUrls.contains(url)) {
        // unavailable — handled by the else branch below
      } else if (_preparedItemIds.contains(asset.id)) {
        hasLikely = true;
      }
      // else: unavailable by default
    }

    if (hasReady && urls.every((u) => _confirmedReadyUrls.contains(u))) {
      return ReadinessState.ready;
    }
    if (hasReady || hasLikely) return ReadinessState.likelyReady;
    return ReadinessState.unavailable;
  }

  void dispose() {
    if (_preparedItemIds.isNotEmpty) {
      metrics?.recordEvent(MetricEventType.preparationCancelled, data: {
        'preparedItemCount': _preparedItemIds.length,
        'reason': 'engineDisposed',
      });
    }
    _pendingEvictionUrls = null;
    _evictionScheduled = false;
    _adaptiveScheduler?.dispose();
    _adaptiveScheduler = null;
    _viewportScheduler?.dispose();
    _viewportScheduler = null;
    _activeScheduler = null;
    _videoService.dispose();
    _preparedItemIds.clear();
    _confirmedReadyUrls.clear();
    _preparingUrls.clear();
    _failedUrls.clear();
    _lastReconciledIndex = -1;
  }
}
