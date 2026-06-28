import 'dart:async';
import 'dart:developer';
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../core/constants/app_constants.dart';
import 'adaptive_preloader.dart';
import 'demand_calculator.dart';
import 'playlist_manager.dart';
import 'preparation_scheduler.dart';
import 'readiness_state.dart';
import 'scheduler_task.dart';
import 'slide_profiler.dart';
import 'task_planner.dart';
import 'viewport_scheduler.dart';

typedef MeasureWindowFn = List<ReadinessState> Function(int currentIndex, int horizon);
typedef PreloadFunction = Future<void> Function(String url, BuildContext context);

Future<void> _defaultPreload(String url, BuildContext context) async {
  await precacheImage(
    CachedNetworkImageProvider(url),
    context,
  );
}

class ViewportSchedulerAdapter implements PreparationScheduler {
  final PlaylistManager _playlist;
  final LoadMoreCallback _onLoadMore;
  final BuildContext _context;
  final MeasureWindowFn _measureWindow;
  final PreloadFunction _preloadFn;
  int _concurrentCount = 0;
  bool _failed = false;
  Timer? _generationTimer;

  final Set<String> _inProgress = {};
  final Set<String> _completed = {};
  final Set<String> _failedUrls = {};

  static const int _maxConcurrent = AppConstants.maxConcurrentPreloads;
  static const int _targetBudget = 10;
  static const int _horizon = 5;
  static const int _majorJumpThreshold = 20;
  static const int _generationExpiryMs = 30 * 1000;

  int _generation = 0;
  int _lastIndex = -1;

  final ViewportScheduler _scheduler = ViewportScheduler();
  final DemandCalculator _demandCalculator = const DemandCalculator();
  final TaskPlanner _taskPlanner = const TaskPlanner();

  @override
  void Function(String url)? onUrlStarted;
  @override
  void Function(String url)? onUrlReady;
  @override
  void Function(String url)? onUrlFailed;

  ViewportSchedulerAdapter({
    required PlaylistManager playlist,
    required LoadMoreCallback onLoadMore,
    required BuildContext context,
    required MeasureWindowFn measureWindow,
    PreloadFunction? preloadFn,
  })  : _playlist = playlist,
        _onLoadMore = onLoadMore,
        _context = context,
        _measureWindow = measureWindow,
        _preloadFn = preloadFn ?? _defaultPreload;

  @override
  void onIndexChanged(int currentIndex, {int galleryIndex = 0}) {
    if (_failed) return _fallbackToPreloader(currentIndex);

    try {
      _onIndexChangedInternal(currentIndex, galleryIndex: galleryIndex);
    } catch (e, stack) {
      log('[VIEWPORT_SCHEDULER] Error: $e\n$stack');
      _failed = true;
      _fallbackToPreloader(currentIndex);
    }
  }

  void _onIndexChangedInternal(int currentIndex, {int galleryIndex = 0}) {
    final needsNewGeneration = _shouldStartNewGeneration(currentIndex);
    if (needsNewGeneration) {
      _generation++;
      _generationTimer?.cancel();
      _generationTimer = Timer(
        Duration(milliseconds: _generationExpiryMs),
        () {
          if (!_failed) {
            _generation++;
          }
        },
      );
    }
    _lastIndex = currentIndex;

    final items = _playlist.items;
    if (items.isEmpty || currentIndex >= items.length) {
      _scheduler.cancelGeneration(_generation);
      return;
    }

    final t1 = Stopwatch()..start();
    final states = _measureReadiness(currentIndex);
    final needCount = _demandCalculator.computeNeedCount(
      states,
      targetBudget: _targetBudget,
    );
    final demandCalcUs = t1.elapsedMicroseconds;

    final t2 = Stopwatch()..start();
    final tasks = _taskPlanner.plan(
      items: items,
      currentIndex: currentIndex,
      horizon: _horizon,
      needCount: needCount,
      generation: _generation,
      galleryIndex: galleryIndex,
    );
    final planUs = t2.elapsedMicroseconds;

    if (needsNewGeneration && _generation > 1) {
      _scheduler.cancelGeneration(_generation - 1);
    }

    final t3 = Stopwatch()..start();
    _scheduler.enqueue(
      tasks: tasks,
      currentIndex: currentIndex,
      horizon: _horizon,
    );
    final enqueueUs = t3.elapsedMicroseconds;

    SlideProfiler.recordSchedulerDemandCalc(demandCalcUs);
    SlideProfiler.recordSchedulerPlan(planUs);
    SlideProfiler.recordSchedulerEnqueue(enqueueUs);

    final ringCounts = _scheduler.ringCounts;
    final readyCount = states.where((s) => s == ReadinessState.ready).length;
    SlideProfiler.recordSchedulerReadinessScore(
      states.isEmpty ? 0 : (readyCount * 100 ~/ states.length),
    );

    SlideProfiler.recordSchedulerInfo(
      currentScheduler: 'viewport',
      schedulerMode: 'viewport',
      needCount: needCount,
      readyHorizon: _horizon,
      prepBudget: _targetBudget,
      generation: _generation,
      pendingTasks: _scheduler.pendingCount,
      completedTasks: _completed.length,
      cancelledTasks: 0,
      ring0: ringCounts[0],
      ring1: ringCounts[1],
      ring2: ringCounts[2],
      ring3: ringCounts[3],
      isActive: _scheduler.state == SchedulerState.active,
      isSatisfied: _scheduler.state == SchedulerState.satisfied,
      isSleeping: _scheduler.state == SchedulerState.sleeping,
      isResuming: false,
    );

    _checkLoadMore(currentIndex);
    _drain();
  }

