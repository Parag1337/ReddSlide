import 'dart:async';
import 'dart:developer';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/result.dart';
import '../../../core/constants/app_constants.dart';
import '../../feed/data/feed_repository.dart';
import '../../search/data/search_repository.dart';
import '../../settings/providers/settings_provider.dart';
import '../domain/slideshow_source.dart';
import '../domain/slideshow_state.dart';
import '../domain/merge_engine.dart';

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
  final FeedRepository _feedRepository;
  final SearchRepository _searchRepository;
  final List<String> _allSubreddits;
  Timer? _autoAdvanceTimer;
  Timer? _overlayTimer;
  int _retryCount = 0;
  int _slideshowIntervalSeconds = AppConstants.defaultSlideshowIntervalSeconds;
  MergeEngine? _mergeEngine;
  String? _mergeSortMode;

  SlideshowNotifier({
    required this._feedRepository,
    required this._searchRepository,
    required SlideshowSource source,
    required List<String> allSubreddits,
  })  : _allSubreddits = allSubreddits,
        super(SlideshowState(source: source));

  void setInterval(int seconds) {
    _slideshowIntervalSeconds = seconds;
  }

  void initialize() {
    switch (state.source) {
      case MultiSubredditSource():
      case GroupSource():
      case GlobalFeedSource():
        _initMergeEngine();
      default:
        _loadInitialItems();
    }
  }

  Future<List<String>> _resolveSubreddits() async {
    return switch (state.source) {
      MultiSubredditSource(:final subreddits) => subreddits,
      GroupSource(:final subreddits) => subreddits,
      GlobalFeedSource() => _allSubreddits,
      _ => <String>[],
    };
  }

  Future<void> _initMergeEngine() async {
    state = state.copyWith(isLoading: true);
    final sw = Stopwatch()..start();

    final subreddits = await _resolveSubreddits();
    _mergeSortMode = switch (state.source) {
      MultiSubredditSource(:final sortMode) => sortMode,
      _ => null,
    };

    if (subreddits.isEmpty) {
      state = state.copyWith(isLoading: false, hasMorePages: false);
      return;
    }

    _mergeEngine = MergeEngine(
      subreddits: subreddits,
      fetchPage: _fetchMergePage,
    );

    await _mergeEngine!.initialize();
    final items = _mergeEngine!.drainMerged();
    final elapsed = sw.elapsedMilliseconds;

    log('[MERGE] initialized mergedItems=${items.length} buffers=${_mergeEngine!.buffers.length} elapsed=${elapsed}ms');
    debugPrint('[PIPELINE] MergeEngine.initialize subreddits=$subreddits items=${items.length} elapsed=${elapsed}ms');
    state = state.copyWith(
      items: items,
      isLoading: false,
      hasMorePages: items.isNotEmpty,
    );

    if (items.isNotEmpty) {
      _startAutoAdvance();
    }
  }

  Future<SubredditPageResult> _fetchMergePage(String subreddit, {String? cursor}) async {
    final sw = Stopwatch()..start();
    final result = await _feedRepository.getFeed(
      limit: AppConstants.mergeEngineBufferSize,
      after: cursor,
      subreddits: subreddit,
      sort: _mergeSortMode,
    );
    final elapsed = sw.elapsedMilliseconds;
    debugPrint('[PIPELINE] MergeEngine.fetchPage subreddit=$subreddit '
        'cursor=${cursor ?? "null"} elapsed=${elapsed}ms');
    return result.when(
      (data) => SubredditPageResult(
        items: data.items,
        cursor: data.after,
        hasMore: data.hasMore,
      ),
      (error) {
        log('[MERGE] fetch error subreddit=$subreddit error=$error');
        return SubredditPageResult(items: [], cursor: null, hasMore: false);
      },
    );
  }

  Future<void> _loadInitialItems() async {
    state = state.copyWith(isLoading: true);
    final sw = Stopwatch()..start();
    log('[LOAD_MORE] _loadInitialItems');
    final result = await _fetchPage(cursor: null);
    result.when(
      (data) {
        final elapsed = sw.elapsedMilliseconds;
        log('[LOAD_MORE] beforeCount=0 afterCount=${data.items.length} '
            'appended=${data.items.length} hasMore=${data.hasMore} after=${data.after}');
        debugPrint('[PIPELINE] _loadInitialItems source=${state.source.runtimeType} '
            'items=${data.items.length} elapsed=${elapsed}ms');
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
    final fetchSw = Stopwatch()..start();
    debugPrint('[FETCH_START] cursor=$cursor');
    final result = switch (state.source) {
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
    debugPrint('[FETCH_DONE] elapsed=${fetchSw.elapsedMilliseconds}ms');
    return result;
  }

  Future<void> next({int eid = -1}) async {
    if (state.items.isEmpty) return;
    if (eid == -1) eid = _nextEvent();
    final sw = Stopwatch()..start();
    final tapTs = DateTime.now().millisecondsSinceEpoch;
    final nextIndex = state.currentIndex + 1;
    final asset = nextIndex < state.items.length ? state.items[nextIndex] : null;
    final url = asset != null
        ? (asset.isGallery && asset.galleryUrls != null && asset.galleryUrls!.isNotEmpty
              ? asset.galleryUrls![0]
              : asset.mediaUrl)
        : 'none';

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
    final stateMs = sw.elapsedMilliseconds;
    debugPrint('[STATE_CHANGE] event=$eid type=currentIndex value=$nextIndex url=$url '
        'tapToState=${stateMs}ms ts=$tapTs');
    debugPrint('[PIPELINE] next event=$eid index=$nextIndex tapToState=${stateMs}ms url=$url');
    _restartAutoAdvance();
    _checkPreload();
  }

  Future<void> previous({int eid = -1}) async {
    if (state.currentIndex <= 0) return;
    if (eid == -1) eid = _nextEvent();
    final prevIndex = state.currentIndex - 1;
    final asset = prevIndex < state.items.length ? state.items[prevIndex] : null;
    final url = asset != null
        ? (asset.isGallery && asset.galleryUrls != null && asset.galleryUrls!.isNotEmpty
              ? asset.galleryUrls![0]
              : asset.mediaUrl)
        : 'none';
    final ts = DateTime.now().millisecondsSinceEpoch;
    state = state.copyWith(currentIndex: prevIndex, gallerySubIndex: 0);
    debugPrint('[STATE_CHANGE] event=$eid type=currentIndex value=$prevIndex url=$url direction=previous ts=$ts');
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
    debugPrint('[TOGGLE_OVERLAY_TRACE] ${StackTrace.current}');
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
    final eid = _nextEvent();
    final ts = DateTime.now().millisecondsSinceEpoch;
    final startIndex = state.currentIndex;
    final asset = state.items[startIndex];

    final nextGalleryIndex = state.gallerySubIndex + 1;
    final maxGalleryIndex = (asset.isGallery && asset.galleryUrls != null && asset.galleryUrls!.isNotEmpty)
        ? asset.galleryUrls!.length - 1
        : 0;
    final willAdvanceItem = !asset.isGallery || asset.galleryUrls == null ||
        asset.galleryUrls!.isEmpty || state.gallerySubIndex >= maxGalleryIndex;
    final targetIndex = willAdvanceItem ? startIndex + 1 : startIndex;
    final targetUrl = willAdvanceItem
        ? (targetIndex < state.items.length
            ? (state.items[targetIndex].isGallery && state.items[targetIndex].galleryUrls != null
                ? state.items[targetIndex].galleryUrls!.first
                : state.items[targetIndex].mediaUrl)
            : 'none')
        : (asset.galleryUrls![nextGalleryIndex.clamp(0, maxGalleryIndex)]);

    debugPrint('[TAP] event=$eid ts=$ts index=$startIndex targetIndex=$targetIndex url=$targetUrl');

    if (asset.isGallery && asset.galleryUrls != null && asset.galleryUrls!.isNotEmpty) {
      final maxIndex = asset.galleryUrls!.length - 1;
      if (state.gallerySubIndex < maxIndex) {
        state = state.copyWith(gallerySubIndex: state.gallerySubIndex + 1);
        _restartAutoAdvance();
        debugPrint('[STATE_CHANGE] event=$eid type=gallerySubIndex value=${state.gallerySubIndex}');
        return;
      }
    }
    next(eid: eid);
  }

  void galleryPrevious() {
    if (state.items.isEmpty) return;
    final eid = _nextEvent();
    final startIndex = state.currentIndex;
    final asset = state.items[startIndex];
    final prevGalleryIndex = state.gallerySubIndex - 1;
    final willAdvanceItem = !asset.isGallery || asset.galleryUrls == null ||
        asset.galleryUrls!.isEmpty || state.gallerySubIndex <= 0;
    final targetIndex = willAdvanceItem ? startIndex - 1 : startIndex;
    final targetUrl = willAdvanceItem
        ? (targetIndex >= 0
            ? (state.items[targetIndex].isGallery && state.items[targetIndex].galleryUrls != null
                ? state.items[targetIndex].galleryUrls!.last
                : state.items[targetIndex].mediaUrl)
            : 'none')
        : (asset.galleryUrls![prevGalleryIndex.clamp(0, asset.galleryUrls!.length - 1)]);
    debugPrint('[TAP] event=$eid direction=previous index=$startIndex targetIndex=$targetIndex url=$targetUrl');
    if (asset.isGallery && asset.galleryUrls != null && asset.galleryUrls!.isNotEmpty) {
      if (state.gallerySubIndex > 0) {
        state = state.copyWith(gallerySubIndex: state.gallerySubIndex - 1);
        _restartAutoAdvance();
        debugPrint('[STATE_CHANGE] event=$eid type=gallerySubIndex value=${state.gallerySubIndex}');
        return;
      }
    }
    previous(eid: eid);
  }

  Future<void> loadMore() async {
    final loadSw = Stopwatch()..start();
    if (state.isLoadingMore) {
      log('[LOAD_MORE] SKIP — isLoadingMore already true');
      return;
    }

    if (_mergeEngine != null) {
      if (!_mergeEngine!.hasMoreSources) {
        log('[LOAD_MORE] SKIP — no more sources');
        state = state.copyWith(hasMorePages: false);
        return;
      }

      state = state.copyWith(isLoadingMore: true);
      final beforeCount = state.items.length;

      _mergeEngine!.autoRefill();
      final newItems = _mergeEngine!.drainMerged();
      final hasMore = _mergeEngine!.hasMoreSources;

      log('[LOAD_MORE] merge beforeCount=$beforeCount appended=${newItems.length} hasMore=$hasMore');
      state = state.copyWith(
        items: [...state.items, ...newItems],
        isLoadingMore: false,
        hasMorePages: newItems.isNotEmpty || hasMore,
      );
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
    debugPrint('[LOAD_MORE_WIRE] elapsed=${loadSw.elapsedMilliseconds}ms before=$beforeCount');

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
    final mergedRemaining = _mergeEngine?.merged.length ?? 0;
    final effectiveRemaining = remaining + mergedRemaining;
    final willLoad = effectiveRemaining <= AppConstants.preloadTriggerRemaining && !state.isLoadingMore;
    debugPrint('[PRELOAD_TRIGGER] currentIndex=${state.currentIndex} '
        'totalItems=${state.items.length} '
        'remaining=$remaining mergedRemaining=$mergedRemaining '
        'effectiveRemaining=$effectiveRemaining '
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
    _mergeEngine?.dispose();
    _mergeEngine = null;
    super.dispose();
  }
}
