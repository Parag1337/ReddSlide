import 'package:flutter/material.dart';
import '../../../feed/domain/media_asset.dart';
import '../../domain/slideshow_source.dart';
import 'queue_indicator.dart';
import 'slideshow_controls.dart';

class SlideshowOverlay extends StatelessWidget {
  final MediaAsset? currentAsset;
  final int currentIndex;
  final int totalItems;
  final int galleryIndex;
  final int galleryLength;
  final bool isPlaying;
  final bool isMuted;
  final bool isFullscreen;
  final bool visible;
  final SlideshowSource source;
  final VoidCallback onBack;
  final VoidCallback onPrevious;
  final VoidCallback onPlayPause;
  final VoidCallback onNext;
  final VoidCallback onToggleMute;
  final VoidCallback onToggleFullscreen;
  final VoidCallback onDownload;
  final VoidCallback onShare;
  final VoidCallback onOpenReddit;
  final void Function(int index) onChipTap;

  const SlideshowOverlay({
    super.key,
    this.currentAsset,
    required this.currentIndex,
    required this.totalItems,
    this.galleryIndex = 0,
    this.galleryLength = 0,
    required this.isPlaying,
    required this.isMuted,
    required this.isFullscreen,
    required this.visible,
    required this.source,
    required this.onBack,
    required this.onPrevious,
    required this.onPlayPause,
    required this.onNext,
    required this.onToggleMute,
    required this.onToggleFullscreen,
    required this.onDownload,
    required this.onShare,
    required this.onOpenReddit,
    required this.onChipTap,
  });

  @override
  Widget build(BuildContext context) {
    if (!visible) return const SizedBox.shrink();
    final theme = Theme.of(context);

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withValues(alpha: 0.6),
            Colors.transparent,
            Colors.black.withValues(alpha: 0.6),
          ],
          stops: const [0.0, 0.3, 0.7],
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            _buildTopBar(theme),
            const Spacer(),
            QueueIndicator(
              totalItems: totalItems,
              currentIndex: currentIndex,
              onChipTap: onChipTap,
            ),
            const SizedBox(height: 8),
            SlideshowControls(
              isPlaying: isPlaying,
              isMuted: isMuted,
              isVideo: currentAsset?.isVideo ?? false,
              onPrevious: onPrevious,
              onPlayPause: onPlayPause,
              onNext: onNext,
              onToggleMute: onToggleMute,
              onToggleFullscreen: onToggleFullscreen,
              onDownload: onDownload,
              onShare: onShare,
              onOpenReddit: onOpenReddit,
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            tooltip: 'Back',
            onPressed: onBack,
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _buildTitle(),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 2),
                Row(
                  children: [
                    Text(
                      currentAsset != null ? 'r/${currentAsset!.subreddit}' : '',
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 12),
                    ),
                    const Text(' • ', style: TextStyle(color: Colors.white54, fontSize: 12)),
                    Text(
                      currentAsset != null ? 'u/${currentAsset!.author}' : '',
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.7), fontSize: 12),
                    ),
                    if (currentAsset?.nsfw ?? false) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.error,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text('NSFW', style: TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w700)),
                      ),
                    ],
                  ],
                ),
                _buildSourceLabel(),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.more_vert, color: Colors.white),
            tooltip: 'More',
            onPressed: () {},
          ),
        ],
      ),
    );
  }

  String _buildTitle() {
    if (currentAsset == null) return '';
    if (galleryLength > 1) {
      return '(${galleryIndex + 1}/$galleryLength) ${currentAsset!.title}';
    }
    return currentAsset!.title;
  }

  Widget _buildSourceLabel() {
    return switch (source) {
      SearchSource(:final query) => Text(
          'Search: "$query"',
          style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 10),
        ),
      MultiSubredditSource(:final subreddits) => Text(
          '${subreddits.length} subreddits',
          style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 10),
        ),
      GroupSource(:final groupName) => Text(
          'Group: $groupName',
          style: TextStyle(color: Colors.white.withValues(alpha: 0.5), fontSize: 10),
        ),
      _ => const SizedBox.shrink(),
    };
  }
}
