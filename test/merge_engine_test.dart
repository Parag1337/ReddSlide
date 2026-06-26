import 'package:flutter_test/flutter_test.dart';
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

class MockFetchController {
  final Map<String, List<List<MediaAsset>>> _pages = {};
  final Map<String, int> _callCount = {};
  final Map<String, int> _maxCallCount = {};
  Duration _delay = Duration.zero;

  void setDelay(Duration d) => _delay = d;

  void addPage(String subreddit, List<MediaAsset> items) {
    _pages.putIfAbsent(subreddit, () => []).add(items);
  }

  void addPages(String subreddit, int count, int itemsPerPage) {
    for (int i = 0; i < count; i++) {
      final items = List<MediaAsset>.generate(
        itemsPerPage,
        (j) => _makeAsset(
          id: '${subreddit}_p${i}_$j',
          subreddit: subreddit,
          author: 'author_$subreddit',
          createdUtc: 2000000 - (i * itemsPerPage + j),
        ),
      );
      addPage(subreddit, items);
    }
  }

  void addSinglePage(String subreddit, int itemCount) {
    final items = List<MediaAsset>.generate(
      itemCount,
      (j) => _makeAsset(
        id: '${subreddit}_$j',
        subreddit: subreddit,
        author: 'author_$subreddit',
        createdUtc: 2000000 - j,
      ),
    );
    _pages[subreddit] = [items];
    _maxCallCount[subreddit] = 1;
  }

  void addUnlimitedPages(String subreddit, int itemsPerPage) {
    _maxCallCount[subreddit] = 999999;
    _pages[subreddit] = [];
    for (int i = 0; i < 100; i++) {
      final items = List<MediaAsset>.generate(
        itemsPerPage,
        (j) => _makeAsset(
          id: '${subreddit}_p${i}_$j',
          subreddit: subreddit,
          author: 'author_$subreddit',
          createdUtc: 100000000 - (i * itemsPerPage + j),
        ),
      );
      _pages[subreddit]!.add(items);
    }
  }

  int get fetchCount => _callCount.values.fold(0, (a, b) => a + b);

  int fetchCountFor(String subreddit) => _callCount[subreddit] ?? 0;

  Future<SubredditPageResult> fetch(String subreddit, {String? cursor}) async {
    if (_delay > Duration.zero) await Future.delayed(_delay);
    final pages = _pages[subreddit] ?? [];
    final callIndex = (_callCount[subreddit] ?? 0);
    _callCount[subreddit] = callIndex + 1;
    final maxCalls = _maxCallCount[subreddit] ?? pages.length;

    if (callIndex < pages.length && callIndex < maxCalls) {
      return SubredditPageResult(
        items: pages[callIndex],
        cursor: 'cursor_${callIndex + 1}',
        hasMore: callIndex + 1 < maxCalls,
      );
    }
    return SubredditPageResult(items: [], cursor: null, hasMore: false);
  }
}

MergeEngine _createEngine(
  List<String> subreddits,
  MockFetchController controller,
) {
  return MergeEngine(
    subreddits: subreddits,
    fetchPage: controller.fetch,
  );
}

