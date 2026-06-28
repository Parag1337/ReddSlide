import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../../core/constants/theme_constants.dart';

class SubredditCard extends StatelessWidget {
  final String name;
  final String? coverUrl;
  final bool enabled;
  final bool isSelected;
  final bool selectionMode;
  final VoidCallback onTap;
  final VoidCallback onLongPress;

  const SubredditCard({
    super.key,
    required this.name,
    this.coverUrl,
    this.enabled = true,
    this.isSelected = false,
    this.selectionMode = false,
    required this.onTap,
    required this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final opacity = enabled ? 1.0 : 0.4;

    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: RepaintBoundary(
        child: AnimatedOpacity(
          opacity: opacity,
          duration: AppDuration.normal,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.card),
              border: isSelected
                  ? Border.all(color: theme.colorScheme.primary, width: 2)
                  : Border.all(color: theme.colorScheme.surfaceContainerHighest, width: 1),
            ),
            clipBehavior: Clip.antiAlias,
            child: AspectRatio(
              aspectRatio: 3 / 4,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (coverUrl != null)
                    CachedNetworkImage(
                      imageUrl: coverUrl!,
                      memCacheWidth: (MediaQuery.of(context).size.width * MediaQuery.of(context).devicePixelRatio).ceil(),
                      fit: BoxFit.cover,
                      placeholder: (_, _) => _buildPlaceholder(theme),
                      errorWidget: (_, _, _) => _buildPlaceholder(theme),
                    )
                  else
                    _buildPlaceholder(theme),
                  Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          Colors.black.withValues(alpha: 0.87),
                        ],
                        stops: const [0.4, 1.0],
                      ),
                    ),
                  ),
                  Positioned(
                    left: 12,
                    right: 12,
                    bottom: 12,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'r/$name',
                          style: theme.textTheme.titleMedium?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (!enabled)
                          Text(
                            'Disabled',
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: Colors.white70,
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (selectionMode)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isSelected ? theme.colorScheme.primary : Colors.black45,
                          border: Border.all(color: Colors.white, width: 1.5),
                        ),
                        child: isSelected
                            ? const Icon(Icons.check, size: 18, color: Colors.white)
                            : const SizedBox(width: 18, height: 18),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPlaceholder(ThemeData theme) {
    return Container(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Center(
        child: Text(
          name[0].toUpperCase(),
          style: theme.textTheme.displayLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
