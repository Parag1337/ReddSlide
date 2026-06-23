import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../../../../core/media/media_error.dart';
import '../../../../core/media/image_loader.dart';

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
  bool _loading = true;
  List<int>? _imageBytes;

  @override
  void initState() {
    super.initState();
    _loadImage();
  }

  @override
  void didUpdateWidget(ImageViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl) {
      _reset();
      _loadImage();
    }
  }

  void _reset() {
    _loading = true;
    _imageBytes = null;
  }

  Future<void> _loadImage() async {
    final result = await loadImageWithRetry(widget.imageUrl);
    if (!mounted) return;

    if (result.isSuccess) {
      setState(() {
        _imageBytes = result.bytes;
        _loading = false;
      });
    } else {
      final errorType = result.errorType ?? MediaErrorType.unknown;
      setState(() => _loading = false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        widget.onError?.call(errorType);
      });
    }
  }

  @override
  void dispose() {
    _transformController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }

    if (_imageBytes != null) {
      return GestureDetector(
        onDoubleTap: _handleDoubleTap,
        child: InteractiveViewer(
          transformationController: _transformController,
          minScale: 1.0,
          maxScale: 4.0,
          boundaryMargin: const EdgeInsets.all(20),
          child: Image.memory(
            Uint8List.fromList(_imageBytes!),
            fit: BoxFit.contain,
            gaplessPlayback: true,
          ),
        ),
      );
    }

    return const SizedBox.shrink();
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
}
