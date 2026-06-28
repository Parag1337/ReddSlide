import 'dart:math' show min, max;
import '../../feed/domain/media_asset.dart';
import 'readiness_state.dart';
import 'demand_calculator.dart';
import 'scheduler_task.dart';
import 'task_planner.dart';
import 'viewport_scheduler.dart';

class ShadowScheduler {
  final DemandCalculator demandCalculator;
  final TaskPlanner taskPlanner;
  final ViewportScheduler scheduler;
  final ShadowSchedulerConfig config;
  int _generation = 0;

  ShadowScheduler({
    ShadowSchedulerConfig? config,
  })  : demandCalculator = const DemandCalculator(),
        taskPlanner = const TaskPlanner(),
        scheduler = ViewportScheduler(),
        config = config ?? const ShadowSchedulerConfig();

  int get generation => _generation;

  ShadowCycleResult runCycle({
    required List<ReadinessState> states,
    required List<MediaAsset> items,
    required int currentIndex,
    required Set<String> adaptivePlannedUrls,
    int galleryIndex = 0,
  }) {
    _generation++;

    final sw = Stopwatch()..start();
    final phaseTimings = <String, int>{};

    // Demand calculation
    final dSw = Stopwatch()..start();
    final needCount = demandCalculator.computeNeedCount(
      states,
      targetBudget: config.targetBudget,
    );
    phaseTimings['demandCalc'] = dSw.elapsedMicroseconds;

    // Task planning
    final pSw = Stopwatch()..start();
    final tasks = taskPlanner.plan(
      items: items,
      currentIndex: currentIndex,
      horizon: config.horizon,
      needCount: needCount,
      generation: _generation,
      galleryIndex: galleryIndex,
    );
    phaseTimings['plan'] = pSw.elapsedMicroseconds;

    // Enqueue into scheduler
    final eSw = Stopwatch()..start();
    if (_generation > 1) {
      final cancelSw = Stopwatch()..start();
      scheduler.cancelGeneration(_generation - 1);
      phaseTimings['cancelGeneration'] = cancelSw.elapsedMicroseconds;
    }
    scheduler.enqueue(
      tasks: tasks,
      currentIndex: currentIndex,
      horizon: config.horizon,
    );
    phaseTimings['enqueue'] = eSw.elapsedMicroseconds;

    // Pick tasks (record decision only, never execute)
    final pickSw = Stopwatch()..start();
    final picked = <SchedulerTask>[];
    while (true) {
      final t = scheduler.pickTask();
      if (t == null) break;
      picked.add(t);
      scheduler.markStarted(t);
      scheduler.markCompleted(t);
    }
    phaseTimings['pickAll'] = pickSw.elapsedMicroseconds;

    phaseTimings['total'] = sw.elapsedMicroseconds;

    // Comparison with AdaptivePreloader
    final viewportUrls = tasks.map((t) => t.url).toSet();
    final intersection = viewportUrls.intersection(adaptivePlannedUrls);
    final onlyAdaptive = adaptivePlannedUrls.difference(viewportUrls);
    final onlyViewport = viewportUrls.difference(adaptivePlannedUrls);
    final union = viewportUrls.union(adaptivePlannedUrls);
    final agreement = union.isEmpty ? 1.0 : intersection.length / union.length;

    // Ring distribution
    int immediateCount = 0, criticalCount = 0, nearCount = 0, bgCount = 0;
    for (final task in picked) {
      switch (_ringOfTask(task, currentIndex, config.horizon)) {
        case Ring.immediate:
          immediateCount++;
        case Ring.critical:
          criticalCount++;
        case Ring.near:
          nearCount++;
        case Ring.background:
          bgCount++;
      }
    }

    return ShadowCycleResult(
      cycleNumber: _generation,
      currentIndex: currentIndex,
      generation: _generation,
      needCount: needCount,
      plannedTasks: tasks,
      pickedTasks: picked,
      viewportUrls: viewportUrls,
      adaptiveUrls: adaptivePlannedUrls,
      intersection: intersection,
      onlyAdaptive: onlyAdaptive,
      onlyViewport: onlyViewport,
      agreement: agreement,
      immediateCount: immediateCount,
      criticalCount: criticalCount,
      nearCount: nearCount,
      backgroundCount: bgCount,
      schedulerState: scheduler.state,
      phaseTimings: phaseTimings,
    );
  }

  Ring _ringOfTask(SchedulerTask task, int currentIndex, int horizon) {
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
}

class ShadowSchedulerConfig {
  final int targetBudget;
  final int horizon;

  const ShadowSchedulerConfig({
    this.targetBudget = 10,
    this.horizon = 5,
  });
}

class ShadowCycleResult {
  final int cycleNumber;
  final int currentIndex;
  final int generation;
  final int needCount;
  final List<SchedulerTask> plannedTasks;
  final List<SchedulerTask> pickedTasks;
  final Set<String> viewportUrls;
  final Set<String> adaptiveUrls;
  final Set<String> intersection;
  final Set<String> onlyAdaptive;
  final Set<String> onlyViewport;
  final double agreement;
  final int immediateCount;
  final int criticalCount;
  final int nearCount;
  final int backgroundCount;
  final SchedulerState schedulerState;
  final Map<String, int> phaseTimings;

