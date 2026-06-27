import 'dart:async';
import 'dart:developer';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/media/media_source.dart';
import '../../feed/data/feed_repository.dart';
import '../../feed/domain/media_asset.dart';
import '../../search/data/search_repository.dart';
import '../../settings/providers/settings_provider.dart';
import '../data/search_media_source.dart';
import '../data/subreddit_media_source.dart';
import '../domain/media_preparation_engine.dart';
import '../domain/merge_engine.dart';
import '../domain/playlist_manager.dart';
import '../domain/prepared_media_handle.dart';
import '../domain/slideshow_source.dart';
import '../domain/slideshow_state.dart';

int _nextEventId = 0;
int _nextEvent() => ++_nextEventId;

final slideshowProvider = StateNotifierProvider.family<SlideshowNotifier, SlideshowState, SlideshowSource>(
  (ref, source) {
    final feedRepository = ref.watch(feedRepositoryProvider);
    final searchRepository = ref.watch(searchRepositoryProvider);
    final settings = ref.watch(settingsProvider).valueOrNull;
    return SlideshowNotifier(
      feedRepository: feedRepository,
      searchRepository: searchRepository,
      source: source,
      allSubreddits: settings?.subreddits ?? [],
    );
  },
);

class SlideshowNotifier extends StateNotifier<SlideshowState> {
  late final PlaylistManager _playlist;
  late final MergeEngine? _mergeEngine;
  MediaPreparationEngine? _preparationEngine;
  Timer? _autoAdvanceTimer;
  Timer? _overlayTimer;
  int _slideshowIntervalSeconds = AppConstants.defaultSlideshowIntervalSeconds;
  Future<void>? _inFlightLoadMore;

  SlideshowNotifier({
    required FeedRepository feedRepository,
    required SearchRepository searchRepository,
    required SlideshowSource source,
    required List<String> allSubreddits,
  }  ) : super(SlideshowState()) {
    _playlist = PlaylistManager();
    _mergeEngine = _buildMergeEngine(source, feedRepository, searchRepository, allSubreddits);
  }

  void attachPreparationEngine(BuildContext context) {
    if (_mergeEngine != null) {
      _preparationEngine = MediaPreparationEngine(
        playlist: _playlist,
        onLoadMore: loadMore,
      )..attachContext(context, onReadinessChanged: _onVideoReadinessChanged);
    }
  }

  PreparedMediaHandle getPreparedHandle(MediaAsset asset, {int galleryIndex = 0}) {
    return _preparationEngine?.prepare(asset, galleryIndex: galleryIndex) ?? PreparedMediaHandle(
      asset: asset,
      ready: false,
    );
  }

  void _onVideoReadinessChanged() {
    _syncState();
  }

  MergeEngine? _buildMergeEngine(
    SlideshowSource source,
    FeedRepository feedRepository,
    SearchRepository searchRepository,
    List<String> allSubreddits,
  ) {
    final sources = _buildMediaSources(source, feedRepository, searchRepository, allSubreddits);
    if (sources.isEmpty) return null;
    return MergeEngine(sources: sources);
  }

  List<MediaSource> _buildMediaSources(
    SlideshowSource source,
    FeedRepository feedRepository,
    SearchRepository searchRepository,
    List<String> allSubreddits,
  ) {
    return switch (source) {
      SubredditSource(:final subreddit, :final sortMode) => [
          SubredditMediaSource(
            repository: feedRepository,
            subreddit: subreddit,
            sortMode: sortMode,
          ),
        ],
      MultiSubredditSource(:final subreddits, :final sortMode) => subreddits.map((sub) =>
          SubredditMediaSource(
            repository: feedRepository,
            subreddit: sub,
            sortMode: sortMode,
          ),
        ).toList(),
      GlobalFeedSource() => allSubreddits.map((sub) =>
          SubredditMediaSource(
            repository: feedRepository,
            subreddit: sub,
          ),
        ).toList(),
      SearchSource(:final query, :final mode, :final subreddits) => [
          SearchMediaSource(
            repository: searchRepository,
            query: query,
            mode: mode,
            subreddits: subreddits,
          ),
        ],
      GroupSource(:final subreddits) => subreddits.map((sub) =>
          SubredditMediaSource(
            repository: feedRepository,
            subreddit: sub,
          ),
        ).toList(),
    };
  }

