import '../../feed/domain/media_asset.dart';
import 'scheduler_task.dart';

class TaskPlanner {
  const TaskPlanner();

  List<SchedulerTask> plan({
    required List<MediaAsset> items,
    required int currentIndex,
    required int horizon,
    required int needCount,
    required int generation,
    int galleryIndex = 0,
  }) {
    if (items.isEmpty || currentIndex >= items.length || needCount <= 0 || horizon < 0) {
      return [];
    }

    final result = <SchedulerTask>[];
    final seenUrls = <String>{};

    final end = (currentIndex + horizon + 1).clamp(0, items.length);

    final currentAsset = items[currentIndex];
    final currentIsGallery = currentAsset.isGallery &&
        currentAsset.galleryUrls != null &&
        currentAsset.galleryUrls!.isNotEmpty;
    final currentGalleryLength = currentIsGallery ? currentAsset.galleryUrls!.length : 0;

    if (currentIsGallery && galleryIndex < currentGalleryLength - 1) {
      for (int g = galleryIndex + 1; g < currentGalleryLength; g++) {
        if (result.length >= needCount) return result;
        final url = currentAsset.galleryUrls![g];
        if (seenUrls.contains(url)) continue;
        seenUrls.add(url);
        result.add(SchedulerTask(
          assetId: currentAsset.id,
          url: url,
          index: currentIndex,
          mediaType: MediaTaskType.image,
          galleryPosition: g,
          galleryLength: currentGalleryLength,
          generation: generation,
        ));
      }
    }

    for (int i = currentIndex; i < end; i++) {
      if (result.length >= needCount) return result;
      final asset = items[i];

      if (i == currentIndex && currentIsGallery) {
        continue;
      }

      if (asset.isGallery && asset.galleryUrls != null && asset.galleryUrls!.isNotEmpty) {
        for (int g = 0; g < asset.galleryUrls!.length; g++) {
          if (result.length >= needCount) return result;
          final url = asset.galleryUrls![g];
          if (seenUrls.contains(url)) continue;
          seenUrls.add(url);
          result.add(SchedulerTask(
            assetId: asset.id,
            url: url,
            index: i,
            mediaType: MediaTaskType.image,
            galleryPosition: g,
            galleryLength: asset.galleryUrls!.length,
            generation: generation,
          ));
        }
      } else if (asset.isVideo) {
        if (asset.thumbnailUrl != null) {
          if (!seenUrls.contains(asset.thumbnailUrl!)) {
            if (result.length >= needCount) return result;
            seenUrls.add(asset.thumbnailUrl!);
            result.add(SchedulerTask(
              assetId: asset.id,
              url: asset.thumbnailUrl!,
              index: i,
              mediaType: MediaTaskType.image,
              generation: generation,
            ));
          }
        }
        if (asset.videoUrl != null) {
          if (!seenUrls.contains(asset.videoUrl!)) {
            if (result.length >= needCount) return result;
            seenUrls.add(asset.videoUrl!);
            result.add(SchedulerTask(
              assetId: asset.id,
              url: asset.videoUrl!,
              index: i,
              mediaType: MediaTaskType.video,
              generation: generation,
            ));
          }
        }
      } else {
        if (!seenUrls.contains(asset.mediaUrl)) {
          seenUrls.add(asset.mediaUrl);
          result.add(SchedulerTask(
            assetId: asset.id,
            url: asset.mediaUrl,
            index: i,
            mediaType: MediaTaskType.image,
            generation: generation,
          ));
        }
      }
    }

    return result;
  }
}
