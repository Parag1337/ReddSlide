import 'package:redslide/features/feed/domain/media_asset.dart';
import 'package:redslide/features/slideshow/domain/readiness_state.dart';
import 'package:redslide/features/slideshow/domain/demand_calculator.dart';
import 'package:redslide/features/slideshow/domain/scheduler_task.dart';
import 'package:redslide/features/slideshow/domain/task_planner.dart';
import 'package:redslide/features/slideshow/domain/viewport_scheduler.dart';

typedef ReadinessSimulator = ReadinessState Function(
    List<MediaAsset> playlist, int index);

class PipelineResult {
  final int generation;
  final int needCount;
  final List<SchedulerTask> plannedTasks;
  final ViewportScheduler scheduler;
  final int enqueuedCount;

  PipelineResult({
    required this.generation,
    required this.needCount,
    required this.plannedTasks,
    required this.scheduler,
    required this.enqueuedCount,
  });

  int get pendingCount => scheduler.pendingCount;

  SchedulerTask? pickNext() => scheduler.pickTask();
}

class SchedulerPipelineHarness {
  final DemandCalculator demandCalculator;
  final TaskPlanner taskPlanner;
  final ViewportScheduler scheduler;
  final List<MediaAsset> playlist;
  final int targetBudget;
  final int horizon;
  final ReadinessSimulator readinessSimulator;
  int _generation = 0;
  int _currentIndex = 0;

  SchedulerPipelineHarness({
    required this.playlist,
    this.targetBudget = 10,
    this.horizon = 5,
    ReadinessSimulator? readinessSimulator,
  })  : demandCalculator = const DemandCalculator(),
        taskPlanner = const TaskPlanner(),
        scheduler = ViewportScheduler(),
        readinessSimulator =
            readinessSimulator ?? _readyForMostSimulator;

  int get generation => _generation;
  int get currentIndex => _currentIndex;

  PipelineResult navigate(
    int currentIndex, {
    int galleryIndex = 0,
  }) {
    _generation++;
    _currentIndex = currentIndex;

    final end = (currentIndex + horizon + 1).clamp(0, playlist.length);
    final states = <ReadinessState>[];
    for (int i = currentIndex; i < end; i++) {
      states.add(readinessSimulator(playlist, i));
    }

    final needCount = demandCalculator.computeNeedCount(
      states,
      targetBudget: targetBudget,
    );

    final tasks = taskPlanner.plan(
      items: playlist,
      currentIndex: currentIndex,
      horizon: horizon,
      needCount: needCount,
      generation: _generation,
      galleryIndex: galleryIndex,
    );

    if (_generation > 1) {
      scheduler.cancelGeneration(_generation - 1);
    }
    scheduler.enqueue(
      tasks: tasks,
      currentIndex: currentIndex,
      horizon: horizon,
    );

    return PipelineResult(
      generation: _generation,
      needCount: needCount,
      plannedTasks: tasks,
      scheduler: scheduler,
      enqueuedCount: tasks.length,
    );
  }

  static ReadinessState _readyForMostSimulator(
      List<MediaAsset> playlist, int index) {
    return ReadinessState.likelyReady;
  }

  static ReadinessState allReady(
      List<MediaAsset> playlist, int index) {
    return ReadinessState.ready;
  }

  static ReadinessState allUnavailable(
      List<MediaAsset> playlist, int index) {
    return ReadinessState.unavailable;
  }
}
