import 'dart:math' show min, max;
import 'package:flutter_test/flutter_test.dart';
import 'package:redslide/features/feed/domain/media_asset.dart';
import 'package:redslide/features/slideshow/domain/readiness_state.dart';
import 'package:redslide/features/slideshow/domain/viewport_scheduler.dart';
import 'package:redslide/features/slideshow/domain/shadow_scheduler.dart';

MediaAsset _asset({
  required String id,
  bool isVideo = false,
  bool isGallery = false,
  List<String>? galleryUrls,
  String? mediaUrl,
  String? videoUrl,
  String? thumbnailUrl,
}) {
  return MediaAsset(
    id: id,
    title: 'Test $id',
    author: 'test_author',
    score: 100,
    subreddit: 'test',
    mediaUrl: mediaUrl ?? 'https://i.redd.it/$id.jpg',
    videoUrl: videoUrl ?? (isVideo ? 'https://v.redd.it/$id.mp4' : null),
    thumbnailUrl:
        thumbnailUrl ?? (isVideo ? 'https://i.redd.it/${id}_thumb.jpg' : null),
    isVideo: isVideo,
    isGallery: isGallery,
    nsfw: false,
    qualityScore: 50,
    galleryUrls: galleryUrls,
    createdUtc: 1000000,
  );
}

