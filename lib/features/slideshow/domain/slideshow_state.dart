import '../../feed/domain/media_asset.dart';
import 'slideshow_source.dart';

class SlideshowState {
  final List<MediaAsset> items;
  final int currentIndex;
  final bool isPlaying;
  final bool isMuted;
  final bool isFullscreen;
  final bool overlayVisible;
  final SlideshowSource source;
  final bool isLoading;
  final bool isLoadingMore;
  final bool hasMorePages;
  final String? paginationCursor;
  final int gallerySubIndex;

  const SlideshowState({
    this.items = const [],
    this.currentIndex = 0,
    this.isPlaying = true,
    this.isMuted = true,
    this.isFullscreen = false,
    this.overlayVisible = true,
    required this.source,
    this.isLoading = true,
    this.isLoadingMore = false,
    this.hasMorePages = true,
    this.paginationCursor,
    this.gallerySubIndex = 0,
  });

  SlideshowState copyWith({
    List<MediaAsset>? items,
    int? currentIndex,
    bool? isPlaying,
    bool? isMuted,
    bool? isFullscreen,
    bool? overlayVisible,
    SlideshowSource? source,
    bool? isLoading,
    bool? isLoadingMore,
    bool? hasMorePages,
    String? paginationCursor,
    int? gallerySubIndex,
  }) {
    return SlideshowState(
      items: items ?? this.items,
      currentIndex: currentIndex ?? this.currentIndex,
      isPlaying: isPlaying ?? this.isPlaying,
      isMuted: isMuted ?? this.isMuted,
      isFullscreen: isFullscreen ?? this.isFullscreen,
      overlayVisible: overlayVisible ?? this.overlayVisible,
      source: source ?? this.source,
      isLoading: isLoading ?? this.isLoading,
      isLoadingMore: isLoadingMore ?? this.isLoadingMore,
      hasMorePages: hasMorePages ?? this.hasMorePages,
      paginationCursor: paginationCursor ?? this.paginationCursor,
      gallerySubIndex: gallerySubIndex ?? this.gallerySubIndex,
    );
  }
}
