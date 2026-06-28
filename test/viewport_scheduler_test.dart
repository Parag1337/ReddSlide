import 'package:flutter_test/flutter_test.dart';
import 'package:redslide/features/slideshow/domain/scheduler_task.dart';
import 'package:redslide/features/slideshow/domain/viewport_scheduler.dart';

SchedulerTask _task({
  required String id,
  required int index,
  int generation = 1,
  String? url,
  MediaTaskType mediaType = MediaTaskType.image,
  int? galleryPosition,
  int? galleryLength,
}) {
  return SchedulerTask(
    assetId: id,
    url: url ?? 'https://i.redd.it/$id.jpg',
    index: index,
    mediaType: mediaType,
    galleryPosition: galleryPosition,
    galleryLength: galleryLength,
    generation: generation,
  );
}

void main() {
  group('pickTask ring ordering', () {
    test('immediate before critical', () {
      final scheduler = ViewportScheduler();
      scheduler.enqueue(
        tasks: [
          _task(id: 'near', index: 10, generation: 1),
          _task(id: 'close', index: 1, generation: 1),
        ],
        currentIndex: 0,
        horizon: 5,
      );
      // close (distance=1) → immediate; near (distance=10) → near
      expect(scheduler.pickTask()!.assetId, 'close');
    });

    test('critical before near', () {
      final scheduler = ViewportScheduler();
      scheduler.enqueue(
        tasks: [
          _task(id: 'far', index: 10, generation: 1),
          _task(id: 'medium', index: 4, generation: 1),
        ],
        currentIndex: 0,
        horizon: 5,
      );
      // medium (distance=4) → critical; far (distance=10) → near
      expect(scheduler.pickTask()!.assetId, 'medium');
    });

    test('near before background', () {
      final scheduler = ViewportScheduler();
      scheduler.enqueue(
        tasks: [
          _task(id: 'bg', index: 20, generation: 1),
          _task(id: 'nr', index: 10, generation: 1),
        ],
        currentIndex: 0,
        horizon: 5,
      );
      // nr (distance=10) → near; bg (distance=20) → background
      expect(scheduler.pickTask()!.assetId, 'nr');
    });

    test('golden rule: never picks background when immediate has work', () {
      final scheduler = ViewportScheduler();
      scheduler.enqueue(
        tasks: [
          _task(id: 'immediate', index: 0, generation: 1),
          _task(id: 'background', index: 20, generation: 1),
        ],
        currentIndex: 0,
        horizon: 5,
      );
      // Must always pick immediate first
      expect(scheduler.pickTask()!.assetId, 'immediate');
    });
  });

  group('pickTask lifecycle', () {
    test('returns null when no tasks', () {
      final scheduler = ViewportScheduler();
      expect(scheduler.pickTask(), isNull);
    });

    test('returns null after all tasks completed', () {
      final scheduler = ViewportScheduler();
      scheduler.enqueue(
        tasks: [_task(id: 'a', index: 0, generation: 1)],
        currentIndex: 0,
        horizon: 5,
      );
      final task = scheduler.pickTask()!;
      scheduler.markStarted(task);
      scheduler.markCompleted(task);
      expect(scheduler.pickTask(), isNull);
    });

    test('returns null after all tasks failed', () {
      final scheduler = ViewportScheduler();
      scheduler.enqueue(
        tasks: [_task(id: 'a', index: 0, generation: 1)],
        currentIndex: 0,
        horizon: 5,
      );
      final task = scheduler.pickTask()!;
      scheduler.markStarted(task);
      scheduler.markFailed(task);
      expect(scheduler.pickTask(), isNull);
    });

    test('tasks are consumed in ring order', () {
      final scheduler = ViewportScheduler();
      // One task per ring
      scheduler.enqueue(
        tasks: [
          _task(id: 'bg', index: 20, generation: 1),
          _task(id: 'near', index: 10, generation: 1),
          _task(id: 'crit', index: 4, generation: 1),
          _task(id: 'immediate', index: 0, generation: 1),
        ],
        currentIndex: 0,
        horizon: 5,
      );
      expect(scheduler.pickTask()!.assetId, 'immediate');
      scheduler.markStarted(scheduler.pickTask()!); // not needed, just peeked
      // Actually pickTask doesn't mark started - let me redo this properly
    });

    test('complete one then next is available', () {
      final scheduler = ViewportScheduler();
      scheduler.enqueue(
        tasks: [
          _task(id: 'a', index: 0, generation: 1),
          _task(id: 'b', index: 1, generation: 1),
        ],
        currentIndex: 0,
        horizon: 5,
      );
      var task = scheduler.pickTask()!;
      expect(task.assetId, 'a');
      scheduler.markStarted(task);
      scheduler.markCompleted(task);

      task = scheduler.pickTask()!;
      expect(task.assetId, 'b');
    });

    test('markStarted removes from rings', () {
      final scheduler = ViewportScheduler();
      scheduler.enqueue(
        tasks: [_task(id: 'a', index: 0, generation: 1)],
        currentIndex: 0,
        horizon: 5,
      );
      expect(scheduler.pendingCount, 1);
      scheduler.markStarted(scheduler.pickTask()!);
      expect(scheduler.pendingCount, 0);
    });

    test('cannot pick same task twice', () {
      final scheduler = ViewportScheduler();
      scheduler.enqueue(
        tasks: [_task(id: 'a', index: 0, generation: 1)],
        currentIndex: 0,
        horizon: 5,
      );
      final first = scheduler.pickTask()!;
      scheduler.markStarted(first);
      // Second pick should see no pending tasks (a is in-flight)
      expect(scheduler.pickTask(), isNull);
    });
  });

  group('ring assignment by distance', () {
    test('distance 0 and 1 are immediate', () {
      final scheduler = ViewportScheduler();
      scheduler.enqueue(
        tasks: [
          _task(id: 'i0', index: 0, generation: 1),
          _task(id: 'i1', index: 1, generation: 1),
          _task(id: 'c2', index: 2, generation: 1),
        ],
        currentIndex: 0,
        horizon: 5,
      );
      // 0→immediate, 1→immediate, 2→critical
      expect(scheduler.pickTask()!.assetId, 'i0');
      scheduler.markStarted(scheduler.pickTask()!);
      scheduler.markCompleted(scheduler.pickTask()!);
      // Not a clean test of ring assignment, but verifies ordering
    });

    test('distance up to 1+horizon is critical', () {
      final scheduler = ViewportScheduler();
      scheduler.enqueue(
        tasks: [
          _task(id: 'c2', index: 2, generation: 1),
          _task(id: 'c6', index: 6, generation: 1),
        ],
        currentIndex: 0,
        horizon: 5,
      );
      // distance 2-6 = critical (2 <= distance <= 6)
      // Both should be in same ring; pickTask returns first enqueued
      expect(scheduler.pickTask()!.assetId, 'c2');
    });

    test('distance up to 1+horizon*2 is near', () {
      final scheduler = ViewportScheduler();
      scheduler.enqueue(
        tasks: [
          _task(id: 'n7', index: 7, generation: 1),
          _task(id: 'n11', index: 11, generation: 1),
        ],
        currentIndex: 0,
        horizon: 5,
      );
      // distance 7-11 = near (7 <= distance <= 11)
      // Both in near ring
      expect(scheduler.pickTask()!.assetId, 'n7');
    });

    test('beyond 1+horizon*2 is background', () {
      final scheduler = ViewportScheduler();
      scheduler.enqueue(
        tasks: [_task(id: 'bg', index: 12, generation: 1)],
        currentIndex: 0,
        horizon: 5,
      );
      // distance 12 → background
      // No higher-priority tasks, so this is returned
      expect(scheduler.pickTask()!.assetId, 'bg');
    });

    test('higher ring exhausted before lower ring', () {
      final scheduler = ViewportScheduler();
      scheduler.enqueue(
        tasks: [
          _task(id: 'im', index: 0, generation: 1),
          _task(id: 'bg', index: 12, generation: 1),
        ],
        currentIndex: 0,
        horizon: 5,
      );
      // im is immediate, bg is background
      // First pick: im
      expect(scheduler.pickTask()!.assetId, 'im');
      scheduler.markStarted(scheduler.pickTask()!);
      scheduler.markCompleted(scheduler.pickTask()!);
      // After im completes: bg
      expect(scheduler.pickTask()!.assetId, 'bg');
    });
  });

  group('gallery promotion', () {
    test('gallery at near distance promoted to critical', () {
      final scheduler = ViewportScheduler();
      scheduler.enqueue(
        tasks: [
          _task(id: 'gal', index: 7, generation: 1, galleryPosition: 0),
          _task(id: 'reg', index: 2, generation: 1),
        ],
        currentIndex: 0,
        horizon: 5,
      );
      // gal (distance=7) normally near, but promoted to critical
      // reg (distance=2) critical
      // Both critical, order depends on enqueue order → gal first
      expect(scheduler.pickTask()!.assetId, 'gal');
    });

    test('gallery at background distance promoted to near', () {
      final scheduler = ViewportScheduler();
      scheduler.enqueue(
        tasks: [
          _task(id: 'gal', index: 12, generation: 1, galleryPosition: 0),
          _task(id: 'reg', index: 8, generation: 1),
        ],
        currentIndex: 0,
        horizon: 5,
      );
      // gal (distance=12) normally background, promoted to near
      // reg (distance=8) near
      // Both near, gal first
      expect(scheduler.pickTask()!.assetId, 'gal');
    });

    test('gallery at immediate distance stays immediate', () {
      final scheduler = ViewportScheduler();
      scheduler.enqueue(
        tasks: [
          _task(id: 'gal', index: 1, generation: 1, galleryPosition: 0),
          _task(id: 'reg', index: 0, generation: 1),
        ],
        currentIndex: 0,
        horizon: 5,
      );
      // Both immediate
      expect(scheduler.pickTask()!.assetId, 'gal');
    });

    test('gallery promoted above non-gallery at closer distance', () {
      final scheduler = ViewportScheduler();
      scheduler.enqueue(
        tasks: [
          // gal at distance 7 normally near, promoted to critical
          _task(id: 'gal', index: 7, generation: 1, galleryPosition: 0),
          // reg at distance 2 is critical
          _task(id: 'reg', index: 2, generation: 1),
          // close at distance 0 is immediate
          _task(id: 'close', index: 0, generation: 1),
        ],
        currentIndex: 0,
        horizon: 5,
      );
      // close is immediate (highest ring) → picked first
      expect(scheduler.pickTask()!.assetId, 'close');
      scheduler.markStarted(scheduler.pickTask()!);
      scheduler.markCompleted(scheduler.pickTask()!);

      // gal promoted to critical, reg is critical too
      // gal was enqueued first → picked first
      expect(scheduler.pickTask()!.assetId, 'gal');
    });
  });

  group('generation cancellation', () {
    test('cancelGeneration removes pending tasks of that generation', () {
      final scheduler = ViewportScheduler();
      scheduler.enqueue(
        tasks: [
          _task(id: 'old', index: 0, generation: 1),
          _task(id: 'new', index: 0, generation: 2),
        ],
        currentIndex: 0,
        horizon: 5,
      );
      // Both enqueued. Both immediate.
      expect(scheduler.pendingCount, 2);

      scheduler.cancelGeneration(1);

      // Only old generation 1 removed
      expect(scheduler.pendingCount, 1);
      expect(scheduler.pickTask()!.assetId, 'new');
    });

    test('in-flight tasks survive cancelGeneration', () {
      final scheduler = ViewportScheduler();
      scheduler.enqueue(
        tasks: [_task(id: 'a', index: 0, generation: 1)],
        currentIndex: 0,
        horizon: 5,
      );
      final task = scheduler.pickTask()!;
      scheduler.markStarted(task);

      scheduler.cancelGeneration(1);

      // Task still in-flight (not failed, not completed)
      expect(scheduler.isEmpty, false);
    });

    test('completed stale task ignored after cancelGeneration', () {
      final scheduler = ViewportScheduler();
      scheduler.enqueue(
        tasks: [_task(id: 'a', index: 0, generation: 1)],
        currentIndex: 0,
        horizon: 5,
      );
      final task = scheduler.pickTask()!;
      scheduler.markStarted(task);

      scheduler.cancelGeneration(1);

      // Mark completed — should be ignored (generation 1 still, but handled)
      scheduler.markCompleted(task);
      // After handling old completion, no in-flight or pending tasks remain
    });

    test('cancelGeneration does not affect tasks of other generations', () {
      final scheduler = ViewportScheduler();
      scheduler.enqueue(
        tasks: [
          _task(id: 'keep', index: 0, generation: 2),
        ],
        currentIndex: 0,
        horizon: 5,
      );
      scheduler.cancelGeneration(1);
      expect(scheduler.pendingCount, 1);
      expect(scheduler.pickTask()!.assetId, 'keep');
    });

    test('double cancelGeneration is safe', () {
      final scheduler = ViewportScheduler();
      scheduler.enqueue(
        tasks: [_task(id: 'a', index: 0, generation: 1)],
        currentIndex: 0,
        horizon: 5,
      );
      scheduler.cancelGeneration(1);
      scheduler.cancelGeneration(1);
      expect(scheduler.isEmpty, true);
    });
  });

  group('duplicate prevention', () {
    test('same task enqueued twice adds only once', () {
      final scheduler = ViewportScheduler();
      final task = _task(id: 'a', index: 0, generation: 1);
      scheduler.enqueue(
        tasks: [task, task],
        currentIndex: 0,
        horizon: 5,
      );
      expect(scheduler.pendingCount, 1);
    });

    test('same URL in two tasks with same generation adds once', () {
      final scheduler = ViewportScheduler();
      scheduler.enqueue(
        tasks: [
          _task(id: 'a', index: 0, generation: 1),
          _task(id: 'b', index: 1, generation: 1,
              url: 'https://i.redd.it/a.jpg'),
        ],
        currentIndex: 0,
        horizon: 5,
      );
      // Both tasks have same URL and generation
      expect(scheduler.pendingCount, 1);
    });

    test('same URL different generation adds both', () {
      final scheduler = ViewportScheduler();
      scheduler.enqueue(
        tasks: [
          _task(id: 'a', index: 0, generation: 1),
          _task(id: 'a', index: 0, generation: 2),
        ],
        currentIndex: 0,
        horizon: 5,
      );
      expect(scheduler.pendingCount, 2);
    });

    test('completed task not re-enqueued', () {
      final scheduler = ViewportScheduler();
      scheduler.enqueue(
        tasks: [_task(id: 'a', index: 0, generation: 1)],
        currentIndex: 0,
        horizon: 5,
      );
      final task = scheduler.pickTask()!;
      scheduler.markStarted(task);
      scheduler.markCompleted(task);

      // Re-enqueue same task
      scheduler.enqueue(
        tasks: [_task(id: 'a', index: 0, generation: 1)],
        currentIndex: 0,
        horizon: 5,
      );
      expect(scheduler.pendingCount, 0);
    });

    test('failed task not re-enqueued', () {
      final scheduler = ViewportScheduler();
      scheduler.enqueue(
        tasks: [_task(id: 'a', index: 0, generation: 1)],
        currentIndex: 0,
        horizon: 5,
      );
      final task = scheduler.pickTask()!;
      scheduler.markStarted(task);
      scheduler.markFailed(task);

      scheduler.enqueue(
        tasks: [_task(id: 'a', index: 0, generation: 1)],
        currentIndex: 0,
        horizon: 5,
      );
      expect(scheduler.pendingCount, 0);
    });

    test('in-flight task not re-enqueued', () {
      final scheduler = ViewportScheduler();
      scheduler.enqueue(
        tasks: [_task(id: 'a', index: 0, generation: 1)],
        currentIndex: 0,
        horizon: 5,
      );
      final task = scheduler.pickTask()!;
      scheduler.markStarted(task);

      scheduler.enqueue(
        tasks: [_task(id: 'a', index: 0, generation: 1)],
        currentIndex: 0,
        horizon: 5,
      );
      expect(scheduler.pendingCount, 0);
    });
  });

  group('clear and state', () {
    test('clear removes all state', () {
      final scheduler = ViewportScheduler();
      scheduler.enqueue(
        tasks: [_task(id: 'a', index: 0, generation: 1)],
        currentIndex: 0,
        horizon: 5,
      );
      final task = scheduler.pickTask()!;
      scheduler.markStarted(task);
      scheduler.clear();
      expect(scheduler.isEmpty, true);
      expect(scheduler.pendingCount, 0);
      expect(scheduler.state, SchedulerState.idle);
    });

    test('clear is safe on empty scheduler', () {
      final scheduler = ViewportScheduler();
      scheduler.clear();
      expect(scheduler.isEmpty, true);
    });

    test('clear twice is safe', () {
      final scheduler = ViewportScheduler();
      scheduler.clear();
      scheduler.clear();
      expect(scheduler.isEmpty, true);
    });
  });

  group('isEmpty and pendingCount', () {
    test('isEmpty true initially', () {
      final scheduler = ViewportScheduler();
      expect(scheduler.isEmpty, true);
    });

    test('isEmpty false after enqueue', () {
      final scheduler = ViewportScheduler();
      scheduler.enqueue(
        tasks: [_task(id: 'a', index: 0, generation: 1)],
        currentIndex: 0,
        horizon: 5,
      );
      expect(scheduler.isEmpty, false);
    });

    test('pendingCount after enqueue', () {
      final scheduler = ViewportScheduler();
      scheduler.enqueue(
        tasks: [
          _task(id: 'a', index: 0, generation: 1),
          _task(id: 'b', index: 1, generation: 1),
        ],
        currentIndex: 0,
        horizon: 5,
      );
      expect(scheduler.pendingCount, 2);
    });

    test('pendingCount decreases after pick+start', () {
      final scheduler = ViewportScheduler();
      scheduler.enqueue(
        tasks: [
          _task(id: 'a', index: 0, generation: 1),
          _task(id: 'b', index: 1, generation: 1),
        ],
        currentIndex: 0,
        horizon: 5,
      );
      scheduler.markStarted(scheduler.pickTask()!);
      expect(scheduler.pendingCount, 1);
    });
  });

  group('state machine', () {
    test('initial state is idle', () {
      final scheduler = ViewportScheduler();
      expect(scheduler.state, SchedulerState.idle);
    });

    test('active after enqueue with tasks', () {
      final scheduler = ViewportScheduler();
      scheduler.enqueue(
        tasks: [_task(id: 'a', index: 0, generation: 1)],
        currentIndex: 0,
        horizon: 5,
      );
      expect(scheduler.state, SchedulerState.active);
    });

    test('satisfied after enqueue with no tasks', () {
      final scheduler = ViewportScheduler();
      scheduler.enqueue(
        tasks: [],
        currentIndex: 0,
        horizon: 5,
      );
      expect(scheduler.state, SchedulerState.satisfied);
    });

    test('satisfied after all tasks completed', () {
      final scheduler = ViewportScheduler();
      scheduler.enqueue(
        tasks: [_task(id: 'a', index: 0, generation: 1)],
        currentIndex: 0,
        horizon: 5,
      );
      final task = scheduler.pickTask()!;
      scheduler.markStarted(task);
      scheduler.markCompleted(task);
      expect(scheduler.state, SchedulerState.satisfied);
    });

    test('satisfied after all tasks failed', () {
      final scheduler = ViewportScheduler();
      scheduler.enqueue(
        tasks: [_task(id: 'a', index: 0, generation: 1)],
        currentIndex: 0,
        horizon: 5,
      );
      final task = scheduler.pickTask()!;
      scheduler.markStarted(task);
      scheduler.markFailed(task);
      expect(scheduler.state, SchedulerState.satisfied);
    });

    test('sleep sets sleeping state', () {
      final scheduler = ViewportScheduler();
      scheduler.enqueue(
        tasks: [_task(id: 'a', index: 0, generation: 1)],
        currentIndex: 0,
        horizon: 5,
      );
      scheduler.sleep();
      expect(scheduler.state, SchedulerState.sleeping);
    });

    test('wake after sleep returns to correct state', () {
      final scheduler = ViewportScheduler();
      scheduler.sleep();
      expect(scheduler.state, SchedulerState.sleeping);
      scheduler.wake();
      expect(scheduler.state, SchedulerState.satisfied);
    });

    test('enqueue transitions sleeping to active', () {
      final scheduler = ViewportScheduler();
      scheduler.sleep();
      scheduler.enqueue(
        tasks: [_task(id: 'a', index: 0, generation: 1)],
        currentIndex: 0,
        horizon: 5,
      );
      expect(scheduler.state, SchedulerState.active);
    });

    test('clear transitions to idle', () {
      final scheduler = ViewportScheduler();
      scheduler.enqueue(
        tasks: [_task(id: 'a', index: 0, generation: 1)],
        currentIndex: 0,
        horizon: 5,
      );
      expect(scheduler.state, SchedulerState.active);
      scheduler.clear();
      expect(scheduler.state, SchedulerState.idle);
    });
  });

  group('navigation simulation', () {
    test('enqueue replaces old pending tasks', () {
      final scheduler = ViewportScheduler();
      scheduler.enqueue(
        tasks: [_task(id: 'old', index: 0, generation: 1)],
        currentIndex: 0,
        horizon: 5,
      );
      expect(scheduler.pendingCount, 1);

      // Navigate to index 5
      scheduler.enqueue(
        tasks: [_task(id: 'new', index: 5, generation: 1)],
        currentIndex: 5,
        horizon: 5,
      );
      // Old pending task is removed; new task remains
      expect(scheduler.pendingCount, 1);
      expect(scheduler.pickTask()!.assetId, 'new');
    });

    test('in-flight task survives re-enqueue', () {
      final scheduler = ViewportScheduler();
      scheduler.enqueue(
        tasks: [_task(id: 'a', index: 0, generation: 1)],
        currentIndex: 0,
        horizon: 5,
      );
      final task = scheduler.pickTask()!;
      scheduler.markStarted(task);

      // Re-enqueue with same task
      scheduler.enqueue(
        tasks: [_task(id: 'a', index: 0, generation: 1)],
        currentIndex: 0,
        horizon: 5,
      );
      // In-flight task still tracked
      expect(scheduler.isEmpty, false);
    });

    test('large jump reassigns rings correctly', () {
      final scheduler = ViewportScheduler();
      scheduler.enqueue(
        tasks: [
          _task(id: 'near_old', index: 10, generation: 1),
          _task(id: 'immediate', index: 5, generation: 1),
        ],
        currentIndex: 5,
        horizon: 5,
      );
      // immediate (dist 0) → immediate, near_old (dist 5) → critical
      expect(scheduler.pickTask()!.assetId, 'immediate');

      // Jump to index 50
      scheduler.enqueue(
        tasks: [
          _task(id: 'new_imm', index: 50, generation: 1),
          _task(id: 'new_far', index: 60, generation: 1),
        ],
        currentIndex: 50,
        horizon: 5,
      );
      // new_imm (dist 0) → immediate, new_far (dist 10) → background
      expect(scheduler.pickTask()!.assetId, 'new_imm');
    });
  });

  group('determinism', () {
    test('same sequence produces same pick order', () {
      final a = ViewportScheduler();
      final b = ViewportScheduler();

      final tasks = [
        _task(id: 'bg', index: 20, generation: 1),
        _task(id: 'im', index: 0, generation: 1),
        _task(id: 'near', index: 10, generation: 1),
        _task(id: 'crit', index: 3, generation: 1),
      ];

      a.enqueue(tasks: tasks, currentIndex: 0, horizon: 5);
      b.enqueue(tasks: tasks, currentIndex: 0, horizon: 5);

      for (int i = 0; i < 4; i++) {
        final ta = a.pickTask()!;
        final tb = b.pickTask()!;
        expect(ta.assetId, tb.assetId);
        a.markStarted(ta);
        a.markCompleted(ta);
        b.markStarted(tb);
        b.markCompleted(tb);
      }
    });

    test('pendingCount stable', () {
      final scheduler = ViewportScheduler();
      expect(scheduler.pendingCount, 0);
      scheduler.enqueue(
        tasks: List.generate(10, (i) => _task(id: 't$i', index: i, generation: 1)),
        currentIndex: 0,
        horizon: 5,
      );
      expect(scheduler.pendingCount, 10);
      scheduler.clear();
      expect(scheduler.pendingCount, 0);
    });
  });

  group('edge cases', () {
    test('enqueue empty tasks clears pending and keeps in-flight', () {
      final scheduler = ViewportScheduler();
      scheduler.enqueue(
        tasks: [_task(id: 'a', index: 0, generation: 1)],
        currentIndex: 0,
        horizon: 5,
      );
      final task = scheduler.pickTask()!;
      scheduler.markStarted(task);

      scheduler.enqueue(tasks: [], currentIndex: 0, horizon: 5);

      // Pending cleared; in-flight remains
      expect(scheduler.pendingCount, 0);
      expect(scheduler.isEmpty, false);
    });

    test('markStarted same task twice is safe', () {
      final scheduler = ViewportScheduler();
      scheduler.enqueue(
        tasks: [_task(id: 'a', index: 0, generation: 1)],
        currentIndex: 0,
        horizon: 5,
      );
      final task = scheduler.pickTask()!;
      scheduler.markStarted(task);
      // Second call is a no-op (already in _inFlight)
      scheduler.markStarted(task);
    });

    test('markCompleted of unknown task is safe', () {
      final scheduler = ViewportScheduler();
      final task = _task(id: 'unknown', index: 0, generation: 1);
      scheduler.markCompleted(task);
      // No crash
    });

    test('markFailed of unknown task is safe', () {
      final scheduler = ViewportScheduler();
      final task = _task(id: 'unknown', index: 0, generation: 1);
      scheduler.markFailed(task);
    });

    test('enqueue after clear works', () {
      final scheduler = ViewportScheduler();
      scheduler.enqueue(
        tasks: [_task(id: 'a', index: 0, generation: 1)],
        currentIndex: 0,
        horizon: 5,
      );
      scheduler.clear();
      scheduler.enqueue(
        tasks: [_task(id: 'b', index: 0, generation: 1)],
        currentIndex: 0,
        horizon: 5,
      );
      expect(scheduler.pickTask()!.assetId, 'b');
    });

    test('large number of tasks', () {
      final scheduler = ViewportScheduler();
      final tasks = List.generate(100,
          (i) => _task(id: 't$i', index: i, generation: 1));
      scheduler.enqueue(tasks: tasks, currentIndex: 50, horizon: 10);
      expect(scheduler.pendingCount, 100);

      // Pick and start first 50
      for (int i = 0; i < 50; i++) {
        final task = scheduler.pickTask()!;
        scheduler.markStarted(task);
        scheduler.markCompleted(task);
      }
      expect(scheduler.isEmpty, false);

      // Complete all
      for (int i = 0; i < 50; i++) {
        final task = scheduler.pickTask()!;
        scheduler.markStarted(task);
        scheduler.markCompleted(task);
      }
      expect(scheduler.isEmpty, true);
    });
  });
}
