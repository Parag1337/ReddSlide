import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import '../../feed/domain/media_asset.dart';
import '../../../core/display_quality/display_quality_mode.dart';
import '../../../core/display_quality/image_decode_policy.dart';
import 'adaptive_preloader.dart';
import 'metrics_collector.dart';
import 'playlist_manager.dart';
import 'preparation_policy.dart';
import 'prepared_media_handle.dart';
import 'video_preparation_service.dart';

class MediaPreparationEngine {
  final PlaylistManager _playlist;
  final LoadMoreCallback _onLoadMore;
  final PreparationPolicy _policy;
  final VideoPreparationService _videoService = VideoPreparationService();
  AdaptivePreloader? _preloader;
  DecodeSize? _defaultDecodeSize;
  MetricsCollector? metrics;

  int _lastReconciledIndex = -1;
  final Set<String> _preparedItemIds = {};
  final Set<String> _confirmedReadyUrls = {};
  final Set<String> _preparingUrls = {};
  static const int _maxConfirmedReadyUrls = 1000;

  void _onUrlStarted(String url) {
    _preparingUrls.add(url);
  }

  void _onUrlReady(String url) {
    _preparingUrls.remove(url);
    _confirmedReadyUrls.add(url);
    if (_confirmedReadyUrls.length > _maxConfirmedReadyUrls) {
      final excess = _confirmedReadyUrls.length - _maxConfirmedReadyUrls;
      final toRemove = _confirmedReadyUrls.take(excess).toList();
      _confirmedReadyUrls.removeAll(toRemove);
    }
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
    _preloader = AdaptivePreloader(
      playlist: _playlist,
      onLoadMore: _onLoadMore,
      context: context,
      metrics: metrics,
      displayQualityMode: displayQualityMode,
    )
      ..onUrlReady = _onUrlReady
      ..onUrlStarted = _onUrlStarted;
    if (onReadinessChanged != null) {
      _videoService.onReadinessChanged = onReadinessChanged;
    }
  }

  void onPlaylistChanged() {
    if (_lastReconciledIndex >= 0) {
      _reconcilePreparationWindow(_lastReconciledIndex);
    }
  }

  void onIndexChanged(int currentIndex) {
    _preloader?.onIndexChanged(currentIndex);
    if (currentIndex == _lastReconciledIndex) return;
    _lastReconciledIndex = currentIndex;
    _reconcilePreparationWindow(currentIndex);
  }

  void _reconcilePreparationWindow(int currentIndex) {
    final items = _playlist.items;
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
        _videoService.prepare(item.videoUrl!, priority: distance).then((_) {}, onError: (_) {});
      }
    }

    final beforeRetain = _preparedItemIds.length;
    _preparedItemIds.retainWhere(inWindow.contains);
    final evictedCount = beforeRetain - _preparedItemIds.length;
    _preparedItemIds.addAll(inWindow);

    _videoService.evictOutsideWindow(videoUrlsInWindow);

    metrics?.recordEvent(MetricEventType.prepWindowReconciled, data: {
      'currentIndex': currentIndex,
      'windowStart': windowStart,
      'windowEnd': windowEnd,
      'inWindowSize': inWindow.length,
      'preparedItemIds': _preparedItemIds.length,
      'evictedFromIds': evictedCount,
    });
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
      if (_confirmedReadyUrls.contains(url)) {
        state = MediaState.ready;
      } else if (_preparingUrls.contains(url)) {
        state = MediaState.preparing;
      } else if (_preparedItemIds.contains(asset.id)) {
        state = MediaState.queued;
      } else {
        state = MediaState.notRequested;
      }
    }

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

  void dispose() {
    if (_preparedItemIds.isNotEmpty) {
      metrics?.recordEvent(MetricEventType.preparationCancelled, data: {
        'preparedItemCount': _preparedItemIds.length,
        'reason': 'engineDisposed',
      });
    }
    _preloader?.dispose();
    _preloader = null;
    _videoService.dispose();
    _preparedItemIds.clear();
    _confirmedReadyUrls.clear();
    _preparingUrls.clear();
    _lastReconciledIndex = -1;
  }
}
