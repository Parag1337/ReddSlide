import 'dart:async';
import 'dart:developer';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/result.dart';
import '../../../core/constants/app_constants.dart';
import '../../feed/data/feed_repository.dart';
import '../../search/data/search_repository.dart';
import '../domain/slideshow_source.dart';
import '../domain/slideshow_state.dart';

final slideshowProvider = StateNotifierProvider.family<SlideshowNotifier, SlideshowState, SlideshowSource>(
  (ref, source) {
    final feedRepository = ref.watch(feedRepositoryProvider);
    final searchRepository = ref.watch(searchRepositoryProvider);
    return SlideshowNotifier(
      feedRepository: feedRepository,
      searchRepository: searchRepository,
      source: source,
    );
  },
);

class SlideshowNotifier extends StateNotifier<SlideshowState> {
  final FeedRepository _feedRepository;
  final SearchRepository _searchRepository;
  Timer? _autoAdvanceTimer;
  Timer? _overlayTimer;
  int _retryCount = 0;
  int _slideshowIntervalSeconds = AppConstants.defaultSlideshowIntervalSeconds;

  SlideshowNotifier({
    required this._feedRepository,
    required this._searchRepository,
    required SlideshowSource source,
  })  : super(SlideshowState(source: source));

  void setInterval(int seconds) {
    _slideshowIntervalSeconds = seconds;
  }

  void initialize() {
    _loadInitialItems();
  }

  Future<void> _loadInitialItems() async {
    state = state.copyWith(isLoading: true);
    log('[LOAD_MORE] _loadInitialItems');
    final result = await _fetchPage(cursor: null);
    result.when(
      (data) {
        log('[LOAD_MORE] beforeCount=0 afterCount=${data.items.length} '
            'appended=${data.items.length} hasMore=${data.hasMore} after=${data.after}');
        state = state.copyWith(
          items: data.items,
          isLoading: false,
          hasMorePages: data.hasMore,
          paginationCursor: data.after,
        );
        if (data.items.isNotEmpty) {
          _startAutoAdvance();
        }
      },
      (error) {
        log('[LOAD_MORE] error=$error');
        state = state.copyWith(isLoading: false, hasMorePages: false);
      },
    );
  }

  void setStartIndex(int index) {
    state = state.copyWith(currentIndex: index);
  }

  Future<Result<FeedResponse>> _fetchPage({String? cursor}) async {
    return switch (state.source) {
      SubredditSource(:final subreddit, :final sortMode) =>
        _feedRepository.getFeed(
          limit: AppConstants.paginationPageSize,
          after: cursor,
          subreddits: subreddit,
          sort: sortMode,
        ),
      MultiSubredditSource(:final subreddits, :final sortMode) =>
        _feedRepository.getFeed(
          limit: AppConstants.paginationPageSize,
          after: cursor,
          subreddits: subreddits.join(','),
          sort: sortMode,
        ),
      GlobalFeedSource() =>
        _feedRepository.getFeed(
          limit: AppConstants.paginationPageSize,
          after: cursor,
        ),
      SearchSource(:final query, :final mode, :final subreddits) =>
        _searchRepository.searchReddit(
          query: query,
          mode: mode,
          limit: AppConstants.paginationPageSize,
          after: cursor,
          subreddits: subreddits,
        ),
      GroupSource(:final subreddits) =>
        _feedRepository.getFeed(
          limit: AppConstants.paginationPageSize,
          after: cursor,
          subreddits: subreddits.join(','),
        ),
    };
  }

  Future<void> next() async {
    if (state.items.isEmpty) return;
    final nextIndex = state.currentIndex + 1;
    final asset = nextIndex < state.items.length ? state.items[nextIndex] : null;
    final url = asset != null
        ? (asset.isGallery && asset.galleryUrls != null && asset.galleryUrls!.isNotEmpty
              ? asset.galleryUrls![0]
              : asset.mediaUrl)
        : 'none';
    log('[SLIDESHOW] currentIndex=${state.currentIndex} '
        'totalItems=${state.items.length} '
        'remaining=${state.items.length - state.currentIndex - 1} '
        'galleryIndex=${state.gallerySubIndex}');
    debugPrint('[SLIDE_START] index=$nextIndex url=$url');

    if (nextIndex >= state.items.length) {
      log('[SLIDESHOW] currentIndex=${state.currentIndex} '
          'totalItems=${state.items.length} remaining=0 '
          'END_OF_LIST hasMorePages=${state.hasMorePages}');
      if (!state.isLoadingMore) {
        await loadMore();
        if (state.currentIndex + 1 < state.items.length) {
          state = state.copyWith(currentIndex: state.currentIndex + 1, gallerySubIndex: 0);
        }
      }
      _restartAutoAdvance();
      return;
    }
    state = state.copyWith(currentIndex: nextIndex, gallerySubIndex: 0);
    _restartAutoAdvance();
    _checkPreload();
  }

  Future<void> previous() async {
    if (state.currentIndex <= 0) return;
    final prevIndex = state.currentIndex - 1;
    final asset = prevIndex < state.items.length ? state.items[prevIndex] : null;
    final url = asset != null
        ? (asset.isGallery && asset.galleryUrls != null && asset.galleryUrls!.isNotEmpty
              ? asset.galleryUrls![0]
              : asset.mediaUrl)
        : 'none';
    debugPrint('[SLIDE_START] index=$prevIndex url=$url direction=previous');
    state = state.copyWith(currentIndex: prevIndex, gallerySubIndex: 0);
    _restartAutoAdvance();
    _checkPreload();
  }

