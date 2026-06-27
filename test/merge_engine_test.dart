import 'package:flutter_test/flutter_test.dart';
import 'package:redslide/core/media/media_source.dart';
import 'package:redslide/features/feed/domain/media_asset.dart';
import 'package:redslide/features/slideshow/domain/merge_engine.dart';

MediaAsset _makeAsset({
  required String id,
  required String subreddit,
  String author = 'test_author',
  int createdUtc = 1000000,
  String mediaUrl = 'https://i.redd.it/test.jpg',
}) {
  return MediaAsset(
    id: id,
    title: 'Test $id',
    author: author,
    score: 100,
    subreddit: subreddit,
    mediaUrl: mediaUrl,
    isVideo: false,
    isGallery: false,
    nsfw: false,
    qualityScore: 50,
    createdUtc: createdUtc,
  );
}

class MockMediaSource extends MediaSource {
  final String label;
  List<List<MediaAsset>> _pages = [];
  int _callCount = 0;
  int _maxCallCount = 999999;
  bool _hasMore = true;
  Duration _delay = Duration.zero;

  MockMediaSource(this.label);

  void setDelay(Duration d) => _delay = d;

  void addPage(List<MediaAsset> items) {
    _pages.add(items);
  }

  void addPages(int count, int itemsPerPage) {
    _maxCallCount = count;
    for (int i = 0; i < count; i++) {
      final items = List<MediaAsset>.generate(
        itemsPerPage,
        (j) => _makeAsset(
          id: '${label}_p${i}_$j',
          subreddit: label,
          author: 'author_$label',
          createdUtc: 2000000 - (i * itemsPerPage + j),
        ),
      );
      _pages.add(items);
    }
  }

  void addSinglePage(int itemCount) {
    final items = List<MediaAsset>.generate(
      itemCount,
      (j) => _makeAsset(
        id: '${label}_$j',
        subreddit: label,
        author: 'author_$label',
        createdUtc: 2000000 - j,
      ),
    );
    _pages = [items];
    _maxCallCount = 1;
  }

  void addUnlimitedPages(int itemsPerPage) {
    _maxCallCount = 999999;
    _pages.clear();
    for (int i = 0; i < 100; i++) {
      final items = List<MediaAsset>.generate(
        itemsPerPage,
        (j) => _makeAsset(
          id: '${label}_p${i}_$j',
          subreddit: label,
          author: 'author_$label',
          createdUtc: 100000000 - (i * itemsPerPage + j),
        ),
      );
      _pages.add(items);
    }
  }

  int get fetchCount => _callCount;
  void reset() { _callCount = 0; }

  @override
  bool get hasMore => _hasMore && _callCount < _maxCallCount;

  @override
  Future<MediaPage> loadNext() async {
    if (_delay > Duration.zero) await Future.delayed(_delay);
    final callIndex = _callCount;
    _callCount++;

    if (callIndex < _pages.length && callIndex < _maxCallCount) {
      return MediaPage(
        items: _pages[callIndex],
        cursor: 'cursor_${callIndex + 1}',
        hasMore: callIndex + 1 < _maxCallCount,
      );
    }
    _hasMore = false;
    return const MediaPage(items: [], cursor: null, hasMore: false);
  }

  @override
  Future<void> dispose() async {}
}

MergeEngine _createEngine(List<MockMediaSource> sources) {
  return MergeEngine(sources: sources);
}

