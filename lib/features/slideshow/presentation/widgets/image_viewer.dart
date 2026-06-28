import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../../../../core/media/media_error.dart';
import '../../../slideshow/domain/prepared_media_handle.dart';

class ImageViewer extends StatefulWidget {
  final PreparedMediaHandle handle;
  final void Function(MediaErrorType errorType)? onError;
  final void Function(String url)? onFirstFrameDecoded;

  const ImageViewer({
    super.key,
    required this.handle,
    this.onError,
    this.onFirstFrameDecoded,
  });

  @override
  State<ImageViewer> createState() => _ImageViewerState();
}

class _ImageViewerState extends State<ImageViewer> with SingleTickerProviderStateMixin {
  final TransformationController _transformController = TransformationController();
  late final AnimationController _fadeController;
  late final Animation<double> _fadeAnimation;
  bool _zoomed = false;
  bool _hasDecodedFrame = false;
  bool _reportedFailure = false;

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeIn,
    );
  }

  @override
  void didUpdateWidget(ImageViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.handle.displayUrl != widget.handle.displayUrl) {
      _zoomed = false;
      _hasDecodedFrame = false;
      _reportedFailure = false;
      _fadeController.value = 0.0;
      _transformController.value = Matrix4.identity();
    }
  }

  @override
  void dispose() {
    _fadeController.dispose();
    _transformController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.handle.state;

    if (state == MediaState.failed) {
      return RepaintBoundary(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.broken_image, color: Colors.white38, size: 48),
              SizedBox(height: 12),
              Text('Failed to load', style: TextStyle(color: Colors.white38)),
            ],
          ),
        ),
      );
    }

    if (state != MediaState.ready) {
      return RepaintBoundary(
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white38,
                ),
              ),
              SizedBox(height: 12),
              Text(_stateLabel(state), style: TextStyle(color: Colors.white38)),
            ],
          ),
        ),
      );
    }

    final decodeWidth = widget.handle.decodeSize?.width;

    return RepaintBoundary(
      child: FadeTransition(
        opacity: _fadeAnimation,
        child: GestureDetector(
          onDoubleTap: _handleDoubleTap,
          child: InteractiveViewer(
            transformationController: _transformController,
            minScale: 1.0,
            maxScale: 4.0,
            boundaryMargin: const EdgeInsets.all(20),
            child: Image(
              image: ResizeImage.resizeIfNeeded(
                decodeWidth,
                null,
                CachedNetworkImageProvider(widget.handle.displayUrl),
              ),
              fit: BoxFit.contain,
              gaplessPlayback: true,
              loadingBuilder: (context, child, loadingProgress) {
                if (loadingProgress == null) return child;
                return child;
              },
              errorBuilder: (context, error, stackTrace) {
                if (!_reportedFailure) {
                  _reportedFailure = true;
                  widget.onError?.call(_classifyError(error));
                }
                return Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.broken_image, color: Colors.white38, size: 48),
                      SizedBox(height: 12),
                      Text('Failed to load', style: TextStyle(color: Colors.white38)),
                    ],
                  ),
                );
              },
              frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
                if (frame != null && !_hasDecodedFrame) {
                  _hasDecodedFrame = true;
                  _fadeController.forward();
                  widget.onFirstFrameDecoded?.call(widget.handle.displayUrl);
                }
                return child;
              },
            ),
          ),
        ),
      ),
    );
  }

  String _stateLabel(MediaState state) {
    switch (state) {
      case MediaState.notRequested:
      case MediaState.evicted:
        return 'Waiting...';
      case MediaState.queued:
        return 'Queued...';
      case MediaState.preparing:
        return 'Preparing...';
      case MediaState.ready:
      case MediaState.failed:
        return '';
    }
  }

  void _handleDoubleTap() {
    if (_zoomed) {
      _transformController.value = Matrix4.identity();
      _zoomed = false;
    } else {
      final position = _transformController.value;
      position.scaleByDouble(2.0, 2.0, 2.0, 1);
      _transformController.value = position;
      _zoomed = true;
    }
  }

  static MediaErrorType _classifyError(Object error) {
    try {
      final statusCode = (error as dynamic).statusCode;
      if (statusCode == 404) return MediaErrorType.http404;
      if (statusCode == 410) return MediaErrorType.http410;
    } catch (_) {}
    final msg = error.toString().toLowerCase();
    if (msg.contains('404') || msg.contains('not found')) return MediaErrorType.http404;
    if (msg.contains('410') || msg.contains('gone')) return MediaErrorType.http410;
    if (msg.contains('timeout') || msg.contains('timed out')) return MediaErrorType.timeout;
    if (msg.contains('socket') || msg.contains('connection')) return MediaErrorType.socketError;
    return MediaErrorType.unknown;
  }
}
