enum MediaTaskType { image, video }

class SchedulerTask {
  final String assetId;
  final String url;
  final int index;
  final MediaTaskType mediaType;
  final int? galleryPosition;
  final int? galleryLength;
  final int generation;

  const SchedulerTask({
    required this.assetId,
    required this.url,
    required this.index,
    required this.mediaType,
    this.galleryPosition,
    this.galleryLength,
    required this.generation,
  });

  @override
  bool operator ==(Object other) =>
      other is SchedulerTask &&
      url == other.url &&
      generation == other.generation;

  @override
  int get hashCode => Object.hash(url, generation);
}
