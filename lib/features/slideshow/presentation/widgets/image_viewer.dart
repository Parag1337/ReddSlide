import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../../../../core/media/media_error.dart';
import '../../../slideshow/domain/prepared_media_handle.dart';

class ImageViewer extends StatefulWidget {
  final PreparedMediaHandle handle;
  final void Function(MediaErrorType errorType)? onError;

  const ImageViewer({
    super.key,
    required this.handle,
    this.onError,
  });

  @override
  State<ImageViewer> createState() => _ImageViewerState();
}

class _ImageViewerState extends State<ImageViewer> {
  final TransformationController _transformController = TransformationController();
  bool _zoomed = false;

  @override
  void initState() {
    super.initState();
  }

  @override
  void didUpdateWidget(ImageViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.handle.displayUrl != widget.handle.displayUrl) {
      _zoomed = false;
      _transformController.value = Matrix4.identity();
    }
  }

  @override
  void dispose() {
    _transformController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: GestureDetector(
        onDoubleTap: _handleDoubleTap,
        child: InteractiveViewer(
          transformationController: _transformController,
          minScale: 1.0,
          maxScale: 4.0,
          boundaryMargin: const EdgeInsets.all(20),
          child: Image(
            image: CachedNetworkImageProvider(widget.handle.displayUrl),
            fit: BoxFit.contain,
            gaplessPlayback: true,
            errorBuilder: (context, error, stackTrace) {
              final errorType = _classifyError(error);
              WidgetsBinding.instance.addPostFrameCallback((_) {
                widget.onError?.call(errorType);
              });
              return const SizedBox.shrink();
            },
            frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
              return child;
            },
          ),
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
