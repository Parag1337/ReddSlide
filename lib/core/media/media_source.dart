import '../../features/feed/domain/media_asset.dart';

class MediaPage {
  final List<MediaAsset> items;
  final String? cursor;
  final bool hasMore;

  const MediaPage({
    required this.items,
    this.cursor,
    required this.hasMore,
  });
}

abstract class MediaSource {
  Future<MediaPage> loadNext();

  bool get hasMore;

  Future<void> dispose();
}
