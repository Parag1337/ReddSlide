import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../../core/constants/theme_constants.dart';
import '../../../feed/domain/media_asset.dart';

class SearchResultTile extends StatelessWidget {
  final MediaAsset asset;
  final VoidCallback onTap;

  const SearchResultTile({
    super.key,
    required this.asset,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scoreText = _formatScore(asset.score);

    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadius.chip),
        child: SizedBox(
          width: 60,
          height: 60,
          child: CachedNetworkImage(
            imageUrl: asset.thumbnailUrl ?? asset.mediaUrl,
            memCacheWidth: (60 * MediaQuery.of(context).devicePixelRatio).ceil(),
            fit: BoxFit.cover,
            placeholder: (_, _) => Container(color: theme.colorScheme.surfaceContainerHighest),
            errorWidget: (_, _, _) => Container(
              color: theme.colorScheme.surfaceContainerHighest,
              child: Icon(Icons.broken_image, color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ),
      ),
      title: Text(
        asset.title,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodyLarge,
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Row(
          children: [
            Text(
              'r/${asset.subreddit}',
              style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.primary),
            ),
            const Text(' • '),
            Text(
              'u/${asset.author}',
              style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (asset.isVideo)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Icon(Icons.play_circle_fill, size: 16, color: theme.colorScheme.primary),
            ),
          if (asset.isGallery)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Icon(Icons.collections, size: 16, color: theme.colorScheme.primary),
            ),
          Text(
            scoreText,
            style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  String _formatScore(int score) {
    if (score >= 1000000) return '${(score / 1000000).toStringAsFixed(1)}M';
    if (score >= 1000) return '${(score / 1000).toStringAsFixed(1)}K';
    return score.toString();
  }
}