  Future<void> jumpTo(int index) async {
    if (index < 0 || index >= state.items.length) return;
    state = state.copyWith(currentIndex: index, gallerySubIndex: 0);
    _restartAutoAdvance();
    _checkPreload();
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
    if (state.items.isEmpty) return;
    final asset = state.items[state.currentIndex];
    final nextGalleryIndex = state.gallerySubIndex + 1;
    final maxGalleryIndex = (asset.isGallery && asset.galleryUrls != null && asset.galleryUrls!.isNotEmpty)
        ? asset.galleryUrls!.length - 1
        : 0;
    final willAdvanceItem = !asset.isGallery || asset.galleryUrls == null ||
        asset.galleryUrls!.isEmpty || state.gallerySubIndex >= maxGalleryIndex;
    final targetIndex = willAdvanceItem ? state.currentIndex + 1 : state.currentIndex;
    final targetUrl = willAdvanceItem
        ? (targetIndex < state.items.length
            ? (state.items[targetIndex].isGallery && state.items[targetIndex].galleryUrls != null
                ? state.items[targetIndex].galleryUrls!.first
                : state.items[targetIndex].mediaUrl)
            : 'none')
        : (asset.galleryUrls![nextGalleryIndex.clamp(0, maxGalleryIndex)]);
    debugPrint('[NEXT_PRESSED] action=galleryNext '
        'currentIndex=${state.currentIndex} '
        'gallerySubIndex=${state.gallerySubIndex} '
        'targetIndex=$targetIndex '
        'targetUrl=$targetUrl');
    log('[UI] galleryNext action=galleryAdvance '
        'currentIndex=${state.currentIndex} '
        'totalItems=${state.items.length} '
        'gallerySubIndex=${state.gallerySubIndex} '
        'isGallery=${asset.isGallery}');
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
    if (state.items.isEmpty) return;
    final asset = state.items[state.currentIndex];
    final prevGalleryIndex = state.gallerySubIndex - 1;
    final willAdvanceItem = !asset.isGallery || asset.galleryUrls == null ||
        asset.galleryUrls!.isEmpty || state.gallerySubIndex <= 0;
    final targetIndex = willAdvanceItem ? state.currentIndex - 1 : state.currentIndex;
    final targetUrl = willAdvanceItem
        ? (targetIndex >= 0
            ? (state.items[targetIndex].isGallery && state.items[targetIndex].galleryUrls != null
                ? state.items[targetIndex].galleryUrls!.last
                : state.items[targetIndex].mediaUrl)
            : 'none')
        : (asset.galleryUrls![prevGalleryIndex.clamp(0, asset.galleryUrls!.length - 1)]);
    debugPrint('[NEXT_PRESSED] action=galleryPrevious '
        'currentIndex=${state.currentIndex} '
        'gallerySubIndex=${state.gallerySubIndex} '
        'targetIndex=$targetIndex '
        'targetUrl=$targetUrl');
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
    if (state.isLoadingMore) {
      log('[LOAD_MORE] SKIP — isLoadingMore already true');
      return;
    }
    if (!state.hasMorePages) {
      log('[LOAD_MORE] SKIP — no more pages');
      return;
    }

    state = state.copyWith(isLoadingMore: true);
    final beforeCount = state.items.length;

    final cursor = state.paginationCursor;

    log('[LOAD_MORE] beforeCount=$beforeCount '
        'hasMorePages=${state.hasMorePages} '
        'cursor=$cursor');
    final result = await _fetchPage(cursor: cursor);

    result.when(
      (data) {
        _retryCount = 0;
        final newCount = data.items.length;
        final afterCount = beforeCount + newCount;
        log('[LOAD_MORE] beforeCount=$beforeCount afterCount=$afterCount '
            'appended=$newCount hasMore=${data.hasMore} after=${data.after}');
        state = state.copyWith(
          items: [...state.items, ...data.items],
          isLoadingMore: false,
          hasMorePages: newCount > 0 && data.hasMore,
          paginationCursor: data.after,
        );
      },
      (error) {
        log('[LOAD_MORE] error=$error');
        _retryCount++;
        if (_retryCount < AppConstants.maxRetries) {
          state = state.copyWith(isLoadingMore: false);
          Future.delayed(Duration(seconds: _retryCount * 2), loadMore);
        } else {
          state = state.copyWith(isLoadingMore: false);
        }
      },
    );
  }

  void _checkPreload() {
    final remaining = state.items.length - state.currentIndex;
    final willLoad = remaining <= AppConstants.preloadTriggerRemaining && !state.isLoadingMore;
    debugPrint('[PRELOAD_TRIGGER] currentIndex=${state.currentIndex} '
        'totalItems=${state.items.length} '
        'remaining=$remaining '
        'threshold=${AppConstants.preloadTriggerRemaining} '
        'willLoad=$willLoad');
    if (willLoad) {
      loadMore();
    }
  }

  void _startAutoAdvance() {
    _cancelAutoAdvance();
    if (!state.isPlaying) return;
    _autoAdvanceTimer = Timer(
      Duration(seconds: _slideshowIntervalSeconds),
      () async {
        galleryNext();
      },
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
    super.dispose();
  }
}
