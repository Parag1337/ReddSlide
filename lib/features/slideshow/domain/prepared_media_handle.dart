import 'package:video_player/video_player.dart';
import '../../feed/domain/media_asset.dart';
import '../../../core/display_quality/image_decode_policy.dart';

enum MediaState {
  notRequested,
  queued,
  preparing,
  ready,
  failed,
  evicted,
}

class PreparedMediaHandle {
  final MediaAsset asset;
  final MediaState state;
  final VideoPlayerController? controller;
  final bool preparationFailed;
  final DecodeSize? decodeSize;

  const PreparedMediaHandle({
    required this.asset,
    required this.state,
    this.controller,
    this.preparationFailed = false,
    this.decodeSize,
  });

  bool get ready => state == MediaState.ready;

  String get displayUrl => asset.mediaUrl;

  String get displayThumbnailUrl => asset.thumbnailUrl ?? asset.mediaUrl;

  bool get isVideo => asset.isVideo;
}
