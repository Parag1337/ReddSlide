import 'package:flutter/material.dart';
import '../../../core/display_quality/display_quality_mode.dart';
import 'adaptive_preloader.dart';
import 'playlist_manager.dart';
import 'preparation_scheduler.dart';

class AdaptivePreloaderScheduler implements PreparationScheduler {
  final AdaptivePreloader _preloader;

  AdaptivePreloaderScheduler({
    required PlaylistManager playlist,
    required LoadMoreCallback onLoadMore,
    required BuildContext context,
    DisplayQualityMode displayQualityMode = DisplayQualityMode.smart,
  }) : _preloader = AdaptivePreloader(
          playlist: playlist,
          onLoadMore: onLoadMore,
          context: context,
          displayQualityMode: displayQualityMode,
        );

  @override
  void Function(String url)? get onUrlStarted => _preloader.onUrlStarted;
  @override
  set onUrlStarted(void Function(String url)? cb) {
    _preloader.onUrlStarted = cb;
  }

  @override
  void Function(String url)? get onUrlReady => _preloader.onUrlReady;
  @override
  set onUrlReady(void Function(String url)? cb) {
    _preloader.onUrlReady = cb;
  }

  @override
  void Function(String url)? get onUrlFailed => _preloader.onUrlFailed;
  @override
  set onUrlFailed(void Function(String url)? cb) {
    _preloader.onUrlFailed = cb;
  }

  @override
  void onIndexChanged(int currentIndex, {int galleryIndex = 0}) {
    _preloader.onIndexChanged(currentIndex);
  }

  @override
  void onPlaylistReplaced() {}

  @override
  Set<String> get plannedUrls => _preloader.plannedUrls;

  @override
  bool get isIdle => _preloader.isIdle;

  @override
  bool get hasFailed => false;

  @override
  void dispose() => _preloader.dispose();
}