  bool _shouldStartNewGeneration(int currentIndex) {
    if (_generation == 0) return true;
    final jump = (currentIndex - _lastIndex).abs();
    if (jump > _majorJumpThreshold) return true;
    return false;
  }

  List<ReadinessState> _measureReadiness(int currentIndex) {
    return _measureWindow(currentIndex, _horizon);
  }

  void _drain() {
    int picked = 0;
    int pickTaskUs = 0;
    while (_concurrentCount < _maxConcurrent) {
      final sw = Stopwatch()..start();
      final task = _scheduler.pickTask();
      pickTaskUs += sw.elapsedMicroseconds;
      if (task == null) break;
      _scheduler.markStarted(task);
      _concurrentCount++;
      picked++;
      _executeTask(task);
    }
    if (picked > 0 && pickTaskUs > 0) {
      SlideProfiler.recordSchedulerPickTask(pickTaskUs);
    }
    SlideProfiler.recordSchedulerWorker(_concurrentCount);
  }

  Future<void> _executeTask(SchedulerTask task) async {
    final url = task.url;
    _inProgress.add(url);
    _preloadStarted(url);

    try {
      await _preloadFn(url, _context)
          .timeout(const Duration(milliseconds: AppConstants.imagePreloadTimeoutMs));
      _inProgress.remove(url);
      _completed.add(url);
      _preloadCompleted(url);
    } catch (e) {
      _inProgress.remove(url);
      _failedUrls.add(url);
      _preloadFailed(url);
    } finally {
      _concurrentCount--;
      _scheduler.markCompleted(task);
      if (!_failed) {
        _drain();
      }
    }
  }

  void _preloadStarted(String url) {
    onUrlStarted?.call(url);
  }

  void _preloadCompleted(String url) {
    onUrlReady?.call(url);
  }

  void _preloadFailed(String url) {
    onUrlFailed?.call(url);
  }

  void _checkLoadMore(int currentIndex) {
    final remaining = _playlist.remainingCount;
    if (remaining <= AppConstants.preloadTriggerRemaining) {
      unawaited(_onLoadMore());
    }
  }

  void _fallbackToPreloader(int currentIndex) {
    log('[VIEWPORT_SCHEDULER] Falling back to AdaptivePreloader');
    _scheduler.clear();
    _generation = 0;
    _concurrentCount = 0;
    _inProgress.clear();
    _completed.clear();
    _failedUrls.clear();
  }

  @override
  void onPlaylistReplaced() {
    _generation++;
    if (_generation > 1) {
      _scheduler.cancelGeneration(_generation - 1);
    }
  }

  @override
  Set<String> get plannedUrls {
    final urls = <String>{};
    urls.addAll(_inProgress);
    urls.addAll(_completed);
    return urls;
  }

  @override
  bool get isIdle => _concurrentCount == 0 && _scheduler.pendingCount == 0;

  @override
  bool get hasFailed => _failed;

  @override
  void dispose() {
    _generationTimer?.cancel();
    _scheduler.clear();
    _inProgress.clear();
    _completed.clear();
    _failedUrls.clear();
  }
}
