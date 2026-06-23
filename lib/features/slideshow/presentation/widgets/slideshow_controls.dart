import 'package:flutter/material.dart';

class SlideshowControls extends StatelessWidget {
  final bool isPlaying;
  final bool isMuted;
  final bool isVideo;
  final VoidCallback onPrevious;
  final VoidCallback onPlayPause;
  final VoidCallback onNext;
  final VoidCallback onToggleMute;
  final VoidCallback onToggleFullscreen;
  final VoidCallback onDownload;
  final VoidCallback onShare;
  final VoidCallback onOpenReddit;

  const SlideshowControls({
    super.key,
    required this.isPlaying,
    required this.isMuted,
    required this.isVideo,
    required this.onPrevious,
    required this.onPlayPause,
    required this.onNext,
    required this.onToggleMute,
    required this.onToggleFullscreen,
    required this.onDownload,
    required this.onShare,
    required this.onOpenReddit,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final iconColor = Colors.white;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Navigation row
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _iconButton(Icons.skip_previous, 'Previous', onPrevious, iconColor),
            const SizedBox(width: 24),
            Container(
              decoration: BoxDecoration(
                color: theme.colorScheme.primary,
                shape: BoxShape.circle,
              ),
              child: _iconButton(
                isPlaying ? Icons.pause : Icons.play_arrow,
                isPlaying ? 'Pause' : 'Play',
                onPlayPause,
                Colors.white,
                size: 32,
              ),
            ),
            const SizedBox(width: 24),
            _iconButton(Icons.skip_next, 'Next', onNext, iconColor),
          ],
        ),
        const SizedBox(height: 16),
        // Actions row
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _iconButton(Icons.fullscreen, 'Fullscreen', onToggleFullscreen, iconColor),
            const SizedBox(width: 16),
            if (isVideo)
              _iconButton(
                isMuted ? Icons.volume_off : Icons.volume_up,
                isMuted ? 'Unmute' : 'Mute',
                onToggleMute,
                iconColor,
              ),
            if (isVideo) const SizedBox(width: 16),
            _iconButton(Icons.download, 'Save', onDownload, iconColor),
            const SizedBox(width: 16),
            _iconButton(Icons.share, 'Share', onShare, iconColor),
            const SizedBox(width: 16),
            _iconButton(Icons.open_in_new, 'Open on Reddit', onOpenReddit, iconColor),
          ],
        ),
      ],
    );
  }

  Widget _iconButton(IconData icon, String tooltip, VoidCallback onPressed, Color color, {double size = 24}) {
    return IconButton(
      icon: Icon(icon, color: color),
      iconSize: size,
      tooltip: tooltip,
      onPressed: onPressed,
      splashRadius: 20,
    );
  }
}
