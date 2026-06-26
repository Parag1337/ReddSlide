import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../../../../core/media/media_error.dart';

class ImageViewer extends StatefulWidget {
  final String imageUrl;
  final void Function(MediaErrorType errorType)? onError;

  const ImageViewer({
    super.key,
    required this.imageUrl,
    this.onError,
  });

  @override
  State<ImageViewer> createState() => _ImageViewerState();
}

class _ImageViewerState extends State<ImageViewer> {
  final TransformationController _transformController = TransformationController();
  bool _zoomed = false;
  int? _widgetCreatedTs;
  int? _imageReadyTs;
  bool _loggedFirstBuild = false;

  @override
  void initState() {
    super.initState();
    _widgetCreatedTs = DateTime.now().millisecondsSinceEpoch;
  }

  @override
  void didUpdateWidget(ImageViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl) {
      _zoomed = false;
      _transformController.value = Matrix4.identity();
      _imageReadyTs = null;
      _widgetCreatedTs = DateTime.now().millisecondsSinceEpoch;
    }
  }

  @override
  void dispose() {
    _transformController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final buildTs = DateTime.now().millisecondsSinceEpoch;
    if (!_loggedFirstBuild && _widgetCreatedTs != null) {
      _loggedFirstBuild = true;
      final elapsed = buildTs - _widgetCreatedTs!;
      debugPrint('[IMG_WIDGET_CREATED] url=${widget.imageUrl} '
          'firstBuildElapsed=${elapsed}ms');
    }
    return GestureDetector(
      onDoubleTap: _handleDoubleTap,
      child: InteractiveViewer(
        transformationController: _transformController,
        minScale: 1.0,
        maxScale: 4.0,
        boundaryMargin: const EdgeInsets.all(20),
        child: Image(
          image: CachedNetworkImageProvider(widget.imageUrl),
          fit: BoxFit.contain,
          gaplessPlayback: true,
          errorBuilder: (context, error, stackTrace) {
            final errorType = _classifyError(error);
            debugPrint('[IMG_FAILED] url=${widget.imageUrl} errorType=${errorType.label}');
            WidgetsBinding.instance.addPostFrameCallback((_) {
              widget.onError?.call(errorType);
            });
            return const SizedBox.shrink();
          },
          frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
            if (wasSynchronouslyLoaded) {
              debugPrint('[IMAGE_SYNC] url=${widget.imageUrl}');
            }
            if (frame == 0 && !wasSynchronouslyLoaded) {
              debugPrint('[IMG_LOADING] url=${widget.imageUrl} source=frameBuilder');
            }
            if (frame != null && _imageReadyTs == null) {
              final now = DateTime.now().millisecondsSinceEpoch;
              final elapsedFromWidgetCreate = _widgetCreatedTs != null ? now - _widgetCreatedTs! : -1;
              final elapsedFromBuild = now - buildTs;
              _imageReadyTs = now;
              debugPrint('[IMAGE_READY] url=${widget.imageUrl} '
                  'widgetToReady=${elapsedFromWidgetCreate}ms '
                  'buildToReady=${elapsedFromBuild}ms '
                  'wasSynchronous=$wasSynchronouslyLoaded');
              WidgetsBinding.instance.addPostFrameCallback((_) {
                final visibleTs = DateTime.now().millisecondsSinceEpoch;
                debugPrint('[IMAGE_VISIBLE] url=${widget.imageUrl} readyToVisible=${visibleTs - now}ms');
              });
              debugPrint('[SLIDE_DONE] url=${widget.imageUrl} source=CachedNetworkImageProvider');
            }
            return child;
          },
        ),
      ),
    );
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