  Future<void> initialize() async {
    if (_mergeEngine == null) {
      state = state.copyWith(isLoading: false, hasMorePages: false);
      return;
    }

    state = state.copyWith(isLoading: true);
    final engine = _mergeEngine;
    try {
      await engine.initialize();
      final items = engine.drainMerged();
      _playlist.append(items);

      state = state.copyWith(
        items: _playlist.items,
        isLoading: false,
        hasMorePages: items.isNotEmpty,
      );

      if (items.isNotEmpty) {
        _startAutoAdvance();
      }
    } catch (e) {
      log('[SLIDESHOW] _initialize error=$e');
      state = state.copyWith(isLoading: false, hasMorePages: false);
    }
  }

  void setStartIndex(int index) {
    _playlist.jumpTo(index);
    state = state.copyWith(currentIndex: index);
  }

  void setInterval(int seconds) {
    _slideshowIntervalSeconds = seconds;
  }

  void debugDump() {
    debugPrint('[DEBUG_DUMP] items.length=${state.items.length} isLoading=${state.isLoading}');
    debugPrint('[DEBUG_DUMP] hasMorePages=${state.hasMorePages} currentIndex=${state.currentIndex}');
    debugPrint('[DEBUG_DUMP] _playlist.items=${_playlist.items.length} currentIndex=${_playlist.currentIndex}');
    final engine = _mergeEngine;
    if (engine != null) {
      debugPrint('[DEBUG_DUMP] MergeEngine buffers=${engine.buffers.length} '
          'merged=${engine.merged.length} hasMoreSources=${engine.hasMoreSources}');
      for (int i = 0; i < engine.buffers.length; i++) {
        final b = engine.buffers[i];
        debugPrint('[DEBUG_DUMP]   buffer[$i] items=${b.items.length} '
            'remaining=${b.remainingCount} hasMore=${b.hasMore} isLoading=${b.isLoading}');
      }
    }
  }

  Future<void> next({int eid = -1}) async {
    if (_playlist.isEmpty) return;
    if (eid == -1) eid = _nextEvent();

    final nextIndex = state.currentIndex + 1;
    if (nextIndex >= _playlist.length) {
      if (!state.isLoadingMore) {
        await loadMore();
      } else if (_inFlightLoadMore != null) {
        await _inFlightLoadMore;
      }
      if (_playlist.advance()) {
        _syncState();
      }
      _restartAutoAdvance();
      _notifyPreloader();
      return;
    }

    if (_playlist.next() != null) {
      _syncState();
      _restartAutoAdvance();
      _notifyPreloader();
    }
  }

  Future<void> previous({int eid = -1}) async {
    if (eid == -1) eid = _nextEvent();
    if (_playlist.previous() != null) {
      _syncState();
      _restartAutoAdvance();
      _notifyPreloader();
    }
  }

  Future<void> jumpTo(int index) async {
    if (index < 0 || index >= _playlist.length) return;
    _playlist.jumpTo(index);
    _syncState();
    _restartAutoAdvance();
    _notifyPreloader();
  }

  void togglePlay() {
    state = state.copyWith(isPlaying: !state.isPlaying);
    if (state.isPlaying) {
      _startAutoAdvance();
    } else {
      _cancelAutoAdvance();
    }
  }

  void toggleMute() {
    state = state.copyWith(isMuted: !state.isMuted);
  }

