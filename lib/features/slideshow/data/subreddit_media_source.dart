import 'dart:developer';
import '../../../core/constants/app_constants.dart';
import '../../../core/media/media_source.dart';
import '../../feed/data/feed_repository.dart';

class SubredditMediaSource extends MediaSource {
  final FeedRepository _repository;
  final String _subreddit;
  final String? _sortMode;
  String? _cursor;
  bool _hasMore = true;

  SubredditMediaSource({
    required FeedRepository repository,
    required String subreddit,
    String? sortMode,
  })  : _repository = repository,
        _subreddit = subreddit,
        _sortMode = sortMode;

  @override
  bool get hasMore => _hasMore;

  @override
  Future<MediaPage> loadNext() async {
    log('[MediaSource] SubredditMediaSource.loadNext subreddit=$_subreddit cursor=$_cursor');
    final result = await _repository.getFeed(
      limit: AppConstants.mergeEngineBufferSize,
      after: _cursor,
      subreddits: _subreddit,
      sort: _sortMode,
    );
    return result.when(
      (data) {
        _cursor = data.after;
        _hasMore = data.hasMore;
        return MediaPage(items: data.items, cursor: data.after, hasMore: data.hasMore);
      },
      (error) {
        log('[MediaSource] SubredditMediaSource error=$error');
        return const MediaPage(items: [], cursor: null, hasMore: false);
      },
    );
  }

  @override
  Future<void> dispose() async {}
}