  ShadowCycleResult({
    required this.cycleNumber,
    required this.currentIndex,
    required this.generation,
    required this.needCount,
    required this.plannedTasks,
    required this.pickedTasks,
    required this.viewportUrls,
    required this.adaptiveUrls,
    required this.intersection,
    required this.onlyAdaptive,
    required this.onlyViewport,
    required this.agreement,
    required this.immediateCount,
    required this.criticalCount,
    required this.nearCount,
    required this.backgroundCount,
    required this.schedulerState,
    required this.phaseTimings,
  });

  int get totalPlanned => viewportUrls.length;
  int get totalAdaptive => adaptiveUrls.length;
  int get totalIntersection => intersection.length;
  int get totalOnlyAdaptive => onlyAdaptive.length;
  int get totalOnlyViewport => onlyViewport.length;
  int get totalPicked => pickedTasks.length;
}

class ShadowMetricsAggregator {
  int cycleCount = 0;
  int totalAdaptiveOnly = 0;
  int totalViewportOnly = 0;
  int totalIntersection = 0;
  double agreementSum = 0.0;
  double minAgreement = 1.0;
  double maxAgreement = 0.0;
  int largeDisagreementCount = 0;
  int totalDemandCalcTime = 0;
  int totalPlanTime = 0;
  int totalEnqueueTime = 0;
  int totalCancelTime = 0;
  int totalPickTime = 0;
  int sumNeedCount = 0;
  int sumViewportTasks = 0;
  int sumAdaptiveTasks = 0;
  int duplicatePreventions = 0;
  int galleryCycles = 0;
  int galleryAgreementSum = 0;

  void record(ShadowCycleResult result) {
    cycleCount++;
    totalAdaptiveOnly += result.totalOnlyAdaptive;
    totalViewportOnly += result.totalOnlyViewport;
    totalIntersection += result.totalIntersection;
    agreementSum += result.agreement;
    minAgreement = min(minAgreement, result.agreement);
    maxAgreement = max(maxAgreement, result.agreement);
    if (result.agreement < 0.5) largeDisagreementCount++;
    totalDemandCalcTime += result.phaseTimings['demandCalc'] ?? 0;
    totalPlanTime += result.phaseTimings['plan'] ?? 0;
    totalEnqueueTime += result.phaseTimings['enqueue'] ?? 0;
    totalCancelTime += result.phaseTimings['cancelGeneration'] ?? 0;
    totalPickTime += result.phaseTimings['pickAll'] ?? 0;
    sumNeedCount += result.needCount;
    sumViewportTasks += result.totalPlanned;
    sumAdaptiveTasks += result.totalAdaptive;
    duplicatePreventions += result.onlyViewport.length;
  }

  double get averageAgreement =>
      cycleCount > 0 ? agreementSum / cycleCount : 0.0;
  double get averageDemandCalcUs =>
      cycleCount > 0 ? totalDemandCalcTime / cycleCount : 0.0;
  double get averagePlanUs =>
      cycleCount > 0 ? totalPlanTime / cycleCount : 0.0;
  double get averageEnqueueUs =>
      cycleCount > 0 ? totalEnqueueTime / cycleCount : 0.0;
  double get averageCancelUs =>
      cycleCount > 0 ? totalCancelTime / cycleCount : 0.0;
  double get averagePickUs =>
      cycleCount > 0 ? totalPickTime / cycleCount : 0.0;
  double get averageNeedCount =>
      cycleCount > 0 ? sumNeedCount / cycleCount : 0.0;
  double get averageViewportTasks =>
      cycleCount > 0 ? sumViewportTasks / cycleCount : 0.0;
  double get averageAdaptiveTasks =>
      cycleCount > 0 ? sumAdaptiveTasks / cycleCount : 0.0;

  Map<String, dynamic> toReport() => {
        'totalCycles': cycleCount,
        'averageAgreement': averageAgreement,
        'minAgreement': minAgreement,
        'maxAgreement': maxAgreement,
        'largeDisagreements': largeDisagreementCount,
        'totalAdaptiveOnly': totalAdaptiveOnly,
        'totalViewportOnly': totalViewportOnly,
        'totalIntersection': totalIntersection,
        'averageDemandCalcUs': averageDemandCalcUs,
        'averagePlanUs': averagePlanUs,
        'averageEnqueueUs': averageEnqueueUs,
        'averageCancelUs': averageCancelUs,
        'averagePickUs': averagePickUs,
        'averageNeedCount': averageNeedCount,
        'averageViewportTasks': averageViewportTasks,
        'averageAdaptiveTasks': averageAdaptiveTasks,
        'duplicatePreventions': duplicatePreventions,
        'galleryCycles': galleryCycles,
      };
}
