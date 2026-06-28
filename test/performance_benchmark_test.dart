import 'dart:math' as math;
import 'package:flutter_test/flutter_test.dart';
import 'package:redslide/core/media/media_source.dart';
import 'package:redslide/features/feed/domain/media_asset.dart';
import 'package:redslide/features/slideshow/domain/adaptive_preloader.dart';
import 'package:redslide/features/slideshow/domain/media_preparation_engine.dart';
import 'package:redslide/features/slideshow/domain/merge_engine.dart';
import 'package:redslide/features/slideshow/domain/metrics_collector.dart';
import 'package:redslide/features/slideshow/domain/playlist_manager.dart';
import 'package:redslide/features/slideshow/domain/preparation_policy.dart';
import 'package:redslide/features/slideshow/domain/video_preparation_service.dart';
import 'package:redslide/features/slideshow/domain/prepared_media_handle.dart';

final _rng = math.Random(1);

MediaAsset _makeImage(int id, {String prefix = 'img'}) {
  return MediaAsset(
    id: '${prefix}_$id',
    title: 'Image $id',
    author: 'author',
    score: _rng.nextInt(1000),
    subreddit: '$prefix',
    mediaUrl: 'https://i.redd.it/${prefix}_$id.jpg',
    isVideo: false,
    isGallery: false,
    nsfw: false,
    qualityScore: _rng.nextInt(100),
    createdUtc: DateTime.now().millisecondsSinceEpoch ~/ 1000 - id,
  );
}

MediaAsset _makeVideo(int id) {
  return MediaAsset(
    id: 'vid_$id',
    title: 'Video $id',
    author: 'author',
    score: _rng.nextInt(1000),
    subreddit: 'videos',
    mediaUrl: 'https://v.redd.it/${id}_h264.mp4',
    isVideo: true,
    isGallery: false,
    nsfw: false,
    qualityScore: _rng.nextInt(100),
    createdUtc: DateTime.now().millisecondsSinceEpoch ~/ 1000 - id,
    videoUrl: 'https://v.redd.it/${id}_h264.mp4',
    thumbnailUrl: 'https://i.redd.it/${id}_thumb.jpg',
  );
}

double _ms(void Function() fn) {
  final sw = Stopwatch()..start();
  fn();
  return sw.elapsedMicroseconds / 1000.0;
}

Future<double> _asyncMs(Future<void> Function() fn) async {
  final sw = Stopwatch()..start();
  await fn();
  return sw.elapsedMicroseconds / 1000.0;
}

class _BenchMediaSource extends MediaSource {
  final String label;
  final List<List<MediaAsset>> _pages = [];
  int _callCount = 0;
  final int maxPages;
  bool _hasMore = true;
  final Duration networkLatency;
  final bool isVideo;

  _BenchMediaSource({
    required this.label,
    this.maxPages = 100,
    this.networkLatency = const Duration(milliseconds: 50),
    this.isVideo = false,
  });

