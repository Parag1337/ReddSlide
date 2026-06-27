import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:redslide/core/media/media_source.dart';
import 'package:redslide/features/feed/domain/media_asset.dart';
import 'package:redslide/features/slideshow/domain/merge_engine.dart';

class _BenchMediaSource extends MediaSource {
  final String label;
  final List<List<MediaAsset>> _pages = [];
  int _callCount = 0;
  final int maxPages;
  bool _hasMore = true;
  final Duration networkLatency;
  final math.Random _rng;

  _BenchMediaSource({
    required this.label,
    this.maxPages = 100,
    this.networkLatency = const Duration(milliseconds: 50),
    int seed = 42,
  }) : _rng = math.Random(seed);

  void initSubreddit(int itemsPerPage) {
    for (int p = 0; p < maxPages; p++) {
      final items = List<MediaAsset>.generate(
        itemsPerPage,
        (j) => MediaAsset(
          id: '${label}_p${p}_$j',
          title: '$label post $p',
          author: 'author_$label',
          score: _rng.nextInt(1000),
          subreddit: label,
          mediaUrl: 'https://i.redd.it/${label}_${p}_$j.jpg',
          isVideo: false,
          isGallery: false,
          nsfw: false,
          qualityScore: _rng.nextInt(100),
          createdUtc: 2000000000 - (p * itemsPerPage + j),
        ),
      );
      _pages.add(items);
    }
  }

  int get fetchCount => _callCount;

  @override
  bool get hasMore => _hasMore && _callCount < maxPages;

  @override
  Future<MediaPage> loadNext() async {
    await Future.delayed(networkLatency);
    final idx = _callCount;
    _callCount++;
    if (idx < _pages.length) {
      return MediaPage(
        items: _pages[idx],
        cursor: 'cursor_$idx',
        hasMore: idx + 1 < _pages.length,
      );
    }
    _hasMore = false;
    return const MediaPage(items: [], cursor: null, hasMore: false);
  }

  @override
  Future<void> dispose() async {}
}

double _measureMs(void Function() fn) {
  final sw = Stopwatch()..start();
  fn();
  return sw.elapsedMicroseconds / 1000.0;
}

Future<double> _measureAsyncMs(Future<void> Function() fn) async {
  final sw = Stopwatch()..start();
  await fn();
  return sw.elapsedMicroseconds / 1000.0;
}

