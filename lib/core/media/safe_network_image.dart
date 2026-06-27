import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

class SafeNetworkImage extends StatelessWidget {
  final String url;
  final BoxFit fit;
  final Widget placeholder;

  const SafeNetworkImage({
    super.key,
    required this.url,
    this.fit = BoxFit.contain,
    this.placeholder = const SizedBox.shrink(),
  });

  @override
  Widget build(BuildContext context) {
    return Image(
      image: CachedNetworkImageProvider(url),
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