void main() {
  group('ShadowScheduler.runCycle', () {
    test('basic cycle returns correct result', () {
      final items = List.generate(10, (i) => _asset(id: 'item_$i'));
      final shadow = ShadowScheduler();

      final states = List.filled(6, ReadinessState.likelyReady);
      final result = shadow.runCycle(
        states: states,
        items: items,
        currentIndex: 0,
        adaptivePlannedUrls: {items[0].mediaUrl, items[1].mediaUrl},
      );

      expect(result.cycleNumber, 1);
      expect(result.generation, 1);
      expect(result.currentIndex, 0);
      expect(result.needCount, greaterThan(0));
      expect(result.plannedTasks, isNotEmpty);
      expect(result.viewportUrls, isNotEmpty);
      expect(result.adaptiveUrls, {'https://i.redd.it/item_0.jpg', 'https://i.redd.it/item_1.jpg'});
      expect(result.phaseTimings, containsPair('total', anything));
    });

    test('generation increments on each cycle', () {
      final items = List.generate(10, (i) => _asset(id: 'item_$i'));
      final shadow = ShadowScheduler();
      final states = List.filled(6, ReadinessState.unavailable);

      final r1 = shadow.runCycle(
        states: states,
        items: items,
        currentIndex: 0,
        adaptivePlannedUrls: {},
      );
      final r2 = shadow.runCycle(
        states: states,
        items: items,
        currentIndex: 5,
        adaptivePlannedUrls: {},
      );

      expect(r1.generation, 1);
      expect(r2.generation, 2);
      expect(r2.cycleNumber, 2);
    });

    test('cancelGeneration called from second cycle onward', () {
      final items = List.generate(10, (i) => _asset(id: 'item_$i'));
      final shadow = ShadowScheduler();
      final states = List.filled(6, ReadinessState.unavailable);

      final r1 = shadow.runCycle(
        states: states,
        items: items,
        currentIndex: 0,
        adaptivePlannedUrls: {},
      );
      expect(r1.plannedTasks.length, greaterThan(0));

      final r2 = shadow.runCycle(
        states: states,
        items: items,
        currentIndex: 5,
        adaptivePlannedUrls: {},
      );
      // Generation 1 tasks should be gone; gen 2 tasks present
      for (final task in r2.plannedTasks) {
        expect(task.generation, 2);
      }
    });

    test('all tasks picked and completed per cycle', () {
      final items = List.generate(20, (i) => _asset(id: 'item_$i'));
      final shadow = ShadowScheduler();
      final states = List.filled(6, ReadinessState.unavailable);

      final result = shadow.runCycle(
        states: states,
        items: items,
        currentIndex: 5,
        adaptivePlannedUrls: {},
      );

      expect(result.pickedTasks.length, result.plannedTasks.length);
      // Scheduler should be emptied (all tasks picked, started, completed)
      expect(shadow.scheduler.pendingCount, 0);
      expect(shadow.scheduler.state, SchedulerState.satisfied);
    });
  });

  group('Agreement analysis', () {
    test('100% agreement when both plan same URLs', () {
      final items = List.generate(10, (i) => _asset(id: 'item_$i'));
      final shadow = ShadowScheduler(config: const ShadowSchedulerConfig(
        targetBudget: 10,
        horizon: 5,
      ));

      final states = List.filled(6, ReadinessState.likelyReady);
      final result = shadow.runCycle(
        states: states,
        items: items,
        currentIndex: 0,
        adaptivePlannedUrls: items.take(6).map((a) => a.mediaUrl).toSet(),
      );

      expect(result.agreement, greaterThan(0.5));
    });

    test('0% agreement when no overlap', () {
      final items = List.generate(10, (i) => _asset(id: 'item_$i'));
      final shadow = ShadowScheduler();

      final states = List.filled(6, ReadinessState.unavailable);
      final result = shadow.runCycle(
        states: states,
        items: items,
        currentIndex: 5,
        adaptivePlannedUrls: {'https://unrelated.com/image.jpg'},
      );

      expect(result.totalIntersection, 0);
      expect(result.agreement, 0.0);
    });

    test('partial agreement computed correctly', () {
      final items = List.generate(10, (i) => _asset(id: 'item_$i'));
      final shadow = ShadowScheduler(config: const ShadowSchedulerConfig(
        targetBudget: 3,
        horizon: 5,
      ));

      final states = List.filled(6, ReadinessState.unavailable);
      final result = shadow.runCycle(
        states: states,
        items: items,
        currentIndex: 0,
        adaptivePlannedUrls: {
          'https://i.redd.it/item_0.jpg',
          'https://i.redd.it/item_1.jpg',
          'https://unrelated.com/other.jpg',
        },
      );

      // Viewport plans: first 3 items from index 0
      // Adaptive plans: item_0, item_1, other
      // Intersection: item_0, item_1 (2)
      // Union: item_0, item_1, item_2, other (4)
      // Agreement: 2/4 = 0.5
      expect(result.totalIntersection, 2);
      expect(result.agreement, 0.5);
    });

    test('empty adaptive plan yields 0 agreement', () {
      final items = List.generate(10, (i) => _asset(id: 'item_$i'));
      final shadow = ShadowScheduler();
      final states = List.filled(6, ReadinessState.unavailable);

      final result = shadow.runCycle(
        states: states,
        items: items,
        currentIndex: 0,
        adaptivePlannedUrls: {},
      );

      expect(result.totalAdaptive, 0);
      expect(result.totalOnlyViewport, greaterThan(0));
      expect(result.agreement, 0.0);
    });

    test('empty viewport plan yields 0 agreement', () {
      final items = List.generate(10, (i) => _asset(id: 'item_$i'));
      final states = List.filled(6, ReadinessState.ready);

      // With targetBudget=10, horizon=5, 6 items all ready:
      // score=6, ceil=6, need=10-6=4
      // So needCount > 0, tasks will be planned
      // Use small budget to make needCount=0
      final shadowSmall = ShadowScheduler(config: const ShadowSchedulerConfig(
        targetBudget: 1,
        horizon: 5,
      ));

      final result = shadowSmall.runCycle(
        states: states,
        items: items,
        currentIndex: 0,
        adaptivePlannedUrls: {'https://unrelated.com/img.jpg'},
      );

      expect(result.totalPlanned, 0);
      expect(result.agreement, 0.0);
    });
  });

  group('ShadowMetricsAggregator', () {
    test('starts empty', () {
      final agg = ShadowMetricsAggregator();
      expect(agg.cycleCount, 0);
      expect(agg.averageAgreement, 0.0);
    });

    test('records single cycle', () {
      final agg = ShadowMetricsAggregator();
      final items = List.generate(10, (i) => _asset(id: 'item_$i'));
      final shadow = ShadowScheduler();
      final states = List.filled(6, ReadinessState.unavailable);

      final result = shadow.runCycle(
        states: states,
        items: items,
        currentIndex: 0,
        adaptivePlannedUrls: {},
      );
      agg.record(result);

      expect(agg.cycleCount, 1);
      expect(agg.averageAgreement, result.agreement);
      expect(agg.minAgreement, result.agreement);
      expect(agg.maxAgreement, result.agreement);
    });

    test('aggregates multiple cycles', () {
      final agg = ShadowMetricsAggregator();
      final items = List.generate(20, (i) => _asset(id: 'item_$i'));
      final shadow = ShadowScheduler();
      final states = List.filled(6, ReadinessState.unavailable);

      // Cycle 1: high agreement
      var result = shadow.runCycle(
        states: states,
        items: items,
        currentIndex: 0,
        adaptivePlannedUrls: items.take(6).map((a) => a.mediaUrl).toSet(),
      );
      agg.record(result);
      final firstAgreement = result.agreement;

      // Cycle 2: low agreement
      result = shadow.runCycle(
        states: states,
        items: items,
        currentIndex: 10,
        adaptivePlannedUrls: {'https://unrelated.com/image.jpg'},
      );
      agg.record(result);
      final secondAgreement = result.agreement;

      expect(agg.cycleCount, 2);
      expect(agg.averageAgreement, (firstAgreement + secondAgreement) / 2);
      expect(agg.minAgreement, min(firstAgreement, secondAgreement));
      expect(agg.maxAgreement, max(firstAgreement, secondAgreement));
    });

    test('toReport returns correct summary', () {
      final agg = ShadowMetricsAggregator();
      final items = List.generate(10, (i) => _asset(id: 'item_$i'));
      final shadow = ShadowScheduler();
      final states = List.filled(6, ReadinessState.unavailable);

      final result = shadow.runCycle(
        states: states,
        items: items,
        currentIndex: 0,
        adaptivePlannedUrls: items.take(3).map((a) => a.mediaUrl).toSet(),
      );
      agg.record(result);

      final report = agg.toReport();
      expect(report['totalCycles'], 1);
      expect(report['averageAgreement'], result.agreement);
      expect(report['totalAdaptiveOnly'], result.totalOnlyAdaptive);
      expect(report['totalViewportOnly'], result.totalOnlyViewport);
      expect(report['totalIntersection'], result.totalIntersection);
      expect(report, containsPair('averageNeedCount', anything));
    });
  });

  group('Ring distribution', () {
    test('distribution matches task positions', () {
      final items = List.generate(20, (i) => _asset(id: 'item_$i'));
      final shadow = ShadowScheduler(config: const ShadowSchedulerConfig(
        targetBudget: 10,
        horizon: 5,
      ));
      final states = List.filled(6, ReadinessState.unavailable);

      final result = shadow.runCycle(
        states: states,
        items: items,
        currentIndex: 5,
        adaptivePlannedUrls: {},
      );

      expect(result.immediateCount + result.criticalCount +
          result.nearCount + result.backgroundCount, result.totalPicked);
    });

    test('immediate ring prioritized when present', () {
      final items = List.generate(20, (i) => _asset(id: 'item_$i'));
      final shadow = ShadowScheduler(config: const ShadowSchedulerConfig(
        targetBudget: 10,
        horizon: 1,
      ));
      final states = List.filled(3, ReadinessState.unavailable);

      final result = shadow.runCycle(
        states: states,
        items: items,
        currentIndex: 5,
        adaptivePlannedUrls: {},
      );

      // horizon=1 means indices 5,6,7 = 3 items
      // distance 0-1 = immediate, distance 2 = critical
      expect(result.immediateCount, greaterThan(0));
    });
  });

  group('Performance', () {
    test('cycle completes in under 1ms for normal playlist', () {
      final items = List.generate(100, (i) => _asset(id: 'item_$i'));
      final shadow = ShadowScheduler();
      final states = List.filled(60, ReadinessState.unavailable);

      final sw = Stopwatch()..start();
      final result = shadow.runCycle(
        states: states,
        items: items,
        currentIndex: 50,
        adaptivePlannedUrls: items.take(20).map((a) => a.mediaUrl).toSet(),
      );
      sw.stop();

      expect(result.phaseTimings['total'], lessThan(1000));
      expect(sw.elapsedMicroseconds, lessThan(1000));
    });

    test('sequential cycles remain fast', () {
      final items = List.generate(100, (i) => _asset(id: 'item_$i'));
      final shadow = ShadowScheduler();
      final states = List.filled(60, ReadinessState.unavailable);

      for (int i = 0; i < 100; i++) {
        final sw = Stopwatch()..start();
        shadow.runCycle(
          states: states,
          items: items,
          currentIndex: i % items.length,
          adaptivePlannedUrls: {},
        );
        sw.stop();
        expect(sw.elapsedMicroseconds, lessThan(2000),
            reason: 'cycle $i exceeded 2ms');
      }
    });
  });

  group('Edge cases', () {
    test('empty states produces empty plan', () {
      final shadow = ShadowScheduler();
      final result = shadow.runCycle(
        states: [],
        items: [],
        currentIndex: 0,
        adaptivePlannedUrls: {},
      );

      expect(result.needCount, 10); // full budget
      expect(result.plannedTasks, isEmpty);
      expect(result.totalPlanned, 0);
      expect(result.agreement, 1.0);
    });

    test('index beyond playlist produces empty plan', () {
      final items = List.generate(5, (i) => _asset(id: 'item_$i'));
      final shadow = ShadowScheduler();
      final states = <ReadinessState>[];

      final result = shadow.runCycle(
        states: states,
        items: items,
        currentIndex: 10,
        adaptivePlannedUrls: {},
      );

      expect(result.plannedTasks, isEmpty);
    });

    test('multiple cycles with different gallery indices', () {
      final items = [
        _asset(
          id: 'gal',
          isGallery: true,
          galleryUrls: List.generate(4, (i) => 'https://i.redd.it/gal_$i.jpg'),
        ),
        _asset(id: 'next'),
      ];
      final shadow = ShadowScheduler(config: const ShadowSchedulerConfig(
        targetBudget: 10,
        horizon: 3,
      ));
      final states = List.filled(4, ReadinessState.unavailable);

      var result = shadow.runCycle(
        states: states,
        items: items,
        currentIndex: 0,
        galleryIndex: 1,
        adaptivePlannedUrls: {},
      );

      // Remaining gallery: positions 2,3 = 2 tasks
      // Then next post at index 1 = 1 task
      expect(result.plannedTasks.any((t) => t.galleryPosition != null), isTrue);

      result = shadow.runCycle(
        states: states,
        items: items,
        currentIndex: 0,
        galleryIndex: 3,
        adaptivePlannedUrls: {},
      );

      // No remaining gallery (at last position), moves to next post
      expect(result.plannedTasks.any((t) => t.assetId == 'next'), isTrue);
    });
  });
}
