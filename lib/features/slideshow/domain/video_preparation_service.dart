import 'dart:async';
import 'dart:collection';
import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/debug/trace.dart';
import 'metrics_collector.dart';
import 'slide_profiler.dart'; // TEMPORARY — Phase 7.2A

enum VideoControllerState { notCreated, preparing, ready, failed }

class _VideoEntry {
  VideoControllerState state = VideoControllerState.notCreated;
  VideoPlayerController? controller;
  Completer<VideoPlayerController>? completer;
  int priority = 0;
  Map<String, String>? headers;
}

class VideoPreparationService {
  final Map<String, _VideoEntry> _pool = {};
  final SplayTreeSet<_QueuedVideo> _queue = SplayTreeSet<_QueuedVideo>();
  int _activeCount = 0;
  final int _maxConcurrent;

  VoidCallback? onReadinessChanged;
  MetricsCollector? metrics;

  VideoPreparationService({int? maxConcurrent})
      : _maxConcurrent = maxConcurrent ?? AppConstants.maxConcurrentVideoPrep;

  int get activeCount => _activeCount;
  int get queuedCount => _queue.length;

  Future<VideoPlayerController> prepare(String url, {Map<String, String>? headers, int priority = 0}) {
    Trace.t('VPS.prepare', ['url', url.substring(0, url.length.clamp(0, 60)), 'headers', '$headers', 'priority', priority, 'poolSize', _pool.length]);
    final existing = _pool[url];
    if (existing != null) {
      switch (existing.state) {
        case VideoControllerState.ready:
          metrics?.recordEvent(MetricEventType.videoControllerReused, data: {'url': url});
          return Future.value(existing.controller!);
        case VideoControllerState.preparing:
          existing.priority = priority;
          return existing.completer!.future;
        case VideoControllerState.failed:
        case VideoControllerState.notCreated:
          break;
      }
    }

    final entry = _VideoEntry();
    entry.priority = priority;
    entry.headers = headers;
    entry.completer = Completer<VideoPlayerController>();
    _pool[url] = entry;
    metrics?.recordEvent(MetricEventType.videoControllerCreated, data: {'url': url});

    if (_activeCount < _maxConcurrent) {
      _activeCount++;
      _initController(url, entry);
    } else {
      _queue.add(_QueuedVideo(url: url, priority: priority));
    }

    return entry.completer!.future;
  }

  void updatePriority(String url, int newPriority) {
    final entry = _pool[url];
    if (entry != null) {
      entry.priority = newPriority;
    }
    if (entry == null || entry.state == VideoControllerState.notCreated || entry.state == VideoControllerState.failed) {
      _queue.removeWhere((q) => q.url == url);
      _queue.add(_QueuedVideo(url: url, priority: newPriority));
    }
  }

  void _processNextInQueue() {
    while (_activeCount < _maxConcurrent && _queue.isNotEmpty) {
      final queued = _queue.first;
      _queue.remove(queued);
      final entry = _pool[queued.url];
      if (entry != null && entry.state == VideoControllerState.notCreated) {
        _activeCount++;
        _initController(queued.url, entry);
      }
    }
  }

  Future<void> _initController(String url, _VideoEntry entry) async {
    Trace.t('VPS._initController.enter', ['url', url.substring(0, url.length.clamp(0, 60))]);
    SlideProfiler.recordVideoInitStart(url); // TEMPORARY — Phase 7.2A
    entry.state = VideoControllerState.preparing;
    final completer = entry.completer!;
    metrics?.recordEvent(MetricEventType.videoControllerInitializing, data: {'url': url});

    try {
      final controller = VideoPlayerController.networkUrl(
        Uri.parse(url),
        httpHeaders: entry.headers ?? const {},
      );
      Trace.t('VPS._initController.created', ['hash', '${controller.hashCode}', 'platform', '${VideoPlayerPlatform.instance.runtimeType}']);
      entry.controller = controller;
      await controller.initialize().timeout(
        Duration(milliseconds: AppConstants.videoInitTimeoutMs),
      );
      Trace.t('VPS._initController.success', ['hash', '${controller.hashCode}', 'size', '${controller.value.size}', 'duration', '${controller.value.duration}']);
      entry.state = VideoControllerState.ready;
      SlideProfiler.recordVideoInitEnd(url, success: true); // TEMPORARY — Phase 7.2A
      metrics?.recordEvent(MetricEventType.videoControllerReady, data: {'url': url, 'retry': false});
      _safeComplete(completer, controller);
      onReadinessChanged?.call();
    } catch (e) {
      Trace.t('VPS._initController.failed', ['url', url.substring(0, url.length.clamp(0, 60)), 'error', '$e', 'timeout', e is TimeoutException]);
      if (completer.isCompleted) return;

      if (e is TimeoutException) {
        entry.controller = null;
        entry.state = VideoControllerState.failed;
        SlideProfiler.recordVideoInitEnd(url, success: false);
        metrics?.recordEvent(MetricEventType.videoControllerFailed, data: {'url': url, 'error': e.toString()});
        _safeCompleteError(completer, e);
        onReadinessChanged?.call();
        return;
      }

      Trace.t('VPS._initController.retry', ['url', url.substring(0, url.length.clamp(0, 60))]);
      _disposeController(entry.controller);
      entry.controller = null;
      metrics?.recordEvent(MetricEventType.videoRetry, data: {'url': url, 'error': e.toString()});
      try {
        final controller = VideoPlayerController.networkUrl(
          Uri.parse(url),
          httpHeaders: entry.headers ?? const {},
        );
        Trace.t('VPS._initController.retryCreated', ['hash', '${controller.hashCode}']);
        entry.controller = controller;
        metrics?.recordEvent(MetricEventType.videoControllerInitializing, data: {'url': url, 'retry': true});
        await controller.initialize().timeout(
          Duration(milliseconds: AppConstants.videoInitTimeoutMs),
        );
        Trace.t('VPS._initController.retrySuccess', ['hash', '${controller.hashCode}']);
        entry.state = VideoControllerState.ready;
        SlideProfiler.recordVideoInitEnd(url, success: true);
        metrics?.recordEvent(MetricEventType.videoControllerReady, data: {'url': url, 'retry': true});
        _safeComplete(completer, controller);
        onReadinessChanged?.call();
        return;
      } catch (e2) {
        Trace.t('VPS._initController.retryFailed', ['url', url.substring(0, url.length.clamp(0, 60)), 'error', '$e2', 'timeout', e2 is TimeoutException]);
        if (e2 is TimeoutException) {
          entry.controller = null;
        } else {
          _disposeController(entry.controller);
          entry.controller = null;
        }
        entry.state = VideoControllerState.failed;
        SlideProfiler.recordVideoInitEnd(url, success: false);
        metrics?.recordEvent(MetricEventType.videoControllerFailed, data: {'url': url, 'error': e2.toString()});
        _safeCompleteError(completer, e2);
        onReadinessChanged?.call();
        return;
      }
    } finally {
      _activeCount--;
      _processNextInQueue();
    }
  }