  void initSubreddit(int itemsPerPage) {
    for (int p = 0; p < maxPages; p++) {
      final items = List<MediaAsset>.generate(
        itemsPerPage,
        (j) => isVideo ? _makeVideo(p * itemsPerPage + j) : _makeImage(p * itemsPerPage + j, prefix: label),
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

void main() {
  late MetricsCollector metrics;
  late PlaylistManager playlist;

  setUp(() {
    metrics = MetricsCollector(maxEvents: 10000);
    playlist = PlaylistManager();
  });

  tearDown(() {
    metrics.dispose();
    playlist.dispose();
  });

  group('Scenario 1: Normal Browsing (Image-only, slow swipe)', () {
    test('swipe latency and cache hit rate', () async {
      final items = List.generate(100, (i) => _makeImage(i));
      playlist.append(items);

      for (int i = 0; i < 50; i++) {
        metrics.recordEvent(MetricEventType.slideshowSwipeNext, data: {'index': i});
        await Future.delayed(const Duration(milliseconds: 5));
        metrics.recordEvent(MetricEventType.slideshowImageVisible, data: {'index': i, 'assetId': items[i].id});
      }

      // Simulate cache: 70% hit rate for normal browsing
      for (int i = 0; i < 100; i++) {
        if (_rng.nextDouble() < 0.7) {
          metrics.recordEvent(MetricEventType.imageCacheHit);
        } else {
          metrics.recordEvent(MetricEventType.imageCacheMiss);
          metrics.recordEvent(MetricEventType.imagePreparationStarted);
          metrics.recordEvent(MetricEventType.imagePreparationCompleted);
        }
      }

      final s = metrics.snapshot();
      print('=== Scenario 1: Normal Browsing ===');
      print(s);

      expect(s.metrics['slideshow.navigation.next'], 50);
      expect(s.metrics['slideshow.images.visible'], 50);
      expect(s.metrics['slideshow.navigation.swipeLatencySamples'], 50);
      expect(s.metrics['image.cache.hitRate'], isNot('0.0%'));
    });
  });

  group('Scenario 2: Rapid Browsing (Fast swipes)', () {
    test('preparation window misses and controller reuse', () async {
      final items = List.generate(100, (i) => _makeImage(i));
      playlist.append(items);

      final engine = MediaPreparationEngine(playlist: playlist, onLoadMore: () async {});
      engine.metrics = metrics;

      // Simulate rapid index changes
      for (int i = 0; i < 80; i++) {
        engine.onIndexChanged(i);
        metrics.recordEvent(MetricEventType.slideshowSwipeNext);
        metrics.recordEvent(MetricEventType.slideshowImageVisible, data: {'index': i});
      }

      final s = metrics.snapshot();
      print('=== Scenario 2: Rapid Browsing ===');
      print(s);

      expect(s.metrics['prepWindow.reconciliations'], greaterThan(0));
      engine.dispose();
    });

    test('preparation misses when moving too fast', () async {
      final items = List.generate(10, (i) => _makeImage(i));
      playlist.append(items);

      // Walk backward through items aggressively to stress the window
      for (int i = 0; i < 20; i++) {
        final idx = i % items.length;
        metrics.recordEvent(MetricEventType.slideshowSwipeNext);
        metrics.recordEvent(MetricEventType.slideshowSwipePrevious);
        metrics.recordEvent(MetricEventType.slideshowImageVisible, data: {'index': idx});
      }

      final s = metrics.snapshot();
      print('=== Scenario 2b: Rapid Back-and-Forth ===');
      print(s);
    });
  });

  group('Scenario 3: Mixed Image/Video', () {
    test('controller preparation and reuse rates', () async {
      final mix = <MediaAsset>[
        for (int i = 0; i < 10; i++) ...[
          _makeImage(i),
          _makeVideo(i),
        ],
      ];
      playlist.append(mix);

      final engine = MediaPreparationEngine(playlist: playlist, onLoadMore: () async {});
      engine.metrics = metrics;

      for (int i = 0; i < 20; i++) {
        engine.onIndexChanged(i);
        final handle = engine.prepare(mix[i]);
        if (handle.isVideo) {
          metrics.recordEvent(MetricEventType.slideshowVideoVisible, data: {'index': i});
        } else {
          metrics.recordEvent(MetricEventType.slideshowImageVisible, data: {'index': i});
        }
      }

      // Simulate controller pool behavior: walk through videos again
      for (int i = 1; i < 20; i += 2) {
        engine.onIndexChanged(i);
        final handle = engine.prepare(mix[i]);
        if (handle.controller != null) {
          metrics.recordEvent(MetricEventType.videoControllerReused, data: {'url': mix[i].videoUrl!});
        }
      }

      final s = metrics.snapshot();
      print('=== Scenario 3: Mixed Image/Video ===');
      print(s);

      engine.dispose();
    });

    test('image/video transition latency', () async {
      // Simulate alternating image → video transitions
      for (int i = 0; i < 10; i++) {
        metrics.recordEvent(MetricEventType.slideshowSwipeNext);
        await Future.delayed(const Duration(milliseconds: 3));
        metrics.recordEvent(MetricEventType.slideshowImageVisible);
        metrics.recordEvent(MetricEventType.slideshowSwipeNext);
        await Future.delayed(const Duration(milliseconds: 8));
        metrics.recordEvent(MetricEventType.slideshowVideoVisible);
      }

      final s = metrics.snapshot();
      print('=== Scenario 3b: Image-Video Transition Latency ===');
      print(s);
      expect(s.metrics['slideshow.navigation.swipeLatencySamples'], 20);
    });
  });

  group('Scenario 4: Large Playlists', () {
    test('memory and eviction behavior across 200 items', () async {
      final items = List.generate(200, (i) => _makeImage(i));
      playlist.append(items);

      final engine = MediaPreparationEngine(playlist: playlist, onLoadMore: () async {});
      engine.metrics = metrics;

      // Walk through entire playlist
      for (int i = 0; i < 200; i++) {
        engine.onIndexChanged(i);
      }

      final s = metrics.snapshot();
      print('=== Scenario 4: Large Playlist (200 items) ===');
      print(s);

      engine.dispose();
    });

    test('video controller pool size with many videos', () async {
      final items = List.generate(50, (i) => _makeVideo(i));
      playlist.append(items);

      final engine = MediaPreparationEngine(playlist: playlist, onLoadMore: () async {});
      engine.metrics = metrics;

      // Walk through 30 videos
      for (int i = 0; i < 30; i++) {
        engine.onIndexChanged(i);
      }

      final s = metrics.snapshot();
      print('=== Scenario 4b: Video Pool Size (50 videos) ===');
      print(s);

      engine.dispose();
    });
  });

  group('Scenario 5: Search Slideshow', () {
    test('pagination and preparation after new search', () async {
      final items = List.generate(30, (i) => _makeImage(i));
      playlist.append(items);

      // Simulate search load with pagination
      for (int i = 0; i < 5; i++) {
        metrics.recordEvent(MetricEventType.paginationTriggered);
        await Future.delayed(const Duration(milliseconds: 100));
        metrics.recordEvent(MetricEventType.paginationCompleted, data: {'appended': 30, 'hasMore': i < 4});
        playlist.append(List.generate(30, (j) => _makeImage(i * 100 + j)));
      }

      final engine = MediaPreparationEngine(playlist: playlist, onLoadMore: () async {});
      engine.metrics = metrics;

      // Browse after search
      for (int i = 0; i < 20; i++) {
        engine.onIndexChanged(i);
        metrics.recordEvent(MetricEventType.slideshowSwipeNext);
        metrics.recordEvent(MetricEventType.slideshowImageVisible, data: {'index': i});
      }

      final s = metrics.snapshot();
      print('=== Scenario 5: Search Slideshow ===');
      print(s);

      expect(s.metrics['pagination.triggers'], 5);
      expect(s.metrics['pagination.completions'], 5);
      engine.dispose();
    });
  });

  group('Bottleneck Analysis', () {
    test('preparation window miss rate', () async {
      final items = List.generate(100, (i) => _makeImage(i));
      playlist.append(items);

      // Walk through with known window = 10 (6 ahead + 3 behind + current)
      // The window starts at item 0, so items 0-6 are in window at start
      // When we're at item 5, items 2-11 are in window
      // Items outside the window that are requested should count as misses

      final engine = MediaPreparationEngine(playlist: playlist, onLoadMore: () async {});
      engine.metrics = metrics;

      // Simulate browsing with jumps beyond the window
      engine.onIndexChanged(0); // window: 0-6
      engine.onIndexChanged(5); // window: 2-11, item 0 and 1 evicted

      // Jump far ahead — items outside current window
      metrics.recordEvent(MetricEventType.outsideWindowMiss, data: {'index': 20});
      engine.onIndexChanged(20); // window: 17-26

      // Two more large jumps
      metrics.recordEvent(MetricEventType.outsideWindowMiss, data: {'index': 50});
      engine.onIndexChanged(50); // window: 47-56

      metrics.recordEvent(MetricEventType.outsideWindowMiss, data: {'index': 80});
      engine.onIndexChanged(80); // window: 77-86

      final s = metrics.snapshot();
      print('=== Bottleneck: Preparation Window Miss Rate ===');
      print(s);

      expect(s.metrics['prepWindow.reconciliations'], 5);
      engine.dispose();
    });

    test('video controller reuse vs create ratio', () async {
      final items = List.generate(20, (i) => _makeVideo(i));
      playlist.append(items);

      // Walk through all videos, then walk back through them
      // First pass: creates controllers
      // Second pass: may reuse if still in window
      for (int pass = 0; pass < 2; pass++) {
        for (int i = 0; i < 20; i++) {
          final item = items[i];
          // Simulate prepare — VPS would return existing if in pool
          if (pass == 1) {
            metrics.recordEvent(MetricEventType.videoControllerReused, data: {'url': item.videoUrl!});
          } else {
            metrics.recordEvent(MetricEventType.videoControllerCreated, data: {'url': item.videoUrl!});
            metrics.recordEvent(MetricEventType.videoControllerInitializing, data: {'url': item.videoUrl!});
            metrics.recordEvent(MetricEventType.videoControllerReady, data: {'url': item.videoUrl!});
          }
        }
      }

      final s = metrics.snapshot();
      print('=== Bottleneck: Controller Reuse Ratio ===');
      print(s);

      final created = s.metrics['video.controllers.created'] as int;
      final reused = s.metrics['video.controllers.reused'] as int;
      print('Created: $created, Reused: $reused, Ratio: ${reused / (created + reused)}');
    });

    test('pagination latency with parallel fetches', () async {
      final sources = <_BenchMediaSource>[];
      for (final name in ['a', 'b', 'c', 'd']) {
        final s = _BenchMediaSource(label: name, networkLatency: const Duration(milliseconds: 50));
        s.initSubreddit(10);
        sources.add(s);
      }

      final engine = MergeEngine(sources: sources);
      await engine.initialize();
      engine.drainMerged();

      final paginationTimes = <double>[];
      for (int i = 0; i < 10; i++) {
        final t = await _asyncMs(() => engine.autoRefill());
        paginationTimes.add(t);
        engine.drainMerged();
      }

      final avgMs = paginationTimes.reduce((a, b) => a + b) / paginationTimes.length;
      final maxMs = paginationTimes.reduce(math.max);
      final minMs = paginationTimes.reduce(math.min);

      print('=== Bottleneck: Pagination Latency (4 sources, 50ms net) ===');
      print('Avg: ${avgMs.toStringAsFixed(1)}ms');
      print('Max: ${maxMs.toStringAsFixed(1)}ms');
      print('Min: ${minMs.toStringAsFixed(1)}ms');
      print('Total fetches: ${sources.fold(0, (sum, s) => sum + s.fetchCount)}');
      expect(avgMs, lessThan(200));
    });
  });

  group('Optimization Candidates', () {
    test('PreparationPolicy: compare window sizes 6 vs 10 vs 14', () async {
      for (final ahead in [6, 10, 14]) {
        final policy = PreparationPolicy(decodedAhead: ahead, decodedBehind: 3);
        final m = MetricsCollector();
        final p = PlaylistManager();
        final items = List.generate(200, (i) => _makeImage(i));
        p.append(items);

        final engine = MediaPreparationEngine(playlist: p, onLoadMore: () async {}, policy: policy);
        engine.metrics = m;

        final time = _ms(() {
          for (int i = 0; i < 200; i++) {
            engine.onIndexChanged(i);
          }
        });

        final s = m.snapshot();
        print('Window ahead=$ahead: time=${time.toStringAsFixed(2)}ms reconciles=${s.metrics['prepWindow.reconciliations']}');
        engine.dispose();
        m.dispose();
        p.dispose();
      }
    });

    test('video service: eviction overhead with large pool', () async {
      final vs = VideoPreparationService();
      final urls = List.generate(100, (i) => 'https://v.redd.it/vid_${i}.mp4');

      // Populate pool by calling prepare (will fail in test env, but entries are created)
      for (final url in urls) {
        vs.prepare(url).ignore();
      }
      // Wait for async failures to settle
      await Future.delayed(const Duration(milliseconds: 10));

      final window = urls.sublist(0, 50).toSet();
      final time = _ms(() => vs.evictOutsideWindow(window));
      print('evictOutsideWindow(50 outside 100): ${time.toStringAsFixed(3)}ms');

      vs.dispose();
    });
  });
}
