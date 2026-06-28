import '../../feed/domain/media_asset.dart';

class SlideshowState {
  final List<MediaAsset> items;
  final int currentIndex;
  final bool isPlaying;
  final bool isMuted;
  final bool isFullscreen;
  final bool overlayVisible;
  final bool isLoading;
  final bool isLoadingMore;
  final bool hasMorePages;
  final int gallerySubIndex;
  final int preparationRevision;

  const SlideshowState({
    this.items = const [],
    this.currentIndex = 0,
    this.isPlaying = true,
    this.isMuted = true,
    this.isFullscreen = false,
    this.overlayVisible = true,
    this.isLoading = true,
    this.isLoadingMore = false,
    this.hasMorePages = true,
    this.gallerySubIndex = 0,
    this.preparationRevision = 0,
  });

  SlideshowState copyWith({
    List<MediaAsset>? items,
    int? currentIndex,
    bool? isPlaying,
    bool? isMuted,
    bool? isFullscreen,
    bool? overlayVisible,
    bool? isLoading,
    bool? isLoadingMore,
    bool? hasMorePages,
    int? gallerySubIndex,
    int? preparationRevision,
  }) {
    return SlideshowState(
      items: items ?? this.items,
      currentIndex: currentIndex ?? this.currentIndex,
      isPlaying: isPlaying ?? this.isPlaying,
      isMuted: isMuted ?? this.isMuted,
      isFullscreen: isFullscreen ?? this.isFullscreen,
      overlayVisible: overlayVisible ?? this.overlayVisible,
      isLoading: isLoading ?? this.isLoading,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      hasMorePages: hasMorePages ?? this.hasMorePages,
      gallerySubIndex: gallerySubIndex ?? this.gallerySubIndex,
      preparationRevision: preparationRevision ?? this.preparationRevision,
    );
  }
}
