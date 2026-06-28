import 'package:flutter/material.dart';
import '../../../../core/media/media_error.dart';
import '../../../slideshow/domain/prepared_media_handle.dart';
import 'image_viewer.dart';
import 'video_viewer.dart';

class MediaViewer extends StatelessWidget {
  final PreparedMediaHandle handle;
  final bool isMuted;
  final void Function(MediaErrorType errorType)? onMediaError;
  final void Function(String url, {required bool wasCached})? onImageDecoded;
  final void Function(String url)? onVideoFirstFrame;

  const MediaViewer({
    super.key,
    required this.handle,
    required this.isMuted,
    this.onMediaError,
    this.onImageDecoded,
    this.onVideoFirstFrame,
  });

  @override
  Widget build(BuildContext context) {
    final widget = handle.isVideo && handle.asset.videoUrl != null
        ? VideoViewer(
            handle: handle,
            muted: isMuted,
            onError: onMediaError,
            onFirstFrameRendered: onVideoFirstFrame,
          )
        : ImageViewer(
            handle: handle,
            onError: onMediaError,
            onFirstFrameDecoded: onImageDecoded,
          );

    return widget;
  }
}
