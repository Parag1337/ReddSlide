import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import '../../../../core/media/media_error.dart';
import '../../../../core/media/safe_network_image.dart';
import '../../../slideshow/domain/prepared_media_handle.dart';

class VideoViewer extends StatefulWidget {
  final PreparedMediaHandle handle;
  final bool muted;
  final void Function(MediaErrorType errorType)? onError;
  final void Function(String url)? onFirstFrameRendered;

  const VideoViewer({
    super.key,
    required this.handle,
    required this.muted,
    this.onError,
    this.onFirstFrameRendered,
  });

  @override
  State<VideoViewer> createState() => _VideoViewerState();
}

class _VideoViewerState extends State<VideoViewer> {
  VideoPlayerController? _attachedController;
  bool _firstFrameRendered = false;
  bool _errorReported = false;
  bool _frameEventEmitted = false;

  @override
  void initState() {
    super.initState();
    _attachToController();
    _reportErrorIfNeeded();
  }

  @override
  void didUpdateWidget(VideoViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.handle.asset.id != widget.handle.asset.id) {
      _detachFromController();
      _firstFrameRendered = false;
      _frameEventEmitted = false;
      _errorReported = false;
      _attachToController();
      _reportErrorIfNeeded();
    } else if (oldWidget.muted != widget.muted) {
      _attachedController?.setVolume(widget.muted ? 0 : 1);
    }
  }

  void _attachToController() {
    final c = widget.handle.controller;
    if (c == null || !c.value.isInitialized) return;
    _attachedController = c;
    try {
      _attachedController!.addListener(_onVideoUpdate);
      _attachedController!.setVolume(widget.muted ? 0 : 1);
      _attachedController!.seekTo(Duration.zero);
      _attachedController!.play();
    } catch (_) {
      _attachedController = null;
    }
  }

  void _detachFromController() {
    final c = _attachedController;
    if (c == null) return;
    try {
      c.removeListener(_onVideoUpdate);
    } catch (_) {}
    _attachedController = null;
  }

  void _onVideoUpdate() {
    if (!_attachedController!.value.isInitialized) return;
    final position = _attachedController!.value.position;
    if (!_firstFrameRendered && position > Duration.zero) {
      if (mounted) setState(() => _firstFrameRendered = true);
      if (!_frameEventEmitted) {
        _frameEventEmitted = true;
        widget.onFirstFrameRendered?.call(widget.handle.asset.videoUrl ?? '');
      }
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
    _detachFromController();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.handle.preparationFailed && widget.handle.displayThumbnailUrl.isNotEmpty) {
      return Center(
        child: SafeNetworkImage(
          url: widget.handle.displayThumbnailUrl,
          fit: BoxFit.contain,
        ),
      );
    }

    final c = _attachedController;
    final initialized = c != null && c.value.isInitialized;

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
            onTap: () {
              if (c.value.isPlaying) {
                c.pause();
              } else {
                c.play();
              }
            },
          ),
        ],
      ),
    );
  }
}