  static void _safeComplete<T>(Completer<T> completer, T value) {
    try {
      if (!completer.isCompleted) completer.complete(value);
    } catch (_) {}
  }

  static void _safeCompleteError(Completer completer, Object error) {
    try {
      if (!completer.isCompleted) completer.completeError(error);
    } catch (_) {}
  }

  /// Fire-and-forget dispose with a safety timeout to prevent hanging.
  /// [VideoPlayerController.dispose] awaits [_creatingCompleter.future],
  /// which only completes after the platform call returns. If [initialize]
  /// timed out that future never completes, so dispose would hang forever.
  static void _disposeController(VideoPlayerController? controller) {
    if (controller == null) return;
    try {
      controller.dispose().timeout(const Duration(seconds: 2)).catchError((_) {});
    } catch (_) {}
  }

  bool isReady(String url) {
    final state = _pool[url]?.state;
    return state == VideoControllerState.ready;
  }

  bool isPreparing(String url) {
    final state = _pool[url]?.state;
    return state == VideoControllerState.preparing;
  }

  VideoPlayerController? getController(String url) {
    final entry = _pool[url];
    if (entry?.state == VideoControllerState.ready) {
      Trace.t('VPS.getController.hit', ['url', url.substring(0, url.length.clamp(0, 60)), 'hash', '${entry!.controller.hashCode}']);
      return entry.controller;
    }
    Trace.t('VPS.getController.miss', ['url', url.substring(0, url.length.clamp(0, 60)), 'state', '${entry?.state}']);
    return null;
  }

  bool hasFailed(String url) {
    return _pool[url]?.state == VideoControllerState.failed;
  }

  void evictOutsideWindow(Set<String> urlsInWindow) {
    final toRemove = _pool.keys.where((url) => !urlsInWindow.contains(url)).toList();
    Trace.t('VPS.evictOutsideWindow', ['inWindow', urlsInWindow.length, 'toRemove', toRemove.length, 'poolBefore', _pool.length]);
    for (final url in toRemove) {
      final entry = _pool.remove(url)!;
      if (entry.completer != null) {
        _safeCompleteError(entry.completer!, Exception('Video preparation evicted: $url'));
      }
      entry.completer = null;
      Trace.t('VPS.evictOutsideWindow.evicting', ['url', url.substring(0, url.length.clamp(0, 60)), 'state', '${entry.state}']);
      _disposeController(entry.controller);
      _queue.removeWhere((q) => q.url == url);
      metrics?.recordEvent(MetricEventType.videoControllerEvicted, data: {'url': url});
    }
  }

  void dispose() {
    Trace.t('VPS.dispose', ['pool', _pool.length, 'queue', _queue.length]);
    for (final entry in _pool.values) {
      entry.completer = null;
      _disposeController(entry.controller);
    }
    _pool.clear();
    _queue.clear();
    _activeCount = 0;
  }
}

class _QueuedVideo implements Comparable<_QueuedVideo> {
  final String url;
  final int priority;
  final int _order;

  static int _counter = 0;

  _QueuedVideo({required this.url, required this.priority})
      : _order = _counter++;

  @override
  int compareTo(_QueuedVideo other) {
    var cmp = url.compareTo(other.url);
    if (cmp != 0) return cmp;
    cmp = priority.compareTo(other.priority);
    if (cmp != 0) return cmp;
    return _order.compareTo(other._order);
  }

  @override
  bool operator ==(Object other) =>
      other is _QueuedVideo && url == other.url;

  @override
  int get hashCode => url.hashCode;
}