void main() {
  group('1. MergeEngine Batch Generation Latency', () {
    test('2 subreddits — generateBatch() timing', () async {
      final art = _BenchMediaSource(label: 'art', networkLatency: Duration.zero);
      final cars = _BenchMediaSource(label: 'cars', networkLatency: Duration.zero);
      art.initSubreddit(500);
      cars.initSubreddit(500);

      final engine = MergeEngine(sources: [art, cars]);
      final initMs = await _measureAsyncMs(() => engine.initialize());

      final times = <double>[];
      for (int i = 0; i < 100; i++) {
        times.add(_measureMs(() => engine.generateBatch()));
        engine.drainMerged();
      }

      final avgMs = times.reduce((a, b) => a + b) / times.length;
      final maxMs = times.reduce(math.max);
      final minMs = times.reduce(math.min);

      print('=== MergeEngine: generateBatch() (2 subreddits, 100 runs) ===');
      print('Initialize: ${initMs.toStringAsFixed(2)}ms');
      print('Avg: ${avgMs.toStringAsFixed(4)}ms');
      print('Max: ${maxMs.toStringAsFixed(4)}ms');
      print('Min: ${minMs.toStringAsFixed(4)}ms');
      expect(engine.isInitialized, true);
    });

    test('8 subreddits — generateBatch() timing', () async {
      final sources = <_BenchMediaSource>[];
      for (final name in ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h']) {
        final s = _BenchMediaSource(label: name, networkLatency: Duration.zero);
        s.initSubreddit(500);
        sources.add(s);
      }

      final engine = MergeEngine(sources: sources);
      await engine.initialize();

      final times = <double>[];
      for (int i = 0; i < 100; i++) {
        times.add(_measureMs(() => engine.generateBatch()));
        engine.drainMerged();
      }

      final avgMs = times.reduce((a, b) => a + b) / times.length;
      final maxMs = times.reduce(math.max);
      final minMs = times.reduce(math.min);

      print('=== MergeEngine: generateBatch() (8 sources, 100 runs) ===');
      print('Avg: ${avgMs.toStringAsFixed(4)}ms');
      print('Max: ${maxMs.toStringAsFixed(4)}ms');
      print('Min: ${minMs.toStringAsFixed(4)}ms');
    });

    test('16 sources — generateBatch() timing', () async {
      final names = ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p'];
      final sources = <_BenchMediaSource>[];
      for (final name in names) {
        final s = _BenchMediaSource(label: name, networkLatency: Duration.zero);
        s.initSubreddit(500);
        sources.add(s);
      }

      final engine = MergeEngine(sources: sources);
      await engine.initialize();

      final times = <double>[];
      for (int i = 0; i < 100; i++) {
        times.add(_measureMs(() => engine.generateBatch()));
        engine.drainMerged();
      }

      final avgMs = times.reduce((a, b) => a + b) / times.length;
      final maxMs = times.reduce(math.max);
      final minMs = times.reduce(math.min);

      print('=== MergeEngine: generateBatch() (16 sources, 100 runs) ===');
      print('Avg: ${avgMs.toStringAsFixed(4)}ms');
      print('Max: ${maxMs.toStringAsFixed(4)}ms');
      print('Min: ${minMs.toStringAsFixed(4)}ms');
    });
  });

  group('2. MergeEngine Refill Latency', () {
    test('refill with 50ms network latency (3 subreddits)', () async {
      final sources = <_BenchMediaSource>[];
      for (final name in ['art', 'cars', 'nature']) {
        final s = _BenchMediaSource(label: name, networkLatency: const Duration(milliseconds: 50));
        s.initSubreddit(10);
        sources.add(s);
      }

      final engine = MergeEngine(sources: sources);
      await engine.initialize();
      engine.drainMerged();

      final refillMs = await _measureAsyncMs(() => engine.autoRefill());

      print('=== MergeEngine: autoRefill() (3 sources, 50ms network) ===');
      print('autoRefill() total: ${refillMs.toStringAsFixed(1)}ms');
      final totalFetches = sources.fold(0, (sum, s) => sum + s.fetchCount);
      print('Backend fetches: $totalFetches');
      expect(refillMs, lessThan(200));
    });

    test('refill with 100ms network latency (4 subreddits)', () async {
      final sources = <_BenchMediaSource>[];
      for (final name in ['art', 'cars', 'tech', 'nature']) {
        final s = _BenchMediaSource(label: name, networkLatency: const Duration(milliseconds: 100));
        s.initSubreddit(8);
        sources.add(s);
      }

      final engine = MergeEngine(sources: sources);
      await engine.initialize();
      engine.drainMerged();

      final refillMs = await _measureAsyncMs(() => engine.autoRefill());

      print('=== MergeEngine: autoRefill() (4 sources, 100ms network) ===');
      print('autoRefill() total: ${refillMs.toStringAsFixed(1)}ms');
      final totalFetches = sources.fold(0, (sum, s) => sum + s.fetchCount);
      print('Backend fetches: $totalFetches');
      expect(refillMs, lessThan(300));
    });
  });

  group('3. Continuous Slideshow Throughput', () {
    test('50 transitions, 2 subreddits, 100ms network', () async {
      final art = _BenchMediaSource(label: 'art', networkLatency: const Duration(milliseconds: 100), maxPages: 10);
      final cars = _BenchMediaSource(label: 'cars', networkLatency: const Duration(milliseconds: 100), maxPages: 10);
      art.initSubreddit(25);
      cars.initSubreddit(25);

      final engine = MergeEngine(sources: [art, cars]);
      final initMs = await _measureAsyncMs(() => engine.initialize());

      final totalSw = Stopwatch()..start();
      int totalItems = engine.drainMerged().length;

      for (int i = 0; i < 50; i++) {
        if (engine.hasMoreSources) {
          await engine.autoRefill();
          totalItems += engine.drainMerged().length;
        }
      }
      final totalMs = totalSw.elapsedMilliseconds;

      print('=== Continuous Throughput (50 cycles, 100ms net latency) ===');
      print('Initialize: ${initMs.toStringAsFixed(1)}ms');
      print('Total time: ${totalMs}ms');
      print('Total items: $totalItems');
      final totalFetches = art.fetchCount + cars.fetchCount;
      print('Backend fetches: $totalFetches');
      if (totalMs > 0) {
        print('Avg items/sec: ${(totalItems / totalMs * 1000).toStringAsFixed(0)}');
      }
      print('Avg time per cycle: ${totalMs / 50}ms');
      expect(totalItems, greaterThan(0));
    });
  });
}
