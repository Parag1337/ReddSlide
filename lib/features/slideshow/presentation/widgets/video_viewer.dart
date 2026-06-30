import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import '../../../../core/debug/trace.dart';
import '../../../../core/media/media_error.dart';
import '../../../../core/media/safe_network_image.dart';
import '../../../slideshow/domain/prepared_media_handle.dart';

enum _VideoPlaybackState { idle, playing, paused, completed }

class VideoViewer extends StatefulWidget {
  final PreparedMediaHandle handle;
  final bool muted;
  final void Function(MediaErrorType errorType)? onError;
  final void Function(String url)? onFirstFrameRendered;
  final void Function(String url)? onVideoCompleted;

  const VideoViewer({
    super.key,
    required this.handle,
    required this.muted,
    this.onError,
    this.onFirstFrameRendered,
    this.onVideoCompleted,
  });

  @override
  State<VideoViewer> createState() => _VideoViewerState();
}

class _VideoViewerState extends State<VideoViewer> {
  VideoPlayerController? _attachedController;
  bool _firstFrameRendered = false;
  bool _errorReported = false;
  bool _frameEventEmitted = false;
  bool _completionEmitted = false;
  _VideoPlaybackState _playbackState = _VideoPlaybackState.idle;
  int _rebuildCount = 0;

  String get _assetId => widget.handle.asset.id;

  @override
  void initState() {
    super.initState();
    Trace.t('VV.initState', ['assetId', _assetId, 'ctrl', '${widget.handle.controller?.hashCode}', 'ctrlInit', '${widget.handle.controller?.value.isInitialized}', 'handleState', widget.handle.state.name]);
    _attachToController();
    _reportErrorIfNeeded();
  }

  @override
  void didUpdateWidget(VideoViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldCtrl = oldWidget.handle.controller;
    final newCtrl = widget.handle.controller;
    Trace.t('VV.didUpdateWidget', [
      'assetId', _assetId,
      'oldCtrl', '${oldCtrl?.hashCode}',
      'newCtrl', '${newCtrl?.hashCode}',
      'sameIdentity', oldCtrl == newCtrl,
      'attachedCtrl', '${_attachedController?.hashCode}',
      'firstFrame', _firstFrameRendered,
      'playbackState', _playbackState.name,
    ]);
    if (oldCtrl != newCtrl) {
      Trace.t('VV.didUpdateWidget.replaced', ['assetId', _assetId, 'oldCtrl', '${oldCtrl?.hashCode}', 'newCtrl', '${newCtrl?.hashCode}']);
      _detachFromController();
      _firstFrameRendered = false;
      _frameEventEmitted = false;
      _completionEmitted = false;
      _errorReported = false;
      _playbackState = _VideoPlaybackState.idle;
      _attachToController();
      _reportErrorIfNeeded();
    } else if (oldWidget.muted != widget.muted) {
      _attachedController?.setVolume(widget.muted ? 0 : 1);
      Trace.t('VV.didUpdateWidget.muted', ['assetId', _assetId, 'muted', widget.muted]);
    }
  }

  void _attachToController() {
    final c = widget.handle.controller;
    if (c == null) {
      Trace.t('VV._attachToController.bail', ['assetId', _assetId, 'reason', 'controller_null']);
      return;
    }
    if (_attachedController == c) {
      Trace.t('VV._attachToController.skip', ['assetId', _assetId, 'hash', '${c.hashCode}', 'reason', 'already_attached']);
      return;
    }
    _detachFromController();
    _attachedController = c;
    try {
      _attachedController!.addListener(_onVideoUpdate);
      final v = _attachedController!.value;
      Trace.t('VV._attachToController.ok', [
        'assetId', _assetId,
        'ctrlHash', '${c.hashCode}',
        'initialized', v.isInitialized,
        'position', '${v.position}',
        'isPlaying', v.isPlaying,
        'isBuffering', v.isBuffering,
        'hasError', v.hasError,
        'errorDesc', '${v.errorDescription}',
        'duration', '${v.duration}',
        'size', '${v.size}',
      ]);
      _attachedController!.setVolume(widget.muted ? 0 : 1);
      _attachedController!.seekTo(Duration.zero);
      _playbackState = _VideoPlaybackState.idle;
      if (c.value.isInitialized) {
        _attachedController!.play();
        _playbackState = _VideoPlaybackState.playing;
        Trace.t('VV._attachToController.play', ['assetId', _assetId, 'ctrlHash', '${c.hashCode}']);
      } else {
        Trace.t('VV._attachToController.wait', ['assetId', _assetId, 'ctrlHash', '${c.hashCode}', 'reason', 'controller_not_initialized']);
      }
    } catch (e) {
      Trace.t('VV._attachToController.exception', ['assetId', _assetId, 'error', '$e']);
      _attachedController = null;
    }
  }

  void _detachFromController() {
    final c = _attachedController;
    if (c == null) return;
    Trace.t('VV._detachFromController', ['assetId', _assetId, 'ctrlHash', '${c.hashCode}', 'playbackState', _playbackState.name]);
    try {
      c.removeListener(_onVideoUpdate);
    } catch (_) {}
    _attachedController = null;
  }

