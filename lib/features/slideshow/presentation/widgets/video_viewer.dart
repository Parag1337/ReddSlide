import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import '../../../../core/media/media_error.dart';
import '../../../../core/media/safe_network_image.dart';

class VideoViewer extends StatefulWidget {
  final String videoUrl;
  final String? thumbnailUrl;
  final bool muted;
  final void Function(MediaErrorType errorType)? onError;

  const VideoViewer({
    super.key,
    required this.videoUrl,
    this.thumbnailUrl,
    required this.muted,
    this.onError,
  });

  @override
  State<VideoViewer> createState() => _VideoViewerState();
}

class _VideoViewerState extends State<VideoViewer> {
  VideoPlayerController? _controller;
  bool _initialized = false;
  bool _firstFrameRendered = false;
  bool _videoFailed = false;
  bool _videoVisibleLogged = false;
  int _retryCount = 0;
  int _pipelineStart = 0;

  @override
  void initState() {
    super.initState();
    _initController();
  }

  @override
  void didUpdateWidget(VideoViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoUrl != widget.videoUrl) {
      _controller?.removeListener(_onVideoUpdate);
      _controller?.dispose();
      _initialized = false;
      _firstFrameRendered = false;
      _videoFailed = false;
      _videoVisibleLogged = false;
      _retryCount = 0;
      _initController();
    } else if (oldWidget.muted != widget.muted) {
      _controller?.setVolume(widget.muted ? 0 : 1);
    }
  }

  void _onVideoUpdate() {
    if (!_controller!.value.isInitialized) return;
    final position = _controller!.value.position;
    if (!_firstFrameRendered && position > Duration.zero) {
      if (mounted) {
        setState(() => _firstFrameRendered = true);
      }
    }
    if (!_videoVisibleLogged && position > Duration.zero) {
      _videoVisibleLogged = true;
      final visibleTs = DateTime.now().millisecondsSinceEpoch;
      debugPrint('[VIDEO_VISIBLE] url=${widget.videoUrl} '
          'totalToVisible=${visibleTs - _pipelineStart}ms');
    }
  }

  Future<void> _initController() async {
    debugPrint('[VIDEO_ENTER] url=${widget.videoUrl}');
    _pipelineStart = DateTime.now().millisecondsSinceEpoch;
    final createSw = Stopwatch()..start();
    _controller = VideoPlayerController.networkUrl(Uri.parse(widget.videoUrl));
    final createMs = createSw.elapsedMilliseconds;
    debugPrint('[VIDEO_CONTROLLER_CREATE] url=${widget.videoUrl} elapsed=${createMs}ms');

    final initSw = Stopwatch()..start();
    debugPrint('[VIDEO_INITIALIZE_START] url=${widget.videoUrl}');
    try {
      await _controller!.initialize();
      final initMs = initSw.elapsedMilliseconds;
      debugPrint('[VIDEO_INITIALIZE_DONE] url=${widget.videoUrl} elapsed=${initMs}ms');

      await _controller!.setVolume(widget.muted ? 0 : 1);
      await _controller!.setLooping(true);
      _controller!.addListener(_onVideoUpdate);

      await _controller!.play();
      final totalMs = createMs + initMs;
      debugPrint('[VIDEO_PLAY] url=${widget.videoUrl} '
          'create=${createMs}ms init=${initMs}ms total=${totalMs}ms');
      if (mounted) {
        setState(() {
          _initialized = true;
        });
      }
    } catch (e) {
      final initMs = initSw.elapsedMilliseconds;
      debugPrint('[VIDEO_INITIALIZE_FAILED] url=${widget.videoUrl} elapsed=${initMs}ms error=$e');
      if (_retryCount < 1) {
        _retryCount++;
        _controller?.dispose();
        _controller = null;
        _initController();
        return;
      }
      if (widget.thumbnailUrl != null && mounted) {
        setState(() => _videoFailed = true);
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.onError?.call(MediaErrorType.videoInitError);
      });
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_videoFailed && widget.thumbnailUrl != null) {
      return Center(
        child: SafeNetworkImage(
          url: widget.thumbnailUrl!,
          fit: BoxFit.contain,
        ),
      );
    }

    if (!_initialized || (!_firstFrameRendered && widget.thumbnailUrl != null)) {
      return Center(
        child: widget.thumbnailUrl != null
            ? Stack(
                fit: StackFit.expand,
                children: [
                  SafeNetworkImage(
                    url: widget.thumbnailUrl!,
                    fit: BoxFit.contain,
                  ),
                  if (!_initialized)
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
              aspectRatio: _controller!.value.aspectRatio,
              child: VideoPlayer(_controller!),
            ),
          ),
          GestureDetector(
            onTap: () {
              if (_controller!.value.isPlaying) {
                _controller!.pause();
              } else {
                _controller!.play();
              }
            },
          ),
        ],
      ),
    );
  }
}
