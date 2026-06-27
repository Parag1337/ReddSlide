import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import '../../feed/domain/media_asset.dart';
import 'adaptive_preloader.dart';
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

  int _lastReconciledIndex = -1;
  final Set<String> _preparedItemIds = {};

  MediaPreparationEngine({
    required PlaylistManager playlist,
    required LoadMoreCallback onLoadMore,
    PreparationPolicy? policy,
  })  : _playlist = playlist,
        _onLoadMore = onLoadMore,
        _policy = policy ?? const PreparationPolicy();

  void attachContext(BuildContext context, {VoidCallback? onReadinessChanged}) {
    _preloader = AdaptivePreloader(
      playlist: _playlist,
      onLoadMore: _onLoadMore,
      context: context,
    );
    if (onReadinessChanged != null) {
      _videoService.onReadinessChanged = onReadinessChanged;
    }
  }

  void initialize() {}

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
        videoUrlsInWindow.add(item.videoUrl!);
        _videoService.prepare(item.videoUrl!).then((_) {}, onError: (_) {});
      }
    }

    _preparedItemIds.retainWhere(inWindow.contains);
    _preparedItemIds.addAll(inWindow);

    _videoService.evictOutsideWindow(videoUrlsInWindow);
  }

  PreparedMediaHandle prepare(MediaAsset asset, {int galleryIndex = 0}) {
    String resolvedUrl;
    if (asset.isGallery && asset.galleryUrls != null && asset.galleryUrls!.isNotEmpty) {
      resolvedUrl = asset.galleryUrls![galleryIndex.clamp(0, asset.galleryUrls!.length - 1)];
    } else {
      resolvedUrl = asset.mediaUrl;
    }

    VideoPlayerController? controller;
    bool preparationFailed = false;
    if (asset.isVideo && asset.videoUrl != null) {
      controller = _videoService.getController(asset.videoUrl!);
      preparationFailed = _videoService.hasFailed(asset.videoUrl!);
    }

    return PreparedMediaHandle(
      asset: asset.copyWith(mediaUrl: resolvedUrl),
      ready: isReady(asset),
      controller: controller,
      preparationFailed: preparationFailed,
    );
  }

  bool isReady(MediaAsset asset) {
    if (!_preparedItemIds.contains(asset.id)) return false;

    if (asset.isVideo) {
      return asset.videoUrl != null && _videoService.isReady(asset.videoUrl!);
    }

    if (asset.isGallery && asset.galleryUrls != null && asset.galleryUrls!.isNotEmpty) {
      return asset.galleryUrls!.every((url) => _isImageCached(url));
    }

    return _isImageCached(asset.mediaUrl);
  }

  bool _isImageCached(String url) {
    try {
      final cacheKey = CachedNetworkImageProvider(url).cacheKey;
      return cacheKey != null && PaintingBinding.instance.imageCache.containsKey(cacheKey);
    } catch (_) {
      return false;
    }
  }

  void dispose() {
    _preloader?.dispose();
    _preloader = null;
    _videoService.dispose();
    _preparedItemIds.clear();
    _lastReconciledIndex = -1;
  }
}
