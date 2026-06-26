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
  int _buildFrame = 0;
  int _frameCount = 0;

  @override
  void didUpdateWidget(ImageViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl) {
      _zoomed = false;
      _transformController.value = Matrix4.identity();
      _buildFrame = 0;
    }
  }

  @override
  void dispose() {
    _transformController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_buildFrame == 0) _buildFrame = ++_frameCount;
    final currentFrame = _frameCount;
    return CachedNetworkImage(
      imageUrl: widget.imageUrl,
      imageBuilder: (context, imageProvider) {
        final framesSinceBuild = currentFrame - _buildFrame + 1;
        final isCacheHit = framesSinceBuild <= 1;
        debugPrint('[IMAGE_READY] url=${widget.imageUrl} framesSinceBuild=$framesSinceBuild');
        debugPrint('[CACHE_HIT] url=${widget.imageUrl} hit=$isCacheHit frames=$framesSinceBuild');
        WidgetsBinding.instance.addPostFrameCallback((_) {
          debugPrint('[IMAGE_VISIBLE] url=${widget.imageUrl}');
        });
        debugPrint('[SLIDE_DONE] url=${widget.imageUrl} source=FlutterImageCache');
        return GestureDetector(
          onDoubleTap: _handleDoubleTap,
          child: InteractiveViewer(
            transformationController: _transformController,
            minScale: 1.0,
            maxScale: 4.0,
            boundaryMargin: const EdgeInsets.all(20),
            child: Image(
              image: imageProvider,
              fit: BoxFit.contain,
              gaplessPlayback: true,
            ),
          ),
        );
      },
      placeholder: (context, url) {
        debugPrint('[IMG_LOADING] url=$url source=placeholder');
        return Container(
          color: Colors.black,
          alignment: Alignment.center,
          child: const CircularProgressIndicator(strokeWidth: 3),
        );
      },
      errorWidget: (context, url, error) {
        final errorType = _classifyError(error);
        debugPrint('[IMG_FAILED] url=$url errorType=${errorType.label}');
        WidgetsBinding.instance.addPostFrameCallback((_) {
          widget.onError?.call(errorType);
        });
        return const SizedBox.shrink();
      },
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
