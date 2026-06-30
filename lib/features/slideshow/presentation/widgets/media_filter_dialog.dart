import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../features/feed/domain/media_asset.dart';
import '../../../../features/settings/providers/settings_provider.dart';
import '../../../slideshow/domain/media_filter.dart';
import '../../../slideshow/domain/slideshow_source.dart';

class MediaFilterResult {
  final MediaFilter filter;
  final bool cancelled;
  const MediaFilterResult({required this.filter, this.cancelled = false});
}

Future<MediaFilterResult?> showMediaFilterDialog({
  required BuildContext context,
  required WidgetRef ref,
  required List<MediaAsset> items,
  required SlideshowSource Function(MediaFilter filter) buildSource,
}) async {
  final settings = ref.read(settingsProvider).valueOrNull;
  final currentFilter = settings?.mediaFilter ?? MediaFilter.all;

  final imagesCount = items.where((a) => a.isImage).length;
  final videosCount = items.where((a) => a.isVideo).length;
  final galleriesCount = items.where((a) => a.isGallery).length;

  final result = await showDialog<MediaFilter>(
    context: context,
    builder: (context) {
      return SimpleDialog(
        title: const Text('Media Filter'),
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Results', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 4),
                Text('Images: $imagesCount'),
                Text('Videos: $videosCount'),
                Text('Galleries: $galleriesCount'),
                const Divider(),
                Text('Current Filter: ${_filterLabel(currentFilter)}'),
                const SizedBox(height: 8),
              ],
            ),
          ),
          ...MediaFilter.values.map((filter) {
            final count = switch (filter) {
              MediaFilter.all => items.length,
              MediaFilter.images => imagesCount + galleriesCount,
              MediaFilter.videos => videosCount + galleriesCount,
            };
            return RadioListTile<MediaFilter>(
              title: Text('${_filterLabel(filter)}  ($count slides)'),
              value: filter,
              groupValue: currentFilter,
              onChanged: (value) => Navigator.pop(context, value),
            );
          }),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
            child: TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
          ),
        ],
      );
    },
  );

  if (result == null) {
    return MediaFilterResult(filter: currentFilter, cancelled: true);
  }

  if (result != currentFilter) {
    await ref.read(settingsProvider.notifier).setMediaFilter(result);
  }

  return MediaFilterResult(filter: result);
}

String _filterLabel(MediaFilter filter) {
  return switch (filter) {
    MediaFilter.all => 'All',
    MediaFilter.images => 'Images',
    MediaFilter.videos => 'Videos',
  };
}