  void toggleFullscreen() {
    state = state.copyWith(isFullscreen: !state.isFullscreen);
    if (state.isFullscreen) {
      _startOverlayTimer();
    } else {
      state = state.copyWith(overlayVisible: true);
      _cancelOverlayTimer();
    }
  }

  void toggleOverlay() {
    state = state.copyWith(overlayVisible: !state.overlayVisible);
    if (state.overlayVisible && state.isFullscreen) {
      _startOverlayTimer();
    } else {
      _cancelOverlayTimer();
    }
  }

  void showOverlay() {
    state = state.copyWith(overlayVisible: true);
    if (state.isFullscreen) {
      _startOverlayTimer();
    }
  }

  void galleryNext() {
    if (_playlist.isEmpty) return;
    final asset = _playlist.current;
    if (asset == null) return;

    if (asset.isGallery && asset.galleryUrls != null && asset.galleryUrls!.isNotEmpty) {
      final maxIndex = asset.galleryUrls!.length - 1;
      if (state.gallerySubIndex < maxIndex) {
        state = state.copyWith(gallerySubIndex: state.gallerySubIndex + 1);
        _restartAutoAdvance();
        return;
      }
    }
    next();
  }

  void galleryPrevious() {
    if (_playlist.isEmpty) return;
    final asset = _playlist.current;
    if (asset == null) return;

    if (asset.isGallery && asset.galleryUrls != null && asset.galleryUrls!.isNotEmpty) {
      if (state.gallerySubIndex > 0) {
        state = state.copyWith(gallerySubIndex: state.gallerySubIndex - 1);
        _restartAutoAdvance();
        return;
      }
    }
    previous();
  }

  Future<void> loadMore() async {
    if (state.isLoadingMore || _mergeEngine == null) return;
    state = state.copyWith(isLoadingMore: true);
    _inFlightLoadMore = _doLoadMore();
    await _inFlightLoadMore;
    _inFlightLoadMore = null;
  }

  Future<void> _doLoadMore() async {
    final engine = _mergeEngine;
    if (engine == null) return;
    final beforeCount = _playlist.length;

    await engine.autoRefill();
    final newItems = engine.drainMerged();
    final hasMore = engine.hasMoreSources;

    log('[LOAD_MORE] before=$beforeCount appended=${newItems.length} hasMore=$hasMore');

    _playlist.append(newItems);
    state = state.copyWith(
      items: _playlist.items,
      isLoadingMore: false,
      hasMorePages: newItems.isNotEmpty || hasMore,
    );
  }

  void _syncState() {
    state = state.copyWith(
      items: _playlist.items,
      currentIndex: _playlist.currentIndex,
      gallerySubIndex: 0,
    );
  }

  void _notifyPreloader() {
    _preparationEngine?.onIndexChanged(_playlist.currentIndex);
  }

  void _startAutoAdvance() {
    _cancelAutoAdvance();
    if (!state.isPlaying) return;
    _autoAdvanceTimer = Timer(
      Duration(seconds: _slideshowIntervalSeconds),
      () => galleryNext(),
    );
  }

  void _restartAutoAdvance() {
    _startAutoAdvance();
  }

  void _cancelAutoAdvance() {
    _autoAdvanceTimer?.cancel();
    _autoAdvanceTimer = null;
  }

  void _startOverlayTimer() {
    _cancelOverlayTimer();
    _overlayTimer = Timer(
      const Duration(milliseconds: AppConstants.overlayAutoHideMs),
      () {
        if (state.isFullscreen) {
          state = state.copyWith(overlayVisible: false);
        }
      },
    );
  }

  void _cancelOverlayTimer() {
    _overlayTimer?.cancel();
    _overlayTimer = null;
  }

  @override
  void dispose() {
    _cancelAutoAdvance();
    _cancelOverlayTimer();
    _preparationEngine?.dispose();
    _mergeEngine?.dispose();
    _playlist.dispose();
    super.dispose();
  }
}
