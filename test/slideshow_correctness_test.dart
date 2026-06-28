import 'package:flutter_test/flutter_test.dart';
import 'package:redslide/core/network/result.dart';
import 'package:redslide/features/feed/data/feed_repository.dart';
import 'package:redslide/features/feed/domain/media_asset.dart';
import 'package:redslide/features/search/data/search_repository.dart';
import 'package:redslide/features/slideshow/data/search_media_source.dart';
import 'package:redslide/features/slideshow/domain/slideshow_source.dart';

MediaAsset _makeAsset({
  required String id,
  required String subreddit,
}) {
  return MediaAsset(
    id: id,
    title: 'Test $id',
    author: 'author',
    score: 100,
    subreddit: subreddit,
    mediaUrl: 'https://i.redd.it/$id.jpg',
    isVideo: false,
    isGallery: false,
    nsfw: false,
    qualityScore: 50,
    createdUtc: 1000000,
  );
}

class _MockSearchRepository implements SearchRepository {
  int callCount = 0;
  bool hasMore = true;

  @override
  Future<Result<FeedResponse>> searchReddit({
    required String query,
    required SearchMode mode,
    int limit = 50,
    String? after,
    List<String>? subreddits,
  }) async {
    callCount++;
    final items = <MediaAsset>[];
    for (int i = 0; i < 5; i++) {
      items.add(_makeAsset(id: 'api_${callCount}_$i', subreddit: query));
    }
    return Success(FeedResponse(
      items: items,
      after: 'cursor_$callCount',
      hasMore: hasMore,
    ));
  }

  @override
  Future<Result<FeedResponse>> search({
    required String query,
    int limit = 50,
    int page = 1,
    List<String>? subreddits,
    String? mediaType,
    String? sort,
  }) async {
    throw UnimplementedError('not used');
  }

  @override
  Future<Result<FeedResponse>> searchDebug({
    required String query,
    int limit = 50,
    int page = 1,
  }) async {
    throw UnimplementedError('not used');
  }
}

void main() {
  group('SearchMediaSource pagination', () {
    test('returns initialResults with hasMore=true on first call', () async {
      final results = [
        _makeAsset(id: 'a', subreddit: 'test'),
        _makeAsset(id: 'b', subreddit: 'test'),
      ];
      final source = SearchMediaSource(
        repository: _MockSearchRepository(),
        query: 'test',
        mode: SearchMode.global,
        initialResults: results,
      );

      final page = await source.loadNext();

      expect(page.items.length, 2);
      expect(page.items[0].id, 'a');
      expect(page.items[1].id, 'b');
      expect(page.hasMore, isTrue,
          reason: 'initialResults must report hasMore=true to continue pagination');
    });

    test('empty initialResults returns empty page with hasMore=true', () async {
      final source = SearchMediaSource(
        repository: _MockSearchRepository(),
        query: 'test',
        mode: SearchMode.global,
        initialResults: <MediaAsset>[],
      );

      final page = await source.loadNext();

      expect(page.items.length, 0);
      expect(page.hasMore, isTrue);
    });

    test('initialResults returned only once, subsequent calls go to API', () async {
      final mock = _MockSearchRepository();
      mock.hasMore = true;
      final results = [_makeAsset(id: 'a', subreddit: 'test')];
      final source = SearchMediaSource(
        repository: mock,
        query: 'test',
        mode: SearchMode.global,
        initialResults: results,
      );

      final page1 = await source.loadNext();
      expect(page1.items.length, 1);
      expect(page1.items[0].id, 'a');

      final page2 = await source.loadNext();
      expect(page2.items.length, 5);
      expect(page2.items[0].id, 'api_1_0');
      expect(mock.callCount, 1);
    });

    test('hasMore is false when API returns no more items', () async {
      final mock = _MockSearchRepository();
      mock.hasMore = false;
      final source = SearchMediaSource(
        repository: mock,
        query: 'test',
        mode: SearchMode.global,
      );

      final page = await source.loadNext();

      expect(page.items.length, 5);
      expect(page.hasMore, isFalse);
      expect(source.hasMore, isFalse);
    });

    test('page2 hasMore=true when API returns more, then false on subsequent call', () async {
      final mock = _MockSearchRepository();
      mock.hasMore = true;
      final source = SearchMediaSource(
        repository: mock,
        query: 'test',
        mode: SearchMode.global,
      );

      await source.loadNext();
      expect(source.hasMore, isTrue);

      mock.hasMore = false;
      await source.loadNext();
      expect(source.hasMore, isFalse);
    });

    test('no initialResults loads from API on first call', () async {
      final mock = _MockSearchRepository();
      final source = SearchMediaSource(
        repository: mock,
        query: 'test',
        mode: SearchMode.global,
      );

      final page = await source.loadNext();

      expect(mock.callCount, 1);
      expect(page.items.length, 5);
      expect(source.hasMore, isTrue);
    });

    test('hasMore getter reflects state after loadNext', () async {
      final mock = _MockSearchRepository();
      mock.hasMore = true;
      final source = SearchMediaSource(
        repository: mock,
        query: 'test',
        mode: SearchMode.global,
      );

      expect(source.hasMore, isTrue);

      await source.loadNext();
      expect(source.hasMore, isTrue);

      mock.hasMore = false;
      await source.loadNext();
      expect(source.hasMore, isFalse);
    });
  });
}
