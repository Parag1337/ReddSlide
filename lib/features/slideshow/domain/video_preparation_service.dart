import 'dart:async';
import 'dart:collection';
import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';
import '../../../core/constants/app_constants.dart';
import 'metrics_collector.dart';
import 'slide_profiler.dart'; // TEMPORARY — Phase 7.2A

enum VideoControllerState { notCreated, preparing, ready, failed }

class _VideoEntry {
  VideoControllerState state = VideoControllerState.notCreated;
  VideoPlayerController? controller;
  Completer<VideoPlayerController>? completer;
  int priority = 0;
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

  Future<VideoPlayerController> prepare(String url, {int priority = 0}) {
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
    _queue.removeWhere((q) => q.url == url);
    _queue.add(_QueuedVideo(url: url, priority: newPriority));
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
    SlideProfiler.recordVideoInitStart(url); // TEMPORARY — Phase 7.2A
    entry.state = VideoControllerState.preparing;
    final completer = entry.completer!;
    metrics?.recordEvent(MetricEventType.videoControllerInitializing, data: {'url': url});

    try {
      final controller = VideoPlayerController.networkUrl(Uri.parse(url));
      entry.controller = controller;
      await controller.initialize().timeout(
        Duration(milliseconds: AppConstants.videoInitTimeoutMs),
      );
      entry.state = VideoControllerState.ready;
      SlideProfiler.recordVideoInitEnd(url, success: true); // TEMPORARY — Phase 7.2A
      metrics?.recordEvent(MetricEventType.videoControllerReady, data: {'url': url, 'retry': false});
      _safeComplete(completer, controller);
      onReadinessChanged?.call();
    } catch (e) {
      if (completer.isCompleted) return;
      entry.controller?.dispose();
      final isTimeout = e is TimeoutException;

      if (!isTimeout) {
        metrics?.recordEvent(MetricEventType.videoRetry, data: {'url': url, 'error': e.toString()});
        try {
          final controller = VideoPlayerController.networkUrl(Uri.parse(url));
          entry.controller = controller;
          metrics?.recordEvent(MetricEventType.videoControllerInitializing, data: {'url': url, 'retry': true});
          await controller.initialize().timeout(
            Duration(milliseconds: AppConstants.videoInitTimeoutMs),
          );
          entry.state = VideoControllerState.ready;
          SlideProfiler.recordVideoInitEnd(url, success: true); // TEMPORARY — Phase 7.2A
          metrics?.recordEvent(MetricEventType.videoControllerReady, data: {'url': url, 'retry': true});
          _safeComplete(completer, controller);
          onReadinessChanged?.call();
          return;
        } catch (e2) {
          entry.controller?.dispose();
          entry.controller = null;
          entry.state = VideoControllerState.failed;
          SlideProfiler.recordVideoInitEnd(url, success: false); // TEMPORARY — Phase 7.2A
          metrics?.recordEvent(MetricEventType.videoControllerFailed, data: {'url': url, 'error': e2.toString()});
          _safeCompleteError(completer, e2);
          onReadinessChanged?.call();
          return;
        }
      }

      entry.controller?.dispose();
      entry.controller = null;
      entry.state = VideoControllerState.failed;
      SlideProfiler.recordVideoInitEnd(url, success: false); // TEMPORARY — Phase 7.2A
      metrics?.recordEvent(MetricEventType.videoControllerFailed, data: {'url': url, 'error': e.toString()});
      _safeCompleteError(completer, e);
      onReadinessChanged?.call();
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

  bool isReady(String url) {
    return _pool[url]?.state == VideoControllerState.ready;
  }

  bool isPreparing(String url) {
    return _pool[url]?.state == VideoControllerState.preparing;
  }

  VideoPlayerController? getController(String url) {
    final entry = _pool[url];
    if (entry?.state == VideoControllerState.ready) return entry!.controller;
    return null;
  }

  bool hasFailed(String url) {
    return _pool[url]?.state == VideoControllerState.failed;
  }

  void evictOutsideWindow(Set<String> urlsInWindow) {
    final toRemove = _pool.keys.where((url) => !urlsInWindow.contains(url)).toList();
    for (final url in toRemove) {
      final entry = _pool.remove(url)!;
      entry.completer = null;
      entry.controller?.dispose();
      _queue.removeWhere((q) => q.url == url);
      metrics?.recordEvent(MetricEventType.videoControllerEvicted, data: {'url': url});
    }
  }

  void dispose() {
    for (final entry in _pool.values) {
      entry.completer = null;
      entry.controller?.dispose();
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
    final cmp = priority.compareTo(other.priority);
    if (cmp != 0) return cmp;
    return _order.compareTo(other._order);
  }

  @override
  bool operator ==(Object other) =>
      other is _QueuedVideo && url == other.url;

  @override
  int get hashCode => url.hashCode;
}
