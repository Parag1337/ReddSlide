import 'package:flutter_test/flutter_test.dart';
import 'package:redslide/features/slideshow/domain/slide_profiler.dart';

void main() {
  group('A4: SlideProfiler bounded collections', () {
    setUp(() {
      SlideProfiler.enabled = true;
      SlideProfiler.reset();
    });

    test('profiler output unchanged with caps', () {
      // Record a simple scenario and verify the JSON output shape
      SlideProfiler.setSourceType('test');
      SlideProfiler.recordQueueTimestamp('https://example.com/img1.jpg', 'asset1');
      SlideProfiler.recordPreparingTimestamp('https://example.com/img1.jpg', 'asset1');
      SlideProfiler.recordDownloadStart('https://example.com/img1.jpg');
      SlideProfiler.recordDownloadComplete('https://example.com/img1.jpg', sizeBytes: 50000);
      SlideProfiler.recordReady('https://example.com/img1.jpg');
      SlideProfiler.recordFirstPaint('https://example.com/img1.jpg', wasCached: false);

      SlideProfiler.sampleWorkers(1, 3);
      SlideProfiler.sampleQueueLength(0);
      SlideProfiler.recordQueueExit('https://example.com/img1.jpg');
      SlideProfiler.recordWidgetRequest('https://example.com/img1.jpg');

      final json = SlideProfiler.dumpJson();
      expect(json['enabled'], isNot(false));
      expect(json['sourceType'], 'test');
      expect(json['workers']['samples'], 1);
      expect(json['queue']['totalEnqueued'], 1);
      expect(json['queue']['totalDequeued'], 1);
      expect(json['images']['timelines'], 1);
    });

    test('memory bounded — _queueWaitMs does not grow unbounded', () {
      for (int i = 0; i < 1000; i++) {
        SlideProfiler.recordQueueTimestamp('https://example.com/img$i.jpg', null);
        SlideProfiler.recordQueueExit('https://example.com/img$i.jpg');
      }
      final json = SlideProfiler.dumpJson();
      final queue = json['queue'] as Map;
      expect(queue['waitSamples'], lessThanOrEqualTo(500),
          reason: '_queueWaitMs should be capped at 500');
    });

    test('memory bounded — _videoInitDurationsMs does not grow unbounded', () {
      for (int i = 0; i < 500; i++) {
        SlideProfiler.recordVideoInitStart('https://example.com/vid$i.mp4');
        SlideProfiler.recordVideoInitEnd('https://example.com/vid$i.mp4', success: true);
      }
      final json = SlideProfiler.dumpJson();
      final video = json['video'] as Map;
      expect(video['initSamples'], lessThanOrEqualTo(200),
          reason: '_videoInitDurationsMs should be capped at 200');
    });

    test('memory bounded — _preparingDurationsMs does not grow unbounded', () {
      for (int i = 0; i < 1000; i++) {
        final url = 'https://example.com/img$i.jpg';
        SlideProfiler.recordQueueTimestamp(url, null);
        SlideProfiler.recordPreparingTimestamp(url, null);
        SlideProfiler.recordQueueExit(url);
        SlideProfiler.recordStateTransition(url, 'ready');
      }
      final json = SlideProfiler.dumpJson();
      final images = json['images'] as Map;
      final prep = images['preparingDurationMs'] as Map;
      expect(prep['samples'], lessThanOrEqualTo(500),
          reason: '_preparingDurationsMs should be capped at 500');
    });

    test('memory bounded — _sourceStats lists cap at 500', () {
      SlideProfiler.setSourceType('subreddit');
      for (int i = 0; i < 1000; i++) {
        SlideProfiler.recordSourceQueueWait(i);
        SlideProfiler.recordSourceDownloadMs(i);
        SlideProfiler.recordSourceDecodeMs(i);
      }
      final json = SlideProfiler.dumpJson();
      final bySource = json['bySource'] as Map;
      final stats = bySource['subreddit'] as Map;
      expect(stats['queueWaitSamples'], lessThanOrEqualTo(500),
          reason: '_SourceStats.queueWaitMs should be capped at 500');
    });
  });
}
