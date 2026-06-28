import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:shimmer/shimmer.dart';
import '../../../../core/constants/theme_constants.dart';
import '../../domain/media_asset.dart';

class MediaCard extends StatelessWidget {
  final MediaAsset asset;
  final bool nsfwEnabled;
  final VoidCallback onTap;

  const MediaCard({
    super.key,
    required this.asset,
    required this.nsfwEnabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final showNsfw = asset.nsfw && nsfwEnabled;

    return GestureDetector(
      onTap: onTap,
      child: RepaintBoundary(
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadius.card),
            border: Border.all(color: theme.colorScheme.surfaceContainerHighest, width: 1),
          ),
          clipBehavior: Clip.antiAlias,
          child: AspectRatio(
            aspectRatio: 1,
            child: Stack(
              fit: StackFit.expand,
              children: [
                _buildImage(context, theme),
                if (asset.isVideo)
                  Positioned(
                    bottom: 8,
                    left: 8,
                    child: _buildBadge(theme, Icons.play_circle_fill, 'Video'),
                  ),
                if (asset.isGallery)
                  Positioned(
                    bottom: 8,
                    left: asset.isVideo ? 64 : 8,
                    child: _buildBadge(theme, Icons.collections, 'Gallery'),
                  ),
                if (showNsfw)
                  Positioned(
                    top: 8,
                    right: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.error,
                        borderRadius: BorderRadius.circular(AppRadius.indicator),
                      ),
                      child: Text(
                        'NSFW',
                        style: TextStyle(
                          color: theme.colorScheme.onError,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildImage(BuildContext context, ThemeData theme) {
    final pixelRatio = MediaQuery.of(context).devicePixelRatio;
    final columns = MediaQuery.of(context).size.width > 600 ? 3 : 2;
    final thumbWidth = (MediaQuery.of(context).size.width / columns * pixelRatio).ceil();
    final url = asset.thumbnailUrl ?? asset.mediaUrl;
    return CachedNetworkImage(
      imageUrl: url,
      memCacheWidth: thumbWidth,
      fit: BoxFit.cover,
      placeholder: (_, _) => _shimmerPlaceholder(theme),
      errorWidget: (_, _, _) => _errorPlaceholder(theme),
    );
  }

  Widget _shimmerPlaceholder(ThemeData theme) {
    return Shimmer.fromColors(
      baseColor: theme.colorScheme.surfaceContainerHighest,
      highlightColor: theme.colorScheme.surfaceContainerLow,
      child: Container(color: theme.colorScheme.surfaceContainerHighest),
    );
  }

  Widget _errorPlaceholder(ThemeData theme) {
    return Container(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Icon(Icons.broken_image, color: theme.colorScheme.onSurfaceVariant),
    );
  }

  Widget _buildBadge(ThemeData theme, IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(AppRadius.indicator),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: Colors.white),
          const SizedBox(width: 3),
          Text(
            label,
            style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }
}
