import 'dart:math' show max;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/errors/app_error.dart';
import '../../../core/constants/app_constants.dart';
import '../../feed/domain/media_asset.dart';
import '../../settings/providers/settings_provider.dart';
import '../../slideshow/domain/slideshow_source.dart';
import '../data/search_repository.dart';

void _trace(String stage, List<MediaAsset> items, {String? cursor, bool? hasMore, String? label}) {
  final firstIds = items.take(5).map((e) => e.id).join(',');
  final lastIds = items.skip(max(0, items.length - 5)).map((e) => e.id).join(',');
  final buf = StringBuffer();
  buf.writeln('');
  buf.writeln('╔══════════════════════════════════════════════════');
  buf.writeln('║ TRACE: $stage${label != null ? ' ($label)' : ''}');
  buf.writeln('║ items=${items.length} cursor=${cursor ?? "null"} hasMore=${hasMore ?? "?"}');
  if (items.isNotEmpty) {
    buf.writeln('║ first5=[$firstIds]');
    buf.writeln('║ last5=[$lastIds]');
  }
  buf.writeln('╚══════════════════════════════════════════════════');
  debugPrint(buf.toString());
}

final searchProvider = StateNotifierProvider<SearchNotifier, SearchState>((ref) {
  final searchRepository = ref.watch(searchRepositoryProvider);
  return SearchNotifier(
    searchRepository: searchRepository,
    ref: ref,
  );
});

class SearchState {
  final String query;
  final SearchMode mode;
  final List<MediaAsset> results;
  final bool isLoading;
  final bool isLoadingMore;
  final bool hasMore;
  final String? afterCursor;
  final AppError? error;
  final List<String> recentQueries;
  final List<String> selectedSubreddits;
  final String? mediaType;
  final String? sort;
  final int totalResults;

  const SearchState({
    this.query = '',
    this.mode = SearchMode.local,
    this.results = const [],
    this.isLoading = false,
    this.isLoadingMore = false,
    this.hasMore = true,
    this.afterCursor,
    this.error,
    this.recentQueries = const [],
    this.selectedSubreddits = const [],
    this.mediaType,
    this.sort,
    this.totalResults = 0,
  });

  SearchState copyWith({
    String? query,
    SearchMode? mode,
    List<MediaAsset>? results,
    bool? isLoading,
    bool? isLoadingMore,
    bool? hasMore,
    String? afterCursor,
    AppError? error,
    List<String>? recentQueries,
    List<String>? selectedSubreddits,
    String? mediaType,
    String? sort,
    int? totalResults,
  }) {
    return SearchState(
      query: query ?? this.query,
      mode: mode ?? this.mode,
      results: results ?? this.results,
      isLoading: isLoading ?? this.isLoading,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      hasMore: hasMore ?? this.hasMore,
      afterCursor: afterCursor ?? this.afterCursor,
      error: error ?? this.error,
      recentQueries: recentQueries ?? this.recentQueries,
      selectedSubreddits: selectedSubreddits ?? this.selectedSubreddits,
      mediaType: mediaType ?? this.mediaType,
      sort: sort ?? this.sort,
      totalResults: totalResults ?? this.totalResults,
    );
  }
}

class SearchNotifier extends StateNotifier<SearchState> {
  final SearchRepository _searchRepository;
  final Ref _ref;

  SearchNotifier({
    required this._searchRepository,
    required Ref ref,
  })  : _ref = ref,
        super(SearchState(
          selectedSubreddits: ref.read(settingsProvider).valueOrNull?.subreddits ?? [],
        ));

  void setMode(SearchMode mode) {
    syncSelectedSubreddits();
    state = state.copyWith(mode: mode);
  }

  void setSelectedSubreddits(List<String> subreddits) {
    state = state.copyWith(selectedSubreddits: subreddits);
  }

  void toggleSubreddit(String subreddit) {
    final current = state.selectedSubreddits;
    if (current.contains(subreddit)) {
      state = state.copyWith(selectedSubreddits: current.where((s) => s != subreddit).toList());
    } else {
      state = state.copyWith(selectedSubreddits: [...current, subreddit]);
    }
  }

  void setMediaType(String? mediaType) {
    state = state.copyWith(mediaType: mediaType);
  }

  void setSort(String? sort) {
    state = state.copyWith(sort: sort);
  }

  void syncSelectedSubreddits() {
    final allSubs = _ref.read(settingsProvider).valueOrNull?.subreddits ?? [];
    final currentSelected = state.selectedSubreddits;
    final synced = currentSelected.where((s) => allSubs.contains(s)).toList();
    if (synced.length != currentSelected.length) {
      state = state.copyWith(selectedSubreddits: synced);
    }
  }

  Future<void> search(String query) async {
    if (query.trim().isEmpty) {
      state = const SearchState();
      return;
    }

    syncSelectedSubreddits();

    state = state.copyWith(
      query: query,
      isLoading: true,
      error: null,
      hasMore: true,
      afterCursor: null,
      totalResults: 0,
    );

    final result = await _searchRepository.searchReddit(
      query: query,
      mode: state.mode,
      limit: AppConstants.paginationPageSize,
      after: null,
      subreddits: state.mode == SearchMode.local ? state.selectedSubreddits : null,
    );

    result.when(
      (data) {
        _trace('search results', data.items, cursor: data.after, hasMore: data.hasMore);

        state = state.copyWith(
          results: data.items,
          isLoading: false,
          hasMore: data.hasMore,
          afterCursor: data.after,
          totalResults: data.items.length,
        );

        _addRecentQuery(query);
      },
      (error) {
        state = state.copyWith(isLoading: false, error: error);
      },
    );
  }

  Future<void> loadMore() async {
    if (state.isLoadingMore || !state.hasMore || state.afterCursor == null) return;

    state = state.copyWith(isLoadingMore: true);

    final result = await _searchRepository.searchReddit(
      query: state.query,
      mode: state.mode,
      limit: AppConstants.paginationPageSize,
      after: state.afterCursor,
      subreddits: state.mode == SearchMode.local ? state.selectedSubreddits : null,
    );

    result.when(
      (data) {
        final existingIds = state.results.map((e) => e.id).toSet();
        final newItems = data.items.where((e) => !existingIds.contains(e.id)).toList();
        final combined = [...state.results, ...newItems];
        final capped = combined.length > 1000
            ? combined.sublist(combined.length - 1000)
            : combined;

        state = state.copyWith(
          results: capped,
          isLoadingMore: false,
          hasMore: data.hasMore,
          afterCursor: data.after,
          totalResults: capped.length,
        );
      },
      (error) {
        state = state.copyWith(isLoadingMore: false);
      },
    );
  }

  void clearResults() {
    state = SearchState(
      recentQueries: state.recentQueries,
      mode: state.mode,
      selectedSubreddits: state.selectedSubreddits,
      mediaType: state.mediaType,
      sort: state.sort,
    );
  }

  void _addRecentQuery(String query) {
    final recent = state.recentQueries;
    if (recent.contains(query)) return;
    final updated = [query, ...recent].take(AppConstants.searchHistoryMax).toList();
    state = state.copyWith(recentQueries: updated);
  }

  void removeRecentQuery(String query) {
    final updated = state.recentQueries.where((e) => e != query).toList();
    state = state.copyWith(recentQueries: updated);
  }

  void clearHistory() {
    state = state.copyWith(recentQueries: []);
  }

  void resetFilters() {
    state = state.copyWith(mediaType: null, sort: null);
  }
}

final searchResultsProvider = Provider<SearchState>((ref) {
  return ref.watch(searchProvider);
});
