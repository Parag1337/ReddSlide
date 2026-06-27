import 'package:flutter/material.dart';
import '../../../../core/media/media_error.dart';
import '../../../feed/domain/media_asset.dart';
import 'image_viewer.dart';
import 'video_viewer.dart';

class MediaViewer extends StatelessWidget {
  final MediaAsset asset;
  final bool isMuted;
  final int galleryIndex;
  final void Function(MediaErrorType errorType)? onMediaError;

  const MediaViewer({
    super.key,
    required this.asset,
    required this.isMuted,
    this.galleryIndex = 0,
    this.onMediaError,
  });

  @override
  Widget build(BuildContext context) {
    final buildSw = Stopwatch()..start();

    final widget = asset.isVideo && asset.videoUrl != null
        ? VideoViewer(
            videoUrl: asset.videoUrl!,
            thumbnailUrl: asset.thumbnailUrl ?? asset.mediaUrl,
            muted: isMuted,
            onError: onMediaError,
          )
        : asset.isGallery && asset.galleryUrls != null && asset.galleryUrls!.isNotEmpty
            ? ImageViewer(
                imageUrl: asset.galleryUrls![galleryIndex.clamp(0, asset.galleryUrls!.length - 1)],
                onError: onMediaError,
              )
            : ImageViewer(imageUrl: asset.mediaUrl, onError: onMediaError);

    final buildMs = buildSw.elapsedMilliseconds;
    if (buildMs > 1) {
      debugPrint('[RENDER_TIMELINE] MediaViewer.build '
          'asset=${asset.id} type=${asset.isVideo ? "video" : "image"} buildMs=$buildMs');
    }

    return widget;
  }
}
