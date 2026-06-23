import 'dart:async';
import 'dart:developer';
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

  Future<Result<FeedResponse>> _fetchPage({String? cursor, int? page}) async {
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
      SearchSource(:final query, :final debug) =>
        debug
            ? _searchRepository.searchDebug(
                query: query,
                limit: AppConstants.paginationPageSize,
                page: page ?? 1,
              )
            : _searchRepository.search(
                query: query,
                limit: AppConstants.paginationPageSize,
                page: page ?? 1,
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
    log('[SLIDESHOW] currentIndex=${state.currentIndex} '
        'totalItems=${state.items.length} '
        'remaining=${state.items.length - state.currentIndex - 1} '
        'galleryIndex=${state.gallerySubIndex}');

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
    state = state.copyWith(currentIndex: state.currentIndex - 1, gallerySubIndex: 0);
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

    state = state.copyWith(isLoadingMore: true);
    final beforeCount = state.items.length;

    String? cursor;
    int? page;
    if (state.source is SearchSource) {
      page = (state.items.length ~/ AppConstants.paginationPageSize) + 1;
    } else {
      cursor = state.paginationCursor;
    }

    log('[LOAD_MORE] beforeCount=$beforeCount '
        'hasMorePages=${state.hasMorePages} '
        'cursor=$cursor page=$page');
    final result = await _fetchPage(cursor: cursor, page: page);

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
          hasMorePages: newCount > 0 ? data.hasMore : state.hasMorePages,
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
    log('[PRELOAD] currentIndex=${state.currentIndex} '
        'totalItems=${state.items.length} '
        'remaining=$remaining');
    if (remaining <= AppConstants.preloadTriggerRemaining && !state.isLoadingMore) {
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
