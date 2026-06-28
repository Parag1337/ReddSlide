import 'package:flutter_test/flutter_test.dart';
import 'package:redslide/features/feed/domain/media_asset.dart';
import 'package:redslide/features/slideshow/domain/readiness_state.dart';
import 'package:redslide/features/slideshow/domain/scheduler_task.dart';
import 'package:redslide/features/slideshow/domain/viewport_scheduler.dart';
import 'scheduler_pipeline_harness.dart';

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

ReadinessSimulator readinessAt(Map<int, ReadinessState> map) {
  return (playlist, index) => map[index] ?? ReadinessState.ready;
}

ReadinessSimulator readinessForIndices(
    List<int> ready, List<int> likelyReady, List<int> unavailable) {
  final map = <int, ReadinessState>{};
  for (final i in ready) map[i] = ReadinessState.ready;
  for (final i in likelyReady) map[i] = ReadinessState.likelyReady;
  for (final i in unavailable) map[i] = ReadinessState.unavailable;
  return (playlist, index) => map[index] ?? ReadinessState.ready;
}

Ring _computeRingForTask(SchedulerTask task, int currentIndex, int horizon) {
  final distance = (task.index - currentIndex).abs();
  Ring base;
  if (distance <= 1) {
    base = Ring.immediate;
  } else if (distance <= 1 + horizon) {
    base = Ring.critical;
  } else if (distance <= 1 + horizon * 2) {
    base = Ring.near;
  } else {
    base = Ring.background;
  }
  if (task.galleryPosition != null && base != Ring.immediate) {
    switch (base) {
      case Ring.critical:
        return Ring.immediate;
      case Ring.near:
        return Ring.critical;
      case Ring.background:
        return Ring.near;
      default:
        return base;
    }
  }
  return base;
}

