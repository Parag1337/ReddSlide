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
  bool _videoFailed = false;
  int _retryCount = 0;

  @override
  void initState() {
    super.initState();
    _initController();
  }

  @override
  void didUpdateWidget(VideoViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.videoUrl != widget.videoUrl) {
      _controller?.dispose();
      _initialized = false;
      _videoFailed = false;
      _retryCount = 0;
      _initController();
    } else if (oldWidget.muted != widget.muted) {
      _controller?.setVolume(widget.muted ? 0 : 1);
    }
  }

  Future<void> _initController() async {
    _controller = VideoPlayerController.networkUrl(Uri.parse(widget.videoUrl));
    try {
      await _controller!.initialize();
      await _controller!.setVolume(widget.muted ? 0 : 1);
      await _controller!.setLooping(true);
      await _controller!.play();
      if (mounted) {
        setState(() => _initialized = true);
      }
    } catch (e) {
      debugPrint('[VideoViewer] Failed to initialize video: url=${widget.videoUrl} error=$e');
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

    if (!_initialized) {
      return Center(
        child: widget.thumbnailUrl != null
            ? Stack(
                fit: StackFit.expand,
                children: [
                  SafeNetworkImage(
                    url: widget.thumbnailUrl!,
                    fit: BoxFit.contain,
                  ),
                  const Center(
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ],
              )
            : const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }

    return Stack(
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
    );
  }
}
