import 'dart:developer';
import '../../../core/constants/app_constants.dart';
import '../../../core/media/media_source.dart';
import '../../search/data/search_repository.dart';
import '../../slideshow/domain/slideshow_source.dart';

class SearchMediaSource extends MediaSource {
  final SearchRepository _repository;
  final String _query;
  final SearchMode _mode;
  final List<String>? _subreddits;
  String? _cursor;
  bool _hasMore = true;

  SearchMediaSource({
    required SearchRepository repository,
    required String query,
    required SearchMode mode,
    List<String>? subreddits,
  })  : _repository = repository,
        _query = query,
        _mode = mode,
        _subreddits = subreddits;

  @override
  bool get hasMore => _hasMore;

  @override
  Future<MediaPage> loadNext() async {
    log('[MediaSource] SearchMediaSource.loadNext query=$_query cursor=$_cursor subreddits=$_subreddits');
    final result = await _repository.searchReddit(
      query: _query,
      mode: _mode,
      limit: AppConstants.mergeEngineBufferSize,
      after: _cursor,
      subreddits: _subreddits,
    );
    return result.when(
      (data) {
        _cursor = data.after;
        _hasMore = data.hasMore;
        return MediaPage(items: data.items, cursor: data.after, hasMore: data.hasMore);
      },
      (error) {
        log('[MediaSource] SearchMediaSource error=$error');
        return const MediaPage(items: [], cursor: null, hasMore: false);
      },
    );
  }

  @override
  Future<void> dispose() async {}
}
