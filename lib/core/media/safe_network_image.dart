import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../display_quality/image_decode_policy.dart';

class SafeNetworkImage extends StatelessWidget {
  final String url;
  final BoxFit fit;
  final Widget placeholder;
  final DecodeSize? decodeSize;

  const SafeNetworkImage({
    super.key,
    required this.url,
    this.fit = BoxFit.contain,
    this.placeholder = const SizedBox.shrink(),
    this.decodeSize,
  });

  @override
  Widget build(BuildContext context) {
    final pixelRatio = MediaQuery.of(context).devicePixelRatio;
    final mediaSize = MediaQuery.of(context).size;
    final w = decodeSize?.width ?? (mediaSize.width * pixelRatio).ceil();
    return Image(
      image: ResizeImage.resizeIfNeeded(
        w,
        null,
        CachedNetworkImageProvider(url),
      ),
      fit: fit,
      gaplessPlayback: true,
      errorBuilder: (context, error, stackTrace) => placeholder,
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        if (frame == null && !wasSynchronouslyLoaded) {
          return placeholder;
        }
        return child;
      },
    );
  }
}
