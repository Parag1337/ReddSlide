import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/errors/app_error.dart';
import '../../../core/constants/app_constants.dart';
import '../../feed/domain/media_asset.dart';
import '../data/search_repository.dart';

final searchProvider = StateNotifierProvider<SearchNotifier, SearchState>((ref) {
  final searchRepository = ref.watch(searchRepositoryProvider);
  return SearchNotifier(searchRepository: searchRepository);
});

class SearchState {
  final String query;
  final List<MediaAsset> results;
  final bool isLoading;
  final bool isLoadingMore;
  final bool hasMore;
  final int currentPage;
  final bool isDebugFallback;
  final AppError? error;
  final List<String> recentQueries;

  const SearchState({
    this.query = '',
    this.results = const [],
    this.isLoading = false,
    this.isLoadingMore = false,
    this.hasMore = false,
    this.currentPage = 1,
    this.isDebugFallback = false,
    this.error,
    this.recentQueries = const [],
  });

  SearchState copyWith({
    String? query,
    List<MediaAsset>? results,
    bool? isLoading,
    bool? isLoadingMore,
    bool? hasMore,
    int? currentPage,
    bool? isDebugFallback,
    AppError? error,
    List<String>? recentQueries,
  }) {
    return SearchState(
      query: query ?? this.query,
      results: results ?? this.results,
      isLoading: isLoading ?? this.isLoading,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      hasMore: hasMore ?? this.hasMore,
      currentPage: currentPage ?? this.currentPage,
      isDebugFallback: isDebugFallback ?? this.isDebugFallback,
      error: error ?? this.error,
      recentQueries: recentQueries ?? this.recentQueries,
    );
  }
}

class SearchNotifier extends StateNotifier<SearchState> {
  final SearchRepository _searchRepository;

  SearchNotifier({required this._searchRepository})
      : super(const SearchState());

  Future<void> search(String query, {int page = 1}) async {
    if (query.trim().isEmpty) {
      state = const SearchState();
      return;
    }

    if (page == 1) {
      state = state.copyWith(query: query, isLoading: true, error: null, isDebugFallback: false);
    } else {
      state = state.copyWith(query: query, isLoadingMore: true);
    }

    final result = await _searchRepository.search(
      query: query,
      limit: AppConstants.paginationPageSize,
      page: page,
    );

    result.when(
      (data) {
        if (data.items.isEmpty && page == 1) {
          _tryDebugFallback(query);
          return;
        }
        final newResults = page == 1 ? data.items : [...state.results, ...data.items];
        state = state.copyWith(
          results: newResults,
          isLoading: false,
          isLoadingMore: false,
          hasMore: data.hasMore,
          currentPage: page,
          isDebugFallback: false,
        );
        _addRecentQuery(query);
      },
      (error) {
        state = state.copyWith(isLoading: false, isLoadingMore: false, error: error);
      },
    );
  }

  Future<void> _tryDebugFallback(String query) async {
    final result = await _searchRepository.searchDebug(
      query: query,
      limit: AppConstants.paginationPageSize,
      page: 1,
    );
    result.when(
      (data) {
        state = state.copyWith(
          results: data.items,
          isLoading: false,
          hasMore: data.hasMore,
          currentPage: 1,
          isDebugFallback: true,
        );
        _addRecentQuery(query);
      },
      (error) {
        state = state.copyWith(isLoading: false, error: error);
      },
    );
  }

  Future<void> loadMore() async {
    if (state.isLoadingMore || !state.hasMore) return;
    await search(state.query, page: state.currentPage + 1);
  }

  void clearResults() {
    state = const SearchState(recentQueries: []);
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
}

final searchResultsProvider = Provider<SearchState>((ref) {
  return ref.watch(searchProvider);
});
