import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';

enum VideoControllerState { notCreated, preparing, ready, failed }

class _VideoEntry {
  VideoControllerState state = VideoControllerState.notCreated;
  VideoPlayerController? controller;
  Completer<VideoPlayerController>? completer;
}

class VideoPreparationService {
  final Map<String, _VideoEntry> _pool = {};

  VoidCallback? onReadinessChanged;

  Future<VideoPlayerController> prepare(String url) {
    final existing = _pool[url];
    if (existing != null) {
      switch (existing.state) {
        case VideoControllerState.ready:
          return Future.value(existing.controller!);
        case VideoControllerState.preparing:
          return existing.completer!.future;
        case VideoControllerState.failed:
        case VideoControllerState.notCreated:
          break;
      }
    }

    final entry = _VideoEntry();
    _pool[url] = entry;
    _initController(url, entry);
    return entry.completer!.future;
  }

  Future<void> _initController(String url, _VideoEntry entry) async {
    entry.state = VideoControllerState.preparing;
    final completer = Completer<VideoPlayerController>();
    entry.completer = completer;

    try {
      final controller = VideoPlayerController.networkUrl(Uri.parse(url));
      entry.controller = controller;
      await controller.initialize();
      entry.state = VideoControllerState.ready;
      _safeComplete(completer, controller);
      onReadinessChanged?.call();
    } catch (e) {
      if (completer.isCompleted) return;
      // Retry once
      try {
        final controller = VideoPlayerController.networkUrl(Uri.parse(url));
        entry.controller = controller;
        await controller.initialize();
        entry.state = VideoControllerState.ready;
        _safeComplete(completer, controller);
        onReadinessChanged?.call();
      } catch (e2) {
        entry.controller?.dispose();
        entry.controller = null;
        entry.state = VideoControllerState.failed;
        _safeCompleteError(completer, e2);
        onReadinessChanged?.call();
      }
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
    }
  }

  void dispose() {
    for (final entry in _pool.values) {
      entry.completer = null;
      entry.controller?.dispose();
    }
    _pool.clear();
  }
}
