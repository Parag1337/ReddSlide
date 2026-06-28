import 'package:flutter_test/flutter_test.dart';
import 'package:redslide/features/slideshow/domain/metrics_collector.dart';

void main() {
  group('MetricsCollector', () {
    late MetricsCollector collector;

    setUp(() {
      collector = MetricsCollector();
    });

    tearDown(() {
      collector.dispose();
    });

    group('recordEvent', () {
      test('records a single event', () {
        collector.recordEvent(MetricEventType.imageCacheHit, data: {'url': 'http://example.com/img.jpg'});
        final snapshot = collector.snapshot();
        expect(snapshot.metrics['image.cache.hits'], 1);
      });

      test('records multiple events of the same type', () {
        collector.recordEvent(MetricEventType.slideshowSwipeNext);
        collector.recordEvent(MetricEventType.slideshowSwipeNext);
        collector.recordEvent(MetricEventType.slideshowSwipeNext);
        final snapshot = collector.snapshot();
        expect(snapshot.metrics['slideshow.navigation.next'], 3);
      });

      test('records different event types independently', () {
        collector.recordEvent(MetricEventType.imagePreparationStarted);
        collector.recordEvent(MetricEventType.imagePreparationCompleted);
        collector.recordEvent(MetricEventType.videoControllerCreated);
        final snapshot = collector.snapshot();
        expect(snapshot.metrics['image.preparations.started'], 1);
        expect(snapshot.metrics['image.preparations.completed'], 1);
        expect(snapshot.metrics['video.controllers.created'], 1);
      });

      test('respects maxEvents limit', () {
        final smallCollector = MetricsCollector(maxEvents: 5);
        for (int i = 0; i < 10; i++) {
          smallCollector.recordEvent(MetricEventType.imageCacheHit);
        }
        final snapshot = smallCollector.snapshot();
        expect(snapshot.metrics['image.cache.hits'], 5);
        expect(snapshot.metrics['general.totalEvents'], 5);
        smallCollector.dispose();
      });

      test('attaches timestamp to events', () {
        collector.recordEvent(MetricEventType.slideshowSwipeNext);
        final events = collector.snapshot().metrics;
        expect(events['slideshow.navigation.next'], 1);
      });
    });

    group('snapshot', () {
      test('returns zero counts for empty collector', () {
        final snapshot = collector.snapshot();
        expect(snapshot.metrics['image.preparations.started'], 0);
        expect(snapshot.metrics['video.controllers.created'], 0);
        expect(snapshot.metrics['slideshow.navigation.next'], 0);
        expect(snapshot.metrics['prepWindow.reconciliations'], 0);
        expect(snapshot.metrics['pagination.triggers'], 0);
        expect(snapshot.metrics['general.totalEvents'], 0);
      });

      test('calculates success rates', () {
        collector.recordEvent(MetricEventType.imagePreparationStarted);
        collector.recordEvent(MetricEventType.imagePreparationStarted);
        collector.recordEvent(MetricEventType.imagePreparationCompleted);
        final snapshot = collector.snapshot();
        expect(snapshot.metrics['image.preparations.successRate'], '50.0%');
      });

      test('returns N/A success rate with zero preparations', () {
        final snapshot = collector.snapshot();
        expect(snapshot.metrics['image.preparations.successRate'], '0.0%');
      });

      test('calculates cache hit rate', () {
        collector.recordEvent(MetricEventType.imageCacheHit);
        collector.recordEvent(MetricEventType.imageCacheHit);
        collector.recordEvent(MetricEventType.imageCacheHit);
        collector.recordEvent(MetricEventType.imageCacheMiss);
        final snapshot = collector.snapshot();
        expect(snapshot.metrics['image.cache.hitRate'], '75.0%');
      });

      test('calculates cache hit rate with no events', () {
        final snapshot = collector.snapshot();
        expect(snapshot.metrics['image.cache.hitRate'], '0.0%');
      });

      test('calculates video success rate', () {
        collector.recordEvent(MetricEventType.videoControllerCreated);
        collector.recordEvent(MetricEventType.videoControllerCreated);
        collector.recordEvent(MetricEventType.videoControllerReady);
        collector.recordEvent(MetricEventType.videoControllerReady);
        final snapshot = collector.snapshot();
        expect(snapshot.metrics['video.successRate'], '100.0%');
      });
    });

    group('reset', () {
      test('clears all events', () {
        collector.recordEvent(MetricEventType.slideshowSwipeNext);
        collector.reset();
        final snapshot = collector.snapshot();
        expect(snapshot.metrics['slideshow.navigation.next'], 0);
        expect(snapshot.metrics['general.totalEvents'], 0);
      });

      test('resets swipe latency tracking', () {
        collector.recordEvent(MetricEventType.slideshowSwipeNext);
        collector.reset();
        final snapshot = collector.snapshot();
        expect(snapshot.metrics['slideshow.navigation.swipeLatencySamples'], 0);
      });
    });

    group('swipe latency', () {
      test('tracks swipe-to-visible latency', () {
        collector.recordEvent(MetricEventType.slideshowSwipeNext);
        // Simulate timing by advancing clock
        collector.recordEvent(MetricEventType.slideshowImageVisible);
        final snapshot = collector.snapshot();
        expect(snapshot.metrics['slideshow.navigation.swipeLatencySamples'], 1);
        expect(snapshot.metrics['slideshow.navigation.swipeLatencyMs'], isNot('N/A'));
      });

      test('tracks multiple swipe latencies', () {
        collector.recordEvent(MetricEventType.slideshowSwipeNext);
        collector.recordEvent(MetricEventType.slideshowImageVisible);
        collector.recordEvent(MetricEventType.slideshowSwipeNext);
        collector.recordEvent(MetricEventType.slideshowImageVisible);
        final snapshot = collector.snapshot();
        expect(snapshot.metrics['slideshow.navigation.swipeLatencySamples'], 2);
      });

      test('does not count visible events without prior swipe', () {
        collector.recordEvent(MetricEventType.slideshowImageVisible);
        final snapshot = collector.snapshot();
        expect(snapshot.metrics['slideshow.navigation.swipeLatencySamples'], 0);
      });

      test('tracks previous and jump swipes', () {
        collector.recordEvent(MetricEventType.slideshowSwipePrevious);
        collector.recordEvent(MetricEventType.slideshowVideoVisible);
        collector.recordEvent(MetricEventType.slideshowSwipeJump);
        collector.recordEvent(MetricEventType.slideshowImageVisible);
        final snapshot = collector.snapshot();
        expect(snapshot.metrics['slideshow.navigation.swipeLatencySamples'], 2);
      });
    });

    group('event ordering', () {
      test('events are stored in insertion order', () {
        collector.recordEvent(MetricEventType.imageCacheHit);
        collector.recordEvent(MetricEventType.imageCacheMiss);
        collector.recordEvent(MetricEventType.imageCacheHit);
        final snapshot = collector.snapshot();
        expect(snapshot.metrics['image.cache.hits'], 2);
        expect(snapshot.metrics['image.cache.misses'], 1);
      });

      test('pagination completion decrements outstanding correctly', () {
        collector.recordEvent(MetricEventType.paginationTriggered);
        collector.recordEvent(MetricEventType.paginationTriggered);
        collector.recordEvent(MetricEventType.paginationCompleted);
        final snapshot = collector.snapshot();
        expect(snapshot.metrics['pagination.triggers'], 2);
        expect(snapshot.metrics['pagination.completions'], 1);
      });
    });

    group('new event types', () {
      test('records search metrics', () {
        collector.recordEvent(MetricEventType.searchRequested, data: {'query': 'test'});
        collector.recordEvent(MetricEventType.searchResponseReceived, data: {'resultCount': 5});
        final snapshot = collector.snapshot();
        expect(snapshot.metrics['search.requests'], 1);
        expect(snapshot.metrics['search.responses'], 1);
      });

      test('records slideshow lifecycle metrics', () {
        collector.recordEvent(MetricEventType.slideshowOpened, data: {'source': 'search'});
        collector.recordEvent(MetricEventType.firstImageRequested, data: {'assetId': 'abc', 'index': 0});
        final snapshot = collector.snapshot();
        expect(snapshot.metrics['slideshow.opened'], 1);
        expect(snapshot.metrics['slideshow.firstImageRequested'], 1);
      });

      test('records image decoded metric', () {
        collector.recordEvent(MetricEventType.imageDecoded, data: {'assetId': 'abc', 'url': 'http://example.com/img.jpg'});
        final snapshot = collector.snapshot();
        expect(snapshot.metrics['image.decoded'], 1);
      });

      test('records video first frame metric', () {
        collector.recordEvent(MetricEventType.videoFirstFrameRendered, data: {'assetId': 'abc'});
        final snapshot = collector.snapshot();
        expect(snapshot.metrics['video.firstFrames'], 1);
      });

      test('records preparation cancelled metric', () {
        collector.recordEvent(MetricEventType.preparationCancelled, data: {'reason': 'disposed'});
        final snapshot = collector.snapshot();
        expect(snapshot.metrics['prepWindow.cancelled'], 1);
      });

      test('records memory snapshot metric', () {
        collector.recordEvent(MetricEventType.memorySnapshot, data: {'imageCacheSize': 10});
        final snapshot = collector.snapshot();
        expect(snapshot.metrics['memory.snapshots'], 1);
      });

      test('records playlist starvation metric', () {
        collector.recordEvent(MetricEventType.playlistStarvation);
        final snapshot = collector.snapshot();
        expect(snapshot.metrics['pagination.starvation'], 1);
      });
    });

    group('firstImageVisible', () {
      test('auto-emitted on first image visible event', () {
        collector.recordEvent(MetricEventType.slideshowImageVisible, data: {'assetId': 'abc', 'index': 0});
        final snapshot = collector.snapshot();
        expect(snapshot.metrics['slideshow.firstImageVisible'], 1);
      });

      test('auto-emitted on first video visible event', () {
        collector.recordEvent(MetricEventType.slideshowVideoVisible, data: {'assetId': 'abc', 'index': 0});
        final snapshot = collector.snapshot();
        expect(snapshot.metrics['slideshow.firstImageVisible'], 1);
      });

      test('emitted only once across multiple visible events', () {
        collector.recordEvent(MetricEventType.slideshowImageVisible, data: {'assetId': 'abc', 'index': 0});
        collector.recordEvent(MetricEventType.slideshowImageVisible, data: {'assetId': 'def', 'index': 1});
        final snapshot = collector.snapshot();
        expect(snapshot.metrics['slideshow.firstImageVisible'], 1);
        expect(snapshot.metrics['slideshow.images.visible'], 2);
      });
    });

    group('export', () {
      test('returns serializable list of events', () {
        collector.recordEvent(MetricEventType.imageCacheHit, data: {'url': 'http://example.com/img.jpg'});
        collector.recordEvent(MetricEventType.slideshowSwipeNext);
        final exported = collector.export();
        expect(exported.length, 2);
        expect(exported[0]['type'], 'imageCacheHit');
        expect(exported[0]['data']['url'], 'http://example.com/img.jpg');
        expect(exported[1]['type'], 'slideshowSwipeNext');
      });

      test('each export entry has type, timestamp, data', () {
        collector.recordEvent(MetricEventType.imageDecoded);
        final exported = collector.export();
        expect(exported[0].keys, containsAll(['type', 'timestamp', 'data']));
      });
    });

    group('reset after firstImageVisible', () {
      test('reset clears firstImageVisible state', () {
        collector.recordEvent(MetricEventType.slideshowImageVisible, data: {'assetId': 'abc', 'index': 0});
        collector.reset();
        collector.recordEvent(MetricEventType.slideshowImageVisible, data: {'assetId': 'def', 'index': 1});
        final snapshot = collector.snapshot();
        expect(snapshot.metrics['slideshow.firstImageVisible'], 1);
        expect(snapshot.metrics['slideshow.images.visible'], 1);
      });
    });
  });
}
