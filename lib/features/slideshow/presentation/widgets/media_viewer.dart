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
    if (asset.isVideo && asset.videoUrl != null) {
      return VideoViewer(
        videoUrl: asset.videoUrl!,
        thumbnailUrl: asset.thumbnailUrl ?? asset.mediaUrl,
        muted: isMuted,
        onError: onMediaError,
      );
    }

    if (asset.isGallery && asset.galleryUrls != null && asset.galleryUrls!.isNotEmpty) {
      final url = asset.galleryUrls![galleryIndex.clamp(0, asset.galleryUrls!.length - 1)];
      return ImageViewer(imageUrl: url, onError: onMediaError);
    }

    return ImageViewer(imageUrl: asset.mediaUrl, onError: onMediaError);
  }
}