void main() {
  group('SourceBuffer', () {
    test('starts empty with no unconsumed items', () {
      final source = MockMediaSource('test');
      final buffer = SourceBuffer(source: source);
      expect(buffer.hasUnconsumed, false);
      expect(buffer.remainingCount, 0);
      expect(buffer.nextUnconsumed, isNull);
      expect(buffer.hasMore, true);
      expect(buffer.isLoading, false);
    });

    test('tracks consumption pointer', () {
      final source = MockMediaSource('test');
      final items = [
        _makeAsset(id: 'a', subreddit: 'test'),
        _makeAsset(id: 'b', subreddit: 'test'),
      ];
      final buffer = SourceBuffer(source: source, items: items);
      expect(buffer.hasUnconsumed, true);
      expect(buffer.remainingCount, 2);
      expect(buffer.nextUnconsumed?.id, 'a');

      buffer.consumeNext();
      expect(buffer.remainingCount, 1);
      expect(buffer.nextUnconsumed?.id, 'b');

      buffer.consumeNext();
      expect(buffer.hasUnconsumed, false);
      expect(buffer.remainingCount, 0);
      expect(buffer.nextUnconsumed, isNull);

      buffer.consumeNext(); // no-op when empty
      expect(buffer.remainingCount, 0);
    });
  });

  group('MergeEngine distribution', () {
    test('distributes fairly across 2 sources (500 items)', () async {
      final art = MockMediaSource('art');
      final cars = MockMediaSource('cars');
      art.addSinglePage(500);
      cars.addSinglePage(500);

      final engine = _createEngine([art, cars]);
      await engine.initialize();

      final allItems = <MediaAsset>[];
      for (int i = 0; i < 30; i++) {
        if (engine.merged.isNotEmpty) {
          allItems.addAll(engine.drainMerged());
        }
        engine.autoRefill();
      }
      allItems.addAll(engine.drainMerged());

      expect(allItems.length, greaterThanOrEqualTo(200));

      final counts = <String, int>{'art': 0, 'cars': 0};
      for (final item in allItems) {
        counts[item.subreddit] = (counts[item.subreddit] ?? 0) + 1;
      }

      final total = counts.values.fold(0, (a, b) => a + b);
      final artPct = counts['art']! / total;
      final carsPct = counts['cars']! / total;

      expect(artPct, inInclusiveRange(0.20, 0.80));
      expect(carsPct, inInclusiveRange(0.20, 0.80));
      expect(artPct + carsPct, closeTo(1.0, 0.01));
    });

    test('distributes fairly across 4 sources (500 items)', () async {
      final sources = <MockMediaSource>[];
      for (final name in ['art', 'cars', 'nature', 'tech']) {
        final s = MockMediaSource(name);
        s.addSinglePage(500);
        sources.add(s);
      }

      final engine = _createEngine(sources);
      await engine.initialize();

      final allItems = <MediaAsset>[];
      for (int i = 0; i < 30; i++) {
        if (engine.merged.isNotEmpty) {
          allItems.addAll(engine.drainMerged());
        }
        engine.autoRefill();
      }
      allItems.addAll(engine.drainMerged());

      expect(allItems.length, greaterThanOrEqualTo(200));

      final counts = <String, int>{};
      for (final item in allItems) {
        counts[item.subreddit] = (counts[item.subreddit] ?? 0) + 1;
      }

      final total = counts.values.fold(0, (a, b) => a + b);
      for (final entry in counts.entries) {
        final pct = entry.value / total;
        expect(pct, inInclusiveRange(0.10, 0.50));
      }
    });

    test('distributes fairly across 8 sources', () async {
      final sources = <MockMediaSource>[];
      for (final name in ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h']) {
        final s = MockMediaSource(name);
        s.addSinglePage(500);
        sources.add(s);
      }

      final engine = _createEngine(sources);
      await engine.initialize();

      final allItems = <MediaAsset>[];
      for (int i = 0; i < 40; i++) {
        if (engine.merged.isNotEmpty) {
          allItems.addAll(engine.drainMerged());
        }
        engine.autoRefill();
      }
      allItems.addAll(engine.drainMerged());

      expect(allItems.length, greaterThanOrEqualTo(200));

      final counts = <String, int>{};
      for (final item in allItems) {
        counts[item.subreddit] = (counts[item.subreddit] ?? 0) + 1;
      }

      final total = counts.values.fold(0, (a, b) => a + b);
      for (final entry in counts.entries) {
        final pct = entry.value / total;
        expect(pct, inInclusiveRange(0.04, 0.40));
      }
    });
  });

  group('MergeEngine streak enforcement', () {
    test('never exceeds 2 consecutive when multiple buffers have items', () async {
      final art = MockMediaSource('art');
      final cars = MockMediaSource('cars');
      art.addSinglePage(500);
      cars.addSinglePage(500);

      final engine = _createEngine([art, cars]);
      await engine.initialize();

      final allItems = <MediaAsset>[];
      for (int i = 0; i < 50; i++) {
        if (engine.merged.isNotEmpty) allItems.addAll(engine.drainMerged());
        engine.autoRefill();
      }
      allItems.addAll(engine.drainMerged());

      final consumed = <String, int>{};
      int firstExhaustionIndex = allItems.length;
      for (int i = 0; i < allItems.length; i++) {
        consumed[allItems[i].subreddit] = (consumed[allItems[i].subreddit] ?? 0) + 1;
        if (consumed[allItems[i].subreddit] == 500) {
          firstExhaustionIndex = i;
          break;
        }
      }

      int maxStreak = 0;
      int currentStreak = 1;
      for (int i = 1; i <= firstExhaustionIndex; i++) {
        if (allItems[i].subreddit == allItems[i - 1].subreddit) {
          currentStreak++;
          if (currentStreak > maxStreak) maxStreak = currentStreak;
        } else {
          currentStreak = 1;
        }
      }

      expect(maxStreak, lessThanOrEqualTo(2));
      expect(maxStreak, greaterThanOrEqualTo(1));
    });

    test('allows streak >2 when only one buffer has remaining items', () async {
      final art = MockMediaSource('art');
      final cars = MockMediaSource('cars');
      art.addSinglePage(3);
      cars.addSinglePage(500);

      final engine = _createEngine([art, cars]);
      await engine.initialize();

      final allItems = <MediaAsset>[];
      for (int i = 0; i < 50; i++) {
        if (engine.merged.isNotEmpty) allItems.addAll(engine.drainMerged());
        engine.autoRefill();
      }
      allItems.addAll(engine.drainMerged());

      int maxStreak = 0;
      int currentStreak = 1;
      for (int i = 1; i < allItems.length; i++) {
        if (allItems[i].subreddit == allItems[i - 1].subreddit) {
          currentStreak++;
          if (currentStreak > maxStreak) maxStreak = currentStreak;
        } else {
          currentStreak = 1;
        }
      }

      expect(maxStreak, greaterThan(2));
    });
  });

  group('MergeEngine starvation', () {
    test('no source is starved when all have content', () async {
      final sources = <MockMediaSource>[];
      for (final name in ['art', 'cars', 'nature']) {
        final s = MockMediaSource(name);
        s.addSinglePage(500);
        sources.add(s);
      }

      final engine = _createEngine(sources);
      await engine.initialize();

      final allItems = <MediaAsset>[];
      for (int i = 0; i < 40; i++) {
        if (engine.merged.isNotEmpty) allItems.addAll(engine.drainMerged());
        engine.autoRefill();
      }
      allItems.addAll(engine.drainMerged());

      final counts = <String, int>{};
      for (final item in allItems) {
        counts[item.subreddit] = (counts[item.subreddit] ?? 0) + 1;
      }

      final minCount = counts.values.reduce((a, b) => a < b ? a : b);
      expect(minCount, greaterThan(0));
    });

    test('source with no more pages stops contributing gracefully', () async {
      final art = MockMediaSource('art');
      final cars = MockMediaSource('cars');
      art.addSinglePage(500);
      cars.addPages(2, 25);

      final engine = _createEngine([art, cars]);
      await engine.initialize();

      final allItems = <MediaAsset>[];
      for (int i = 0; i < 30; i++) {
        if (engine.merged.isNotEmpty) allItems.addAll(engine.drainMerged());
        engine.autoRefill();
      }
      allItems.addAll(engine.drainMerged());

      final counts = <String, int>{};
      for (final item in allItems) {
        counts[item.subreddit] = (counts[item.subreddit] ?? 0) + 1;
      }

      expect(counts['art']! > counts['cars']!, true);
      expect(engine.hasMoreSources, true);
    });
  });

  group('MergeEngine refill behavior', () {
    test('autoRefill triggers when remainingCount drops below low watermark', () async {
      final art = MockMediaSource('art');
      final cars = MockMediaSource('cars');
      art.addUnlimitedPages(5);
      cars.addUnlimitedPages(5);

      final engine = _createEngine([art, cars]);
      await engine.initialize();

      final initialFetchCount = art.fetchCount + cars.fetchCount;
      for (int i = 0; i < 10; i++) {
        engine.drainMerged();
        engine.autoRefill();
      }
      await Future.delayed(Duration.zero);

      final afterFetchCount = art.fetchCount + cars.fetchCount;
      expect(afterFetchCount, greaterThan(initialFetchCount));
    });

    test('no simultaneous refill for same source', () async {
      final art = MockMediaSource('art');
      final cars = MockMediaSource('cars');
      art.addUnlimitedPages(5);
      cars.addUnlimitedPages(5);

      final engine = _createEngine([art, cars]);
      await engine.initialize();

      engine.buffers[0].isLoading = true;
      final fetchBefore = art.fetchCount;

      engine.autoRefill();
      await Future.delayed(Duration.zero);

      expect(art.fetchCount, fetchBefore);
    });

    test('deduplicates items on buffer refill', () async {
      final art = MockMediaSource('art');
      final existingItems = List<MediaAsset>.generate(
        25,
        (i) => _makeAsset(id: 'dup_$i', subreddit: 'art'),
      );
      final newItems = List<MediaAsset>.generate(
        25,
        (i) => _makeAsset(id: 'new_$i', subreddit: 'art'),
      );

      art.addPage(existingItems);
      art.addPage([
        ...existingItems.take(5),
        ...newItems,
      ]);
      art.addPage(newItems);

      final engine = _createEngine([art]);
      await engine.initialize();
      engine.drainMerged();

      engine.autoRefill();
      await Future.delayed(Duration.zero);

      final buffer = engine.buffers[0];
      expect(buffer.items.length, 50);
    });
  });

  group('MergeEngine lifecycle', () {
    test('initialize creates buffers and generates merged items', () async {
      final art = MockMediaSource('art');
      final cars = MockMediaSource('cars');
      art.addUnlimitedPages(25);
      cars.addUnlimitedPages(25);

      final engine = _createEngine([art, cars]);
      expect(engine.isInitialized, false);

      await engine.initialize();

      expect(engine.isInitialized, true);
      expect(engine.buffers.length, 2);
      expect(engine.merged.isNotEmpty, true);
    });

    test('drainMerged returns items and clears merged list', () async {
      final art = MockMediaSource('art');
      final cars = MockMediaSource('cars');
      art.addUnlimitedPages(25);
      cars.addUnlimitedPages(25);

      final engine = _createEngine([art, cars]);
      await engine.initialize();

      final beforeDrain = engine.merged.length;
      expect(beforeDrain, greaterThan(0));

      final drained = engine.drainMerged();
      expect(drained.length, beforeDrain);
      expect(engine.merged.length, 0);
    });

    test('hasMoreSources returns false when all sources exhausted', () async {
      final art = MockMediaSource('art');
      final cars = MockMediaSource('cars');
      art.addPages(1, 5);
      cars.addPages(1, 5);

      final engine = _createEngine([art, cars]);
      await engine.initialize();

      for (int i = 0; i < 20; i++) {
        engine.drainMerged();
        engine.autoRefill();
      }

      expect(engine.hasMoreSources, false);
    });

    test('dispose clears buffers and merged', () async {
      final art = MockMediaSource('art');
      art.addUnlimitedPages(25);

      final engine = _createEngine([art]);
      await engine.initialize();

      engine.dispose();
      expect(engine.buffers.length, 0);
      expect(engine.merged.length, 0);
    });
  });

  group('MergeEngine scoring', () {
    test('diversity penalty applies for same source', () async {
      final art = MockMediaSource('art');
      final cars = MockMediaSource('cars');
      art.addSinglePage(500);
      cars.addSinglePage(500);

      final engine = _createEngine([art, cars]);
      await engine.initialize();
      engine.drainMerged();

      final items = <MediaAsset>[];
      for (int i = 0; i < 30; i++) {
        if (engine.merged.isNotEmpty) items.addAll(engine.drainMerged());
        engine.autoRefill();
      }
      items.addAll(engine.drainMerged());

      int maxStreak = 0;
      int cur = 1;
      for (int i = 1; i < items.length; i++) {
        if (items[i].subreddit == items[i - 1].subreddit) {
          cur++;
          if (cur > maxStreak) maxStreak = cur;
        } else {
          cur = 1;
        }
      }
      expect(maxStreak, lessThanOrEqualTo(2));
    });
  });

  group('MergeEngine _loadBuffer edge cases', () {
    test('does not load if buffer.isLoading is true', () async {
      final art = MockMediaSource('art');
      art.setDelay(const Duration(milliseconds: 50));
      art.addSinglePage(5);

      final engine = _createEngine([art]);
      await engine.initialize();

      engine.drainMerged();

      engine.buffers[0].isLoading = true;
      final fetchBefore = art.fetchCount;

      engine.autoRefill();
      await Future.delayed(const Duration(milliseconds: 100));

      expect(art.fetchCount, fetchBefore);
    });

    test('does not load if buffer.hasMore is false', () async {
      final art = MockMediaSource('art');
      art.addSinglePage(5);

      final engine = _createEngine([art]);
      await engine.initialize();
      engine.drainMerged();

      engine.buffers[0].hasMore = false;
      engine.buffers[0].isLoading = false;

      final fetchBefore = art.fetchCount;
      engine.autoRefill();
      await Future.delayed(Duration.zero);

      expect(art.fetchCount, fetchBefore);
    });

    test('handles fetch error gracefully', () async {
      final errorSource = MockMediaSource('error');
      // Override loadNext to throw
      errorSource.addSinglePage(1);

      // Create a separate source that always fails
      final failingSource = _FailingMediaSource();

      final engine = MergeEngine(sources: [failingSource]);
      await engine.initialize();

      expect(engine.buffers[0].isLoading, false);
      expect(engine.buffers[0].items.length, 0);
    });
  });
}

class _FailingMediaSource extends MediaSource {
  @override
  bool get hasMore => true;

  @override
  Future<MediaPage> loadNext() async {
    throw Exception('Network error');
  }

  @override
  Future<void> dispose() async {}
}
