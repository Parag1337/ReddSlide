import 'package:flutter/material.dart';
import '../../../../core/debug/trace.dart';
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
  final void Function(String url)? onVideoCompleted;

  const MediaViewer({
    super.key,
    required this.handle,
    required this.isMuted,
    this.onMediaError,
    this.onImageDecoded,
    this.onVideoFirstFrame,
    this.onVideoCompleted,
  });

  @override
  Widget build(BuildContext context) {
    Trace.t('MV.build', [
      'assetId', handle.asset.id,
      'isVideo', handle.isVideo,
      'hasVideoUrl', handle.asset.videoUrl != null,
      'handleState', handle.state.name,
      'ctrl', '${handle.controller?.hashCode}',
      'init', '${handle.controller?.value.isInitialized}',
    ]);
    final widget = handle.isVideo && handle.asset.videoUrl != null
        ? VideoViewer(
            handle: handle,
            muted: isMuted,
            onError: onMediaError,
            onFirstFrameRendered: onVideoFirstFrame,
            onVideoCompleted: onVideoCompleted,
          )
        : ImageViewer(
            handle: handle,
            onError: onMediaError,
            onFirstFrameDecoded: onImageDecoded,
          );

    return widget;
  }
}
