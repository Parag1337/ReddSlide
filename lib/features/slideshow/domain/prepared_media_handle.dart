import 'package:video_player/video_player.dart';
import '../../feed/domain/media_asset.dart';

class PreparedMediaHandle {
  final MediaAsset asset;
  final bool ready;
  final VideoPlayerController? controller;
  final bool preparationFailed;

  const PreparedMediaHandle({
    required this.asset,
    required this.ready,
    this.controller,
    this.preparationFailed = false,
  });

  /// The URL to render. For galleries, [MediaPreparationEngine.prepare] resolves
  /// the specific gallery index into [asset.mediaUrl], so this always returns
  /// [asset.mediaUrl] regardless of asset type.
  String get displayUrl => asset.mediaUrl;

  String get displayThumbnailUrl => asset.thumbnailUrl ?? asset.mediaUrl;

  bool get isVideo => asset.isVideo;
}