void main() {
  group('Standard Navigation', () {
    test('0 -> 1 -> 2 -> 3 produces expected work at each step', () {
      final items = List.generate(50, (i) => _asset(id: 'item_$i'));
      final harness = SchedulerPipelineHarness(
        playlist: items,
        targetBudget: 10,
        horizon: 5,
        readinessSimulator: (p, i) => ReadinessState.unavailable,
      );

      for (final idx in [0, 1, 2, 3]) {
        final result = harness.navigate(idx);
        expect(result.needCount, greaterThan(0),
            reason: 'needCount should be > 0 at index $idx');
        expect(result.plannedTasks.length,
            allOf(
              greaterThan(0),
              lessThanOrEqualTo(result.needCount),
            ),
            reason: 'planner produces tasks but does not exceed needCount at index $idx');
        expect(result.scheduler.state, SchedulerState.active,
            reason: 'scheduler active at index $idx');

        final seen = <String>{};
        for (final task in result.plannedTasks) {
          final key = '${task.url}:${task.generation}';
          expect(seen.contains(key), isFalse,
              reason: 'no duplicate tasks at index $idx');
          seen.add(key);
          expect(task.generation, result.generation,
              reason: 'task generation matches at index $idx');
        }

        // Golden Rule: pick tasks in order and verify never background before immediate
        final pickOrder = <SchedulerTask>[];
        while (true) {
          final t = result.scheduler.pickTask();
          if (t == null) break;
          pickOrder.add(t);
          result.scheduler.markStarted(t);
          result.scheduler.markCompleted(t);
        }

        for (int i = 0; i < pickOrder.length; i++) {
          final ringA = _computeRingForTask(pickOrder[i], idx, 5);
          for (int j = i + 1; j < pickOrder.length; j++) {
            final ringB = _computeRingForTask(pickOrder[j], idx, 5);
            if (ringB.index < ringA.index) {
              fail(
                  'Golden rule violated at index $idx: '
                  'task ${pickOrder[j].assetId} (ring $ringB) picked after '
                  '${pickOrder[i].assetId} (ring $ringA)');
            }
          }
        }
      }
    });
  });

  group('Rapid Swiping', () {
    test('0 -> 5 -> 10 -> 18 -> 26 -> 40 generation behavior', () {
      final items = List.generate(100, (i) => _asset(id: 'item_$i'));
      final harness = SchedulerPipelineHarness(
        playlist: items,
        targetBudget: 8,
        horizon: 5,
        readinessSimulator: readinessAt({}),
      );

      final indices = [0, 5, 10, 18, 26, 40];
      for (int step = 0; step < indices.length; step++) {
        final idx = indices[step];
        final oldGen = harness.generation;
        final result = harness.navigate(idx);
        final newGen = result.generation;

        expect(newGen, greaterThan(oldGen),
            reason: 'generation incremented at step $step');

        // Old generation tasks should be gone from pending
        while (true) {
          final t = result.scheduler.pickTask();
          if (t == null) break;
          expect(t.generation, newGen,
              reason:
                  'all pending tasks have current generation at step $step');
          result.scheduler.markStarted(t);
          result.scheduler.markCompleted(t);
        }

        // No duplicate tasks
        final seen = <String>{};
        for (final task in result.plannedTasks) {
          final key = '${task.url}:${task.generation}';
          expect(seen.contains(key), isFalse,
              reason: 'no duplicate at step $step');
          seen.add(key);
        }
      }
    });
  });

  group('Large Jump', () {
    test('current=10 -> 250: new gen, old pending discarded, in-flight '
        'survives', () {
      final items = List.generate(500, (i) => _asset(id: 'item_$i'));
      final harness = SchedulerPipelineHarness(
        playlist: items,
        targetBudget: 10,
        horizon: 5,
        readinessSimulator: readinessAt({}),
      );

      // Navigate to index 10
      final first = harness.navigate(10);
      final firstGen = first.generation;

      // Pick a task and mark it in-flight
      final inFlightTask = first.scheduler.pickTask()!;
      first.scheduler.markStarted(inFlightTask);
      expect(first.scheduler.isEmpty, isFalse,
          reason: 'not empty with in-flight task');

      // Large jump to 250
      final second = harness.navigate(250);
      final secondGen = second.generation;

      expect(secondGen, greaterThan(firstGen),
          reason: 'new generation after jump');

      // In-flight task from gen 1 still tracked (not failed, not completed)
      expect(first.scheduler.isEmpty, isFalse,
          reason: 'in-flight task still tracked');

      // Pending tasks are all from new generation
      final seen = <String>{};
      while (true) {
        final t = second.scheduler.pickTask();
        if (t == null) break;
        expect(t.generation, secondGen,
            reason: 'all pending tasks from new generation');
        expect(t.index, greaterThanOrEqualTo(250),
            reason: 'tasks around new viewport');
        expect(t.index, lessThanOrEqualTo(255),
            reason: 'tasks within horizon of new viewport');
        final key = '${t.url}:${t.generation}';
        expect(seen.contains(key), isFalse, reason: 'no duplicates');
        seen.add(key);
        second.scheduler.markStarted(t);
        second.scheduler.markCompleted(t);
      }
    });
  });

  group('Reverse Jump', () {
    test('250 -> 40: same guarantees as forward jump', () {
      final items = List.generate(500, (i) => _asset(id: 'item_$i'));
      final harness = SchedulerPipelineHarness(
        playlist: items,
        targetBudget: 10,
        horizon: 5,
        readinessSimulator: readinessAt({}),
      );

      final first = harness.navigate(250);
      final firstGen = first.generation;

      final inFlightTask = first.scheduler.pickTask()!;
      first.scheduler.markStarted(inFlightTask);

      final second = harness.navigate(40);
      final secondGen = second.generation;

      expect(secondGen, greaterThan(firstGen),
          reason: 'new generation after reverse jump');

      expect(first.scheduler.isEmpty, isFalse,
          reason: 'in-flight task survives reverse jump');

      final seen = <String>{};
      while (true) {
        final t = second.scheduler.pickTask();
        if (t == null) break;
        expect(t.generation, secondGen,
            reason: 'all pending from new gen after reverse jump');
        expect(t.index,
            allOf(greaterThanOrEqualTo(40), lessThanOrEqualTo(45)),
            reason: 'tasks around new viewport');
        final key = '${t.url}:${t.generation}';
        expect(seen.contains(key), isFalse, reason: 'no duplicates');
        seen.add(key);
        second.scheduler.markStarted(t);
        second.scheduler.markCompleted(t);
      }
    });
  });

  group('Empty Playlist', () {
    test('pipeline remains stable with empty playlist', () {
      final harness = SchedulerPipelineHarness(
        playlist: [],
        targetBudget: 10,
        horizon: 5,
        readinessSimulator: (playlist, index) => ReadinessState.ready,
      );

      // Should not crash
      final result = harness.navigate(0);
      // Empty playlist → empty states → computeNeedCount returns full budget
      // But planner receives empty items → returns []
      expect(result.plannedTasks, isEmpty);
      expect(result.scheduler.pendingCount, 0);
      expect(result.scheduler.pickTask(), isNull);
    });
  });

  group('Beginning Of Playlist', () {
    test('window clipped correctly at index 0', () {
      final items = List.generate(100, (i) => _asset(id: 'item_$i'));
      final harness = SchedulerPipelineHarness(
        playlist: items,
        targetBudget: 10,
        horizon: 5,
        readinessSimulator: readinessAt({}),
      );

      final result = harness.navigate(0);
      for (final task in result.plannedTasks) {
        expect(task.index, greaterThanOrEqualTo(0),
            reason: 'no negative indices');
        expect(task.index, lessThanOrEqualTo(5),
            reason: 'within horizon from 0');
      }
    });
  });

  group('End Of Playlist', () {
    test('window clipped correctly at last index', () {
      final items = List.generate(10, (i) => _asset(id: 'item_$i'));
      final harness = SchedulerPipelineHarness(
        playlist: items,
        targetBudget: 10,
        horizon: 5,
        readinessSimulator: readinessAt({}),
      );

      final result = harness.navigate(9);
      for (final task in result.plannedTasks) {
        expect(task.index, greaterThanOrEqualTo(9),
            reason: 'no indices beyond end');
        expect(task.index, lessThanOrEqualTo(9),
            reason: 'at or before last index');
      }

      // Planner should only produce tasks for index 9
      expect(result.plannedTasks.length, 1);
    });

    test('no invalid tasks at end', () {
      final items = List.generate(10, (i) => _asset(id: 'item_$i'));
      final harness = SchedulerPipelineHarness(
        playlist: items,
        targetBudget: 10,
        horizon: 5,
        readinessSimulator: readinessAt({}),
      );

      final result = harness.navigate(10);
      // currentIndex >= items.length → planner returns []
      expect(result.plannedTasks, isEmpty);
      expect(result.scheduler.pendingCount, 0);
      expect(result.scheduler.pickTask(), isNull);
    });
  });

  group('Gallery Navigation', () {
    test('remaining gallery images appear before next post', () {
      final items = [
        _asset(
          id: 'gal',
          isGallery: true,
          galleryUrls: List.generate(
            8,
            (i) => 'https://i.redd.it/gal_$i.jpg',
          ),
        ),
        _asset(id: 'a'),
        _asset(id: 'b'),
      ];
      final harness = SchedulerPipelineHarness(
        playlist: items,
        targetBudget: 20,
        horizon: 5,
        readinessSimulator: readinessAt({}),
      );

      // Navigate to gallery, position 1
      var result = harness.navigate(0, galleryIndex: 1);
      expect(result.plannedTasks.length, greaterThan(0));

      // Remaining gallery images should come first
      var seenRemaining = false;
      var seenNextPost = false;
      for (final task in result.plannedTasks) {
        if (task.assetId == 'gal' &&
            task.galleryPosition != null &&
            task.galleryPosition! > 1) {
          seenRemaining = true;
          expect(seenNextPost, isFalse,
              reason:
                  'remaining gallery images before next post');
        }
        if (task.assetId == 'a' || task.assetId == 'b') {
          seenNextPost = true;
        }
      }
      expect(seenRemaining, isTrue,
          reason: 'remaining gallery images planned');

      // Navigate to gallery position 2
      result = harness.navigate(0, galleryIndex: 2);
      seenRemaining = false;
      seenNextPost = false;
      for (final task in result.plannedTasks) {
        if (task.assetId == 'gal' &&
            task.galleryPosition != null &&
            task.galleryPosition! > 2) {
          seenRemaining = true;
          expect(seenNextPost, isFalse,
              reason: 'position 2: remaining before next post');
        }
        if (task.assetId == 'a' || task.assetId == 'b') {
          seenNextPost = true;
        }
      }

      // Navigate to gallery position 3
      result = harness.navigate(0, galleryIndex: 3);
      seenRemaining = false;
      for (final task in result.plannedTasks) {
        if (task.assetId == 'gal' &&
            task.galleryPosition != null &&
            task.galleryPosition! > 3) {
          seenRemaining = true;
        }
      }
    });

    test('ring ordering enforced with gallery promotion', () {
      final items = [
        _asset(id: 'a'),
        _asset(
          id: 'gal',
          isGallery: true,
          galleryUrls: List.generate(4, (i) => 'https://i.redd.it/gal_$i.jpg'),
        ),
        _asset(id: 'c'),
        _asset(id: 'd'),
        _asset(id: 'e'),
        _asset(id: 'f'),
      ];
      final harness = SchedulerPipelineHarness(
        playlist: items,
        targetBudget: 10,
        horizon: 5,
        readinessSimulator: readinessAt({}),
      );

      final result = harness.navigate(0);

      // All tasks picked in correct ring order
      final pickOrder = <SchedulerTask>[];
      final s = result.scheduler;
      while (true) {
        final t = s.pickTask();
        if (t == null) break;
        pickOrder.add(t);
        s.markStarted(t);
        s.markCompleted(t);
      }

      for (int i = 0; i < pickOrder.length; i++) {
        final ringA = _computeRingForTask(pickOrder[i], 0, 5);
        for (int j = i + 1; j < pickOrder.length; j++) {
          final ringB = _computeRingForTask(pickOrder[j], 0, 5);
          expect(ringB.index, greaterThanOrEqualTo(ringA.index),
              reason:
                  'ring order maintained: ${pickOrder[i].assetId} ($ringA) '
                  'before ${pickOrder[j].assetId} ($ringB)');
        }
      }
    });
  });

  group('Mixed Media', () {
    test('deterministic pipeline with mixed content', () {
      final items = [
        _asset(id: 'img0'),
        _asset(id: 'img1'),
        _asset(id: 'vid', isVideo: true),
        _asset(
          id: 'gal',
          isGallery: true,
          galleryUrls: [
            'https://i.redd.it/gal_0.jpg',
            'https://i.redd.it/gal_1.jpg',
            'https://i.redd.it/gal_2.jpg',
          ],
        ),
        _asset(id: 'img2'),
      ];

      final sim = readinessForIndices(
        [0, 3],
        [1, 4],
        [2],
      );

      // Run twice, expect identical results
      final h1 = SchedulerPipelineHarness(
        playlist: List.from(items),
        targetBudget: 10,
        horizon: 10,
        readinessSimulator: sim,
      );
      final h2 = SchedulerPipelineHarness(
        playlist: List.from(items),
        targetBudget: 10,
        horizon: 10,
        readinessSimulator: sim,
      );

      final r1 = h1.navigate(0);
      final r2 = h2.navigate(0);

      expect(r1.needCount, r2.needCount);
      expect(r1.plannedTasks.length, r2.plannedTasks.length);
      for (int i = 0; i < r1.plannedTasks.length; i++) {
        expect(r1.plannedTasks[i].url, r2.plannedTasks[i].url);
        expect(r1.plannedTasks[i].generation, r2.plannedTasks[i].generation);
        expect(r1.plannedTasks[i].mediaType, r2.plannedTasks[i].mediaType);
      }

      // Consume both schedulers identically
      while (true) {
        final t1 = r1.scheduler.pickTask();
        final t2 = r2.scheduler.pickTask();
        if (t1 == null && t2 == null) break;
        expect(t1, isNotNull);
        expect(t2, isNotNull);
        expect(t1!.url, t2!.url);
        r1.scheduler.markStarted(t1);
        r1.scheduler.markCompleted(t1);
        r2.scheduler.markStarted(t2);
        r2.scheduler.markCompleted(t2);
      }
    });
  });

  group('Fully Ready Window', () {
    test('needCount zero when window exceeds budget with all ready', () {
      final items = List.generate(20, (i) => _asset(id: 'item_$i'));
      final harness = SchedulerPipelineHarness(
        playlist: items,
        targetBudget: 10,
        horizon: 9,
        readinessSimulator: (p, i) => ReadinessState.ready,
      );

      final result = harness.navigate(0);
      // Window: indices 0..9 = 10 items, all ready, score=10, ceil=10, need=10-10=0
      expect(result.needCount, 0,
          reason: 'no demand when window fully covers budget with ready states');
      expect(result.plannedTasks, isEmpty,
          reason: 'no tasks when needCount is 0');
      expect(result.scheduler.state, SchedulerState.satisfied,
          reason: 'scheduler satisfied when no work needed');
    });
  });

  group('Completely Empty Window', () {
    test('needCount equals target budget when everything unavailable', () {
      final items = List.generate(20, (i) => _asset(id: 'item_$i'));
      final harness = SchedulerPipelineHarness(
        playlist: items,
        targetBudget: 7,
        horizon: 10,
        readinessSimulator: (p, i) => ReadinessState.unavailable,
      );

      final result = harness.navigate(0);
      // Window: indices 0..10 = 11 items, all unavailable, score=0, ceil=0, need=7-0=7
      expect(result.needCount, 7,
          reason: 'full budget needed when nothing is ready');
      expect(result.plannedTasks.length, 7,
          reason: 'planner generates needCount tasks');
      expect(result.scheduler.state, SchedulerState.active,
          reason: 'scheduler active with pending tasks');
    });
  });

  group('Duplicate URLs', () {
    test('same URL in different generations creates separate tasks', () {
      final items = List.generate(10, (i) => _asset(id: 'item_$i'));
      final harness = SchedulerPipelineHarness(
        playlist: items,
        targetBudget: 10,
        horizon: 5,
        readinessSimulator: readinessAt({}),
      );

      final first = harness.navigate(0);
      final gen1 = first.generation;

      // Pick and complete all tasks from gen 1
      while (true) {
        final t = first.scheduler.pickTask();
        if (t == null) break;
        first.scheduler.markStarted(t);
        first.scheduler.markCompleted(t);
      }

      final second = harness.navigate(0);
      final gen2 = second.generation;

      expect(gen2, greaterThan(gen1),
          reason: 'second navigation is new generation');

      // Check that same URLs exist in both generations
      final urls1 = first.plannedTasks.map((t) => t.url).toSet();
      final urls2 = second.plannedTasks.map((t) => t.url).toSet();
      expect(urls1.intersection(urls2), isNotEmpty,
          reason: 'overlapping URLs across generations');
    });

    test('different gallery positions same asset are distinct', () {
      final items = [
        _asset(
          id: 'gal',
          isGallery: true,
          galleryUrls: [
            'https://i.redd.it/gal_0.jpg',
            'https://i.redd.it/gal_1.jpg',
          ],
        ),
        _asset(id: 'next'),
      ];

      final harness = SchedulerPipelineHarness(
        playlist: items,
        targetBudget: 10,
        horizon: 5,
        readinessSimulator: readinessAt({}),
      );

      final result = harness.navigate(0);

      // Each gallery URL should be a separate task
      final galleryTasks =
          result.plannedTasks.where((t) => t.assetId == 'gal').toList();
      final galleryUrls = galleryTasks.map((t) => t.url).toSet();
      expect(galleryUrls.length, galleryTasks.length,
          reason: 'each gallery image is a distinct task');
    });
  });

  group('Massive Playlist', () {
    test('5000 items scheduler complexity bounded', () {
      final items = List.generate(5000, (i) => _asset(id: 'item_$i'));
      final harness = SchedulerPipelineHarness(
        playlist: items,
        targetBudget: 50,
        horizon: 20,
        readinessSimulator: readinessForIndices(
          List.generate(50, (i) => i),
          [],
          List.generate(4950, (i) => i + 50),
        ),
      );

      final sw = Stopwatch()..start();
      final result = harness.navigate(2500);
      sw.stop();

      expect(sw.elapsedMilliseconds, lessThan(1000),
          reason: 'planning completes within 1 second');
      expect(result.needCount, greaterThan(0),
          reason: 'demand exists in large playlist');
      expect(result.plannedTasks.length, lessThanOrEqualTo(result.needCount),
          reason: 'planner respects needCount');
      expect(result.scheduler.state, SchedulerState.active,
          reason: 'scheduler active');

      // Pick and complete all tasks
      sw.reset();
      sw.start();
      while (true) {
        final t = result.scheduler.pickTask();
        if (t == null) break;
        result.scheduler.markStarted(t);
        result.scheduler.markCompleted(t);
      }
      sw.stop();

      expect(sw.elapsedMilliseconds, lessThan(1000),
          reason: 'draining scheduler completes within 1 second');
      expect(result.scheduler.pendingCount, 0);
      expect(result.scheduler.state, SchedulerState.satisfied);
    });

    test('5000 items generation cancellation is fast', () {
      final items = List.generate(5000, (i) => _asset(id: 'item_$i'));
      final harness = SchedulerPipelineHarness(
        playlist: items,
        targetBudget: 50,
        horizon: 20,
        readinessSimulator: readinessAt({}),
      );

      harness.navigate(0);

      final sw = Stopwatch()..start();
      harness.navigate(4000);
      sw.stop();

      expect(sw.elapsedMilliseconds, lessThan(1000),
          reason: 'generation cancellation + enqueue for large jump is fast');
      expect(harness.scheduler.pendingCount, greaterThan(0),
          reason: 'new tasks after jump');
    });
  });

  group('Random Navigation', () {
    test('invariants hold across random viewport changes', () {
      final items = List.generate(200, (i) => _asset(id: 'item_$i'));
      final rng = _SeededRandom(42);

      // Readiness: ~70% ready, ~20% likelyReady, ~10% unavailable
      final sim = (List<MediaAsset> playlist, int index) {
        final val = rng.next();
        if (val < 0.7) return ReadinessState.ready;
        if (val < 0.9) return ReadinessState.likelyReady;
        return ReadinessState.unavailable;
      };

      final harness = SchedulerPipelineHarness(
        playlist: items,
        targetBudget: 8,
        horizon: 5,
        readinessSimulator: sim,
      );

      var previousGen = 0;
      for (int step = 0; step < 50; step++) {
        final idx = rng.nextInt(items.length);
        final result = harness.navigate(idx);
        final gen = result.generation;

        // Generation increased
        expect(gen, greaterThan(previousGen),
            reason: 'generation increases at step $step');
        previousGen = gen;

        // Planner respects needCount
        expect(result.plannedTasks.length, lessThanOrEqualTo(result.needCount),
            reason: 'needCount respected at step $step');

        // No duplicate tasks
        final seen = <String>{};
        for (final task in result.plannedTasks) {
          final key = '${task.url}:${task.generation}';
          expect(seen.contains(key), isFalse,
              reason: 'no duplicates at step $step');
          seen.add(key);
        }

        // Scheduler state is valid
        if (result.scheduler.pendingCount > 0) {
          expect(result.scheduler.state, SchedulerState.active,
              reason: 'active when pending at step $step');
        } else {
          expect(result.scheduler.state, SchedulerState.satisfied,
              reason: 'satisfied when no pending at step $step');
        }

        // Golden Rule: pick tasks in order
        final pickOrder = <SchedulerTask>[];
        while (true) {
          final t = result.scheduler.pickTask();
          if (t == null) break;
          pickOrder.add(t);
          result.scheduler.markStarted(t);
          result.scheduler.markCompleted(t);
        }

        for (int i = 0; i < pickOrder.length; i++) {
          final ringA = _computeRingForTask(pickOrder[i], idx, 5);
          for (int j = i + 1; j < pickOrder.length; j++) {
            final ringB = _computeRingForTask(pickOrder[j], idx, 5);
            expect(ringB.index, greaterThanOrEqualTo(ringA.index),
                reason: 'golden rule at step $step i=$i j=$j');
          }
        }
      }
    });
  });

  test('in-flight task from old generation completes after cancel', () {
    final items = List.generate(50, (i) => _asset(id: 'item_$i'));
    final harness = SchedulerPipelineHarness(
      playlist: items,
      targetBudget: 10,
      horizon: 5,
      readinessSimulator: readinessAt({}),
    );

    final first = harness.navigate(0);

    final inFlight = first.scheduler.pickTask()!;
    first.scheduler.markStarted(inFlight);

    final second = harness.navigate(10);

    // inFlight has gen1, but we already called cancelGeneration for gen1
    // Completing stale task should be safe
    first.scheduler.markCompleted(inFlight);

    // Scheduler should still have gen2 pending work
    expect(second.scheduler.pendingCount, greaterThan(0),
        reason: 'gen2 tasks remain after stale completion');
  });
}

class _SeededRandom {
  int _state;

  _SeededRandom(int seed) : _state = seed;

  double next() {
    _state = (_state * 1103515245 + 12345) & 0x7fffffff;
    return _state / 0x7fffffff;
  }

  int nextInt(int max) => (next() * max).floor();
}
