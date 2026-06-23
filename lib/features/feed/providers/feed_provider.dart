import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/errors/app_error.dart';
import '../../../core/constants/app_constants.dart';
import '../domain/media_asset.dart';
import '../data/feed_repository.dart';

final feedProvider = StateNotifierProvider.family<FeedNotifier, FeedState, String?>(
  (ref, subreddit) {
    final repository = ref.watch(feedRepositoryProvider);
    return FeedNotifier(repository: repository, subreddit: subreddit);
  },
);

class FeedState {
  final List<MediaAsset> items;
  final bool isLoading;
  final bool isLoadingMore;
  final bool hasMore;
  final String? after;
  final AppError? error;

  const FeedState({
    this.items = const [],
    this.isLoading = false,
    this.isLoadingMore = false,
    this.hasMore = true,
    this.after,
    this.error,
  });

  FeedState copyWith({
    List<MediaAsset>? items,
    bool? isLoading,
    bool? isLoadingMore,
    bool? hasMore,
    String? after,
    AppError? error,
  }) {
    return FeedState(
      items: items ?? this.items,
      isLoading: isLoading ?? this.isLoading,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      hasMore: hasMore ?? this.hasMore,
      after: after ?? this.after,
      error: error ?? this.error,
    );
  }
}

class FeedNotifier extends StateNotifier<FeedState> {
  final FeedRepository _repository;
  final String? _subreddit;
  String? _sort;

  FeedNotifier({
    required this._repository,
    this._subreddit,
  })  : _sort = null,
        super(const FeedState());

  void setSort(String? sort) {
    _sort = sort;
    refresh();
  }

  Future<void> loadInitial() async {
    state = state.copyWith(isLoading: true, error: null);
    final result = await _repository.getFeed(
      limit: AppConstants.paginationPageSize,
      subreddits: _subreddit,
      sort: _sort,
    );
    result.when(
      (data) {
        state = FeedState(
          items: data.items,
          isLoading: false,
          hasMore: data.hasMore,
          after: data.after,
        );
      },
      (error) {
        state = state.copyWith(isLoading: false, error: error);
      },
    );
  }

  Future<void> refresh() async {
    state = state.copyWith(isLoading: true, error: null, after: null);
    final result = await _repository.getFeed(
      limit: AppConstants.paginationPageSize,
      subreddits: _subreddit,
      sort: _sort,
    );
    result.when(
      (data) {
        state = FeedState(
          items: data.items,
          isLoading: false,
          hasMore: data.hasMore,
          after: data.after,
        );
      },
      (error) {
        state = state.copyWith(isLoading: false, error: error);
      },
    );
  }

  Future<void> loadMore() async {
    if (state.isLoadingMore || !state.hasMore) return;
    state = state.copyWith(isLoadingMore: true);
    final result = await _repository.getFeed(
      limit: AppConstants.paginationPageSize,
      after: state.after,
      subreddits: _subreddit,
      sort: _sort,
    );
    result.when(
      (data) {
        state = FeedState(
          items: [...state.items, ...data.items],
          isLoadingMore: false,
          hasMore: data.hasMore,
          after: data.after,
        );
      },
      (error) {
        state = state.copyWith(isLoadingMore: false, error: error);
      },
    );
  }
}