  void _onVideoUpdate() {
    final c = _attachedController;
    final v = c?.value;
    if (c == null || v == null) return;

    final justCompleted = v.position >= v.duration && v.duration > Duration.zero;
    final justStarted = !_firstFrameRendered && v.position > Duration.zero;

    Trace.t('VV._onVideoUpdate', [
      'assetId', _assetId,
      'initialized', v.isInitialized,
      'isPlaying', v.isPlaying,
      'isBuffering', v.isBuffering,
      'position', '${v.position}',
      'duration', '${v.duration}',
      'playbackState', _playbackState.name,
      'firstFrame', _firstFrameRendered,
      'completed', justCompleted,
      'hasError', v.hasError,
    ]);

    if (!v.isInitialized) return;

    // 1. Completion detection — highest priority
    if (justCompleted) {
      if (!_completionEmitted) {
        _completionEmitted = true;
        _playbackState = _VideoPlaybackState.completed;
        c.pause();
        Trace.t('VV._onVideoUpdate.completed', ['assetId', _assetId, 'position', '${v.position}', 'duration', '${v.duration}']);
        widget.onVideoCompleted?.call(widget.handle.asset.videoUrl ?? '');
      }
      return;
    }

    // 2. Auto-resume only for unexpected stops during active playback
    //    Do NOT resume if user paused or video completed.
    if (!v.isPlaying) {
      if (_playbackState == _VideoPlaybackState.playing) {
        final isStalled = v.isBuffering;
        if (!isStalled) {
          Trace.t('VV._onVideoUpdate.autoResume', ['assetId', _assetId, 'reason', 'unexpected_stop']);
          c.play();
        }
      }
      // _playbackState == paused or completed: do nothing
      return;
    }

    // 3. Video is playing — update state
    if (_playbackState != _VideoPlaybackState.paused) {
      _playbackState = _VideoPlaybackState.playing;
    }

    // 4. First frame detection
    if (justStarted) {
      Trace.t('VV._onVideoUpdate.firstFrame', ['assetId', _assetId, 'position', '${v.position}']);
      if (mounted) setState(() => _firstFrameRendered = true);
      if (!_frameEventEmitted) {
        _frameEventEmitted = true;
        widget.onFirstFrameRendered?.call(widget.handle.asset.videoUrl ?? '');
      }
    }
  }

  /// Called when the user taps the video to toggle play/pause.
  void _handleTap() {
    final c = _attachedController;
    if (c == null || !c.value.isInitialized) return;

    switch (_playbackState) {
      case _VideoPlaybackState.playing:
        _playbackState = _VideoPlaybackState.paused;
        c.pause();
        Trace.t('VV._handleTap.pause', ['assetId', _assetId]);
        if (mounted) setState(() {});
        break;
      case _VideoPlaybackState.paused:
        c.play();
        _playbackState = _VideoPlaybackState.playing;
        Trace.t('VV._handleTap.resume', ['assetId', _assetId]);
        if (mounted) setState(() {});
        break;
      case _VideoPlaybackState.completed:
        c.seekTo(Duration.zero);
        c.play();
        _playbackState = _VideoPlaybackState.playing;
        _completionEmitted = false;
        if (mounted) setState(() => _firstFrameRendered = false);
        Trace.t('VV._handleTap.replay', ['assetId', _assetId]);
        break;
      case _VideoPlaybackState.idle:
        break;
    }
  }

  void _reportErrorIfNeeded() {
    if (!widget.handle.preparationFailed || _errorReported) return;
    _errorReported = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.onError?.call(MediaErrorType.videoInitError);
    });
  }

  @override
  void dispose() {
    Trace.t('VV.dispose', ['assetId', _assetId, 'ctrlHash', '${_attachedController?.hashCode}', 'firstFrame', _firstFrameRendered, 'playbackState', _playbackState.name]);
    _detachFromController();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _rebuildCount++;
    final c = _attachedController;
    final initialized = c != null && c.value.isInitialized;
    final guardEntered = !initialized || (!_firstFrameRendered && widget.handle.displayThumbnailUrl.isNotEmpty);

    Trace.t('VV.build', [
      'assetId', _assetId,
      'build#', _rebuildCount,
      'ctrlHash', '${c?.hashCode}',
      'initialized', initialized,
      'firstFrame', _firstFrameRendered,
      'playbackState', _playbackState.name,
      'thumb', widget.handle.displayThumbnailUrl.isNotEmpty,
      'guardEntered', guardEntered,
    ]);

    if (widget.handle.preparationFailed && widget.handle.displayThumbnailUrl.isNotEmpty) {
      return Center(
        child: SafeNetworkImage(
          url: widget.handle.displayThumbnailUrl,
          fit: BoxFit.contain,
        ),
      );
    }

    if (!initialized || (!_firstFrameRendered && widget.handle.displayThumbnailUrl.isNotEmpty)) {
      return Center(
        child: widget.handle.displayThumbnailUrl.isNotEmpty
            ? Stack(
                fit: StackFit.expand,
                children: [
                  SafeNetworkImage(
                    url: widget.handle.displayThumbnailUrl,
                    fit: BoxFit.contain,
                  ),
                  if (!initialized)
                    const Center(
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                ],
              )
            : const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }

    Trace.t('VV.build.insertVideoPlayer', ['assetId', _assetId, 'aspectRatio', '${c.value.aspectRatio}']);
    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          Center(
            child: AspectRatio(
              aspectRatio: c.value.aspectRatio,
              child: VideoPlayer(c),
            ),
          ),
          GestureDetector(
            onTap: _handleTap,
          ),
        ],
      ),
    );
  }
}