void main() {
  group('SubredditBuffer', () {
    test('starts empty with no unconsumed items', () {
      final buffer = SubredditBuffer(subreddit: 'test');
      expect(buffer.hasUnconsumed, false);
      expect(buffer.remainingCount, 0);
      expect(buffer.nextUnconsumed, isNull);
      expect(buffer.hasMore, true);
      expect(buffer.isLoading, false);
    });

    test('tracks consumption pointer', () {
      final items = [
        _makeAsset(id: 'a', subreddit: 'test'),
        _makeAsset(id: 'b', subreddit: 'test'),
      ];
      final buffer = SubredditBuffer(subreddit: 'test', items: items);
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
    test('distributes fairly across 2 subreddits (500 items)', () async {
      final controller = MockFetchController();
      controller.addSinglePage('art', 500);
      controller.addSinglePage('cars', 500);

      final engine = _createEngine(['art', 'cars'], controller);
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

    test('distributes fairly across 4 subreddits (500 items)', () async {
      final controller = MockFetchController();
      for (final sub in ['art', 'cars', 'nature', 'tech']) {
        controller.addSinglePage(sub, 500);
      }

      final engine = _createEngine(['art', 'cars', 'nature', 'tech'], controller);
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

    test('distributes fairly across 8 subreddits', () async {
      final controller = MockFetchController();
      final subs = ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'];
      for (final sub in subs) {
        controller.addSinglePage(sub, 500);
      }

      final engine = _createEngine(subs, controller);
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
      final controller = MockFetchController();
      controller.addSinglePage('art', 500);
      controller.addSinglePage('cars', 500);

      final engine = _createEngine(['art', 'cars'], controller);
      await engine.initialize();

      final allItems = <MediaAsset>[];
      for (int i = 0; i < 50; i++) {
        if (engine.merged.isNotEmpty) allItems.addAll(engine.drainMerged());
        engine.autoRefill();
      }
      allItems.addAll(engine.drainMerged());

      // Count per-subreddit consumption to find when the first buffer empties
      final consumed = <String, int>{};
      int firstExhaustionIndex = allItems.length;
      for (int i = 0; i < allItems.length; i++) {
        consumed[allItems[i].subreddit] = (consumed[allItems[i].subreddit] ?? 0) + 1;
        if (consumed[allItems[i].subreddit] == 500) {
          firstExhaustionIndex = i;
          break;
        }
      }

      // Measure streak only up to firstExhaustionIndex (all buffers still had items)
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
      final controller = MockFetchController();
      controller.addSinglePage('art', 3);  // only 3 items
      controller.addSinglePage('cars', 500); // plenty

      final engine = _createEngine(['art', 'cars'], controller);
      await engine.initialize();

      // Drain all items; after art's 3 items are consumed, only cars remains
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

      // Once art runs out, cars should be allowed to streak
      expect(maxStreak, greaterThan(2));
    });
  });

  group('MergeEngine starvation', () {
    test('no subreddit is starved when all have content', () async {
      final controller = MockFetchController();
      controller.addSinglePage('art', 500);
      controller.addSinglePage('cars', 500);
      controller.addSinglePage('nature', 500);

      final engine = _createEngine(['art', 'cars', 'nature'], controller);
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

      final maxCount = counts.values.reduce((a, b) => a > b ? a : b);
      final minCount = counts.values.reduce((a, b) => a < b ? a : b);
      final disparity = maxCount - minCount;

      expect(minCount, greaterThan(0));
      expect(disparity, lessThan(allItems.length ~/ 2));
    });

    test('subreddit with no more pages stops contributing gracefully', () async {
      final controller = MockFetchController();
      controller.addSinglePage('art', 500);
      controller.addPages('cars', 2, 25); // only 2 pages (50 items)

      final engine = _createEngine(['art', 'cars'], controller);
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
      final controller = MockFetchController();
      controller.addUnlimitedPages('art', 5); // pages of 5 items
      controller.addUnlimitedPages('cars', 5);

      final engine = _createEngine(['art', 'cars'], controller);
      await engine.initialize();

      // Consume items until remaining < 8
      final initialFetchCount = controller.fetchCount;
      for (int i = 0; i < 10; i++) {
        engine.drainMerged();
        engine.autoRefill();
      }
      await Future.delayed(Duration.zero);

      final refillFetchCount = controller.fetchCount;
      expect(refillFetchCount, greaterThan(initialFetchCount));
    });

    test('no simultaneous refill for same subreddit', () async {
      final controller = MockFetchController();
      controller.addUnlimitedPages('art', 5);
      controller.addUnlimitedPages('cars', 5);

      final engine = _createEngine(['art', 'cars'], controller);
      await engine.initialize();

      // Set loading state manually to simulate in-flight load
      engine.buffers[0].isLoading = true;
      final fetchBefore = controller.fetchCountFor('art');

      // autoRefill checks isLoading before triggering load
      engine.autoRefill();
      await Future.delayed(Duration.zero);

      final fetchAfter = controller.fetchCountFor('art');
      expect(fetchAfter, fetchBefore);
    });

    test('deduplicates items on buffer refill', () async {
      final controller = MockFetchController();
      final existingItems = List<MediaAsset>.generate(
        25,
        (i) => _makeAsset(id: 'dup_$i', subreddit: 'art'),
      );
      final newItems = List<MediaAsset>.generate(
        25,
        (i) => _makeAsset(id: 'new_$i', subreddit: 'art'),
      );

      // First page has items, second page has duplicates + new items
      controller.addPage('art', existingItems);
      controller.addPage('art', [
        ...existingItems.take(5),
        ...newItems,
      ]);
      controller.addPage('art', newItems);

      final engine = _createEngine(['art'], controller);
      await engine.initialize();
      engine.drainMerged();

      engine.autoRefill();
      await Future.delayed(Duration.zero);

      final buffer = engine.buffers[0];
      expect(buffer.items.length, 50); // 25 existing + 25 new (5 dupes skipped)
    });
  });

  group('MergeEngine lifecycle', () {
    test('initialize creates buffers and generates merged items', () async {
      final controller = MockFetchController();
      controller.addUnlimitedPages('art', 25);
      controller.addUnlimitedPages('cars', 25);

      final engine = _createEngine(['art', 'cars'], controller);
      expect(engine.isInitialized, false);

      await engine.initialize();

      expect(engine.isInitialized, true);
      expect(engine.buffers.length, 2);
      expect(engine.merged.isNotEmpty, true);
    });

    test('drainMerged returns items and clears merged list', () async {
      final controller = MockFetchController();
      controller.addUnlimitedPages('art', 25);
      controller.addUnlimitedPages('cars', 25);

      final engine = _createEngine(['art', 'cars'], controller);
      await engine.initialize();

      final beforeDrain = engine.merged.length;
      expect(beforeDrain, greaterThan(0));

      final drained = engine.drainMerged();
      expect(drained.length, beforeDrain);
      expect(engine.merged.length, 0);
    });

    test('hasMoreSources returns false when all buffers exhausted', () async {
      final controller = MockFetchController();
      controller.addPages('art', 1, 5);
      controller.addPages('cars', 1, 5);

      final engine = _createEngine(['art', 'cars'], controller);
      await engine.initialize();

      for (int i = 0; i < 20; i++) {
        engine.drainMerged();
        engine.autoRefill();
      }

      expect(engine.hasMoreSources, false);
    });

    test('dispose clears buffers and merged', () async {
      final controller = MockFetchController();
      controller.addUnlimitedPages('art', 25);

      final engine = _createEngine(['art'], controller);
      await engine.initialize();

      engine.dispose();
      expect(engine.buffers.length, 0);
      expect(engine.merged.length, 0);
    });
  });

  group('MergeEngine scoring', () {
    test('diversity penalty applies for same subreddit', () async {
      final controller = MockFetchController();
      controller.addSinglePage('art', 500);
      controller.addSinglePage('cars', 500);

      final engine = _createEngine(['art', 'cars'], controller);
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
      final controller = MockFetchController();
      controller.setDelay(const Duration(milliseconds: 50));
      controller.addSinglePage('art', 5); // small page so refill would trigger

      final engine = _createEngine(['art'], controller);
      await engine.initialize();

      // Consume remaining items so autoRefill would try to load
      engine.drainMerged();

      engine.buffers[0].isLoading = true;
      final fetchBefore = controller.fetchCountFor('art');

      engine.autoRefill();
      await Future.delayed(const Duration(milliseconds: 100));

      expect(controller.fetchCountFor('art'), fetchBefore);
    });

    test('does not load if buffer.hasMore is false', () async {
      final controller = MockFetchController();
      controller.addSinglePage('art', 5);

      final engine = _createEngine(['art'], controller);
      await engine.initialize();
      engine.drainMerged();

      // hasMore is already false (single page)
      engine.buffers[0].hasMore = false;
      engine.buffers[0].isLoading = false;

      final fetchBefore = controller.fetchCountFor('art');
      engine.autoRefill();
      await Future.delayed(Duration.zero);

      expect(controller.fetchCountFor('art'), fetchBefore);
    });

    test('handles fetch error gracefully', () async {
      final controller = MockFetchController();
      controller.addUnlimitedPages('art', 25);

      // Replace fetch with error-throwing version
      final errorEngine = MergeEngine(
        subreddits: ['error_sub'],
        fetchPage: (subreddit, {String? cursor}) async {
          throw Exception('Network error');
        },
      );

      await errorEngine.initialize();
      expect(errorEngine.buffers[0].initialLoaded, true);
      expect(errorEngine.buffers[0].isLoading, false);
      expect(errorEngine.buffers[0].items.length, 0);
    });
  });
}
