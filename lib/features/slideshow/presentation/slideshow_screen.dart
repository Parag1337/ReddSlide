import 'dart:io';
import 'dart:async' show unawaited;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:dio/dio.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:share_plus/share_plus.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../../../core/constants/app_constants.dart';
import '../../../core/constants/theme_constants.dart';
import '../../../core/extensions/context_extensions.dart';
import '../../../core/media/media_error.dart';
import '../../../shared/utils/url_sanitizer.dart';
import '../../../shared/widgets/empty_state_widget.dart';
import '../../feed/domain/media_asset.dart';
import '../../settings/domain/settings_model.dart';
import '../../settings/providers/settings_provider.dart';
import '../domain/slideshow_source.dart';
import '../domain/slideshow_state.dart';
import '../providers/slideshow_provider.dart';
import 'widgets/media_viewer.dart';
import 'widgets/slideshow_overlay.dart';

class SlideshowScreen extends ConsumerStatefulWidget {
  final SlideshowSource source;
  final int startIndex;

  const SlideshowScreen({super.key, required this.source, this.startIndex = 0});

  @override
  ConsumerState<SlideshowScreen> createState() => _SlideshowScreenState();
}

enum _PreloadPriority { urgent, high, medium, low, background }

class _PreloadTask {
  final String url;
  final _PreloadPriority priority;
  const _PreloadTask({required this.url, required this.priority});
}

class _SlideshowScreenState extends ConsumerState<SlideshowScreen> with WidgetsBindingObserver {
  late final PageController _pageController;
  int _lastPreloadIndex = -1;
  ProviderSubscription<int?>? _currentIndexSub;
  ProviderSubscription<AsyncValue<SettingsModel>>? _settingsSub;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: widget.startIndex);
    WidgetsBinding.instance.addObserver(this);
    _logSource();
    Future.microtask(() {
      final notifier = ref.read(slideshowProvider(widget.source).notifier);
      notifier.initialize();
      if (widget.startIndex > 0) {
        notifier.setStartIndex(widget.startIndex);
      }
      final settings = ref.read(settingsProvider).valueOrNull;
      if (settings != null) {
        notifier.setInterval(settings.slideshowIntervalSeconds);
      }
    });
    _currentIndexSub = ref.listenManual(
      slideshowProvider(widget.source).select((s) => s.currentIndex),
      (prev, next) {
        if (prev != null && next != null && prev != next) {
          if (_pageController.hasClients && _pageController.page?.round() != next) {
            _pageController.animateToPage(
              next,
              duration: AppDuration.normal,
              curve: Curves.easeInOut,
            );
          }
        }
      },
    );
    _settingsSub = ref.listenManual(
      settingsProvider,
      (prev, next) {
        final interval = next.valueOrNull?.slideshowIntervalSeconds;
        if (interval != null) {
          ref.read(slideshowProvider(widget.source).notifier).setInterval(interval);
        }
      },
    );
  }

  void _logSource() {
    final desc = switch (widget.source) {
      SubredditSource(:final subreddit) => 'SubredditSource(subreddit=$subreddit)',
      MultiSubredditSource(:final subreddits, :final sortMode) =>
        'MultiSubredditSource(subreddits=$subreddits, sort=$sortMode)',
      GlobalFeedSource() => 'GlobalFeedSource()',
      SearchSource(:final query) => 'SearchSource(query=$query)',
      GroupSource(:final groupName, :final subreddits) =>
        'GroupSource(group=$groupName, subreddits=$subreddits)',
    };
    debugPrint('[Slideshow] source=$desc');
  }

  void _logNextReadyFromUrl(String url) {
    try {
      final st = ref.read(slideshowProvider(widget.source));
      for (int i = 1; i <= 3 && st.currentIndex + i < st.items.length; i++) {
        final asset = st.items[st.currentIndex + i];
        final urls = _imageUrls(asset);
        if (urls.contains(url)) {
          final allCached = urls.every((u) => _preloadedUrls.contains(u));
          debugPrint('[NEXT_READY] index=${st.currentIndex + i} url=$url '
              'cached=$allCached');
          return;
        }
      }
    } catch (_) {}
  }

  void _logNextReadyStatus(List<MediaAsset> items, int currentIndex) {
    for (int i = 1; i <= 5 && currentIndex + i < items.length; i++) {
      final asset = items[currentIndex + i];
      final urls = _imageUrls(asset);
      final allCached = urls.every((url) => _preloadedUrls.contains(url));
      if (allCached) {
        debugPrint('[NEXT_READY] index=${currentIndex + i} cached=true '
            'url=${urls.isNotEmpty ? urls.first : "none"}');
      }
    }
  }

  void _logAsset(MediaAsset asset) {
    debugPrint('[Slideshow] asset id=${asset.id} title="${asset.title}" '
        'subreddit=${asset.subreddit} '
        'media_url=${asset.mediaUrl} '
        'is_video=${asset.isVideo} '
        'is_gallery=${asset.isGallery}');
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pageController.dispose();
    _currentIndexSub?.close();
    _settingsSub?.close();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _saveSession();
    }
  }

  void _enqueueUrl(String url, _PreloadPriority priority) {
    if (_preloadedUrls.contains(url)) return;
    if (_activeUrls.contains(url)) return;
    if (_queuedUrls.contains(url)) return;
    _queuedUrls.add(url);
    final task = _PreloadTask(url: url, priority: priority);
    int insertAt = _preloadQueue.length;
    for (int i = 0; i < _preloadQueue.length; i++) {
      if (_preloadQueue[i].priority.index > priority.index) {
        insertAt = i;
        break;
      }
    }
    _preloadQueue.insert(insertAt, task);
  }

  void _processQueue() {
    while (_inFlightPreloads < _maxConcurrentPreloads && _preloadQueue.isNotEmpty) {
      final task = _preloadQueue.removeAt(0);
      _queuedUrls.remove(task.url);
      _activeUrls.add(task.url);
      _inFlightPreloads++;
      unawaited(_executePreload(task.url));
    }
    debugPrint('[PRELOAD_STATS] queued=${_queuedUrls.length} '
        'active=$_inFlightPreloads completed=${_preloadedUrls.length}');
  }

  void _logImageCacheStats() {
    final cache = PaintingBinding.instance.imageCache;
    debugPrint('[IMAGE_CACHE] entries=${cache.currentSize} '
        'sizeKB=${cache.currentSizeBytes ~/ 1024}');
  }

  Future<void> _executePreload(String url) async {
    debugPrint('[PRELOAD_START] url=$url active=$_inFlightPreloads');
    final sw = Stopwatch()..start();
    try {
      await precacheImage(CachedNetworkImageProvider(url), context);
      _preloadedUrls.add(url);
      if (_preloadedUrls.length > AppConstants.maxCacheMemoryItems) {
        _preloadedUrls.clear();
      }
      debugPrint('[PRELOAD_DONE] url=$url duration=${sw.elapsedMilliseconds}ms '
          'active=${_inFlightPreloads - 1}');
      _logNextReadyFromUrl(url);
      _logImageCacheStats();
    } catch (e) {
      debugPrint('[PRELOAD_FAILED] url=$url duration=${sw.elapsedMilliseconds}ms error=$e');
    } finally {
      _activeUrls.remove(url);
      _inFlightPreloads--;
      _processQueue();
    }
  }

  Future<void> _saveSession() async {
    // Session saved to local storage for resume
  }

  static const int _maxConcurrentPreloads = 3;
  final Set<String> _preloadedUrls = {};
  final Set<String> _activeUrls = {};
  int _inFlightPreloads = 0;
  final List<_PreloadTask> _preloadQueue = [];
  final Set<String> _queuedUrls = {};

  List<String> _allAssetUrls(MediaAsset asset, {bool includeVideo = false}) {
    final urls = <String>[
      asset.mediaUrl,
      if (asset.thumbnailUrl != null) asset.thumbnailUrl!,
      if (asset.isGallery && asset.galleryUrls != null) ...asset.galleryUrls!,
      if (includeVideo && asset.videoUrl != null) asset.videoUrl!,
    ];
    return urls;
  }

  List<String> _imageUrls(MediaAsset asset) {
    if (asset.isGallery && asset.galleryUrls != null) {
      return [
        ...asset.galleryUrls!,
        if (asset.thumbnailUrl != null) asset.thumbnailUrl!,
      ];
    }
    return [
      asset.mediaUrl,
      if (asset.thumbnailUrl != null) asset.thumbnailUrl!,
    ];
  }

  void _preloadForIndex(List<MediaAsset> items, int currentIndex) {
    if (items.isEmpty) return;

    final remaining = items.length - currentIndex;
    debugPrint('[PRELOAD_TRIGGER] currentIndex=$currentIndex remaining=$remaining '
        'active=$_inFlightPreloads '
        'queued=${_preloadQueue.length} '
        'completed=${_preloadedUrls.length}');

    // Priority 1: current item + immediate next (urgent)
    final current = items[currentIndex];
    for (final url in _allAssetUrls(current, includeVideo: true)) {
      _enqueueUrl(url, _PreloadPriority.urgent);
    }
    if (currentIndex + 1 < items.length) {
      final asset = items[currentIndex + 1];
      for (final url in _imageUrls(asset)) {
        _enqueueUrl(url, _PreloadPriority.urgent);
      }
    }

    // Priority 2: currentIndex + 2 through +4 (high)
    int highCount = 0;
    for (int i = currentIndex + 2; i <= currentIndex + 4 && i < items.length; i++) {
      final asset = items[i];
      for (final url in _imageUrls(asset)) {
        _enqueueUrl(url, _PreloadPriority.high);
        highCount++;
      }
    }

    // Priority 3: currentIndex + 5 through +10 (medium)
    int medCount = 0;
    for (int i = currentIndex + 5; i <= currentIndex + 10 && i < items.length; i++) {
      final asset = items[i];
      for (final url in _imageUrls(asset)) {
        _enqueueUrl(url, _PreloadPriority.medium);
        medCount++;
      }
    }

    // Priority 4: everything else ahead (low)
    int lowCount = 0;
    final farEnd = currentIndex + AppConstants.tier1PreloadCount + AppConstants.tier2PreloadCount;
    for (int i = currentIndex + 11; i <= farEnd && i < items.length; i++) {
      final asset = items[i];
      for (final url in _imageUrls(asset)) {
        _enqueueUrl(url, _PreloadPriority.low);
        lowCount++;
      }
    }

    // Priority 5: history (background)
    int histCount = 0;
    final histStart = currentIndex - AppConstants.historyCount;
    for (int i = currentIndex - 1; i >= histStart && i >= 0; i--) {
      final asset = items[i];
      for (final url in _imageUrls(asset)) {
        _enqueueUrl(url, _PreloadPriority.background);
        histCount++;
      }
    }

    debugPrint('[PRELOAD_QUEUE] current=$currentIndex '
        'queued=${_preloadQueue.length} '
        'urgent=${
          (currentIndex + 1 < items.length ? _imageUrls(items[currentIndex + 1]).length : 0)
        } '
        'high=$highCount '
        'medium=$medCount '
        'low=$lowCount '
        'history=$histCount');

    _logNextReadyStatus(items, currentIndex);
    _processQueue();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(slideshowProvider(widget.source));
    final currentAsset = state.items.isNotEmpty && state.currentIndex < state.items.length
        ? state.items[state.currentIndex]
        : null;
    final currentGalleryLength = currentAsset != null && currentAsset.isGallery && currentAsset.galleryUrls != null
        ? currentAsset.galleryUrls!.length
        : 0;

    if (state.items.isNotEmpty && _lastPreloadIndex != state.currentIndex) {
      _lastPreloadIndex = state.currentIndex;
      _preloadForIndex(state.items, state.currentIndex);
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // Media content
          state.isLoading
              ? const Center(child: CircularProgressIndicator(color: Colors.white))
              : state.items.isEmpty
                  ? const Center(
                      child: EmptyStateWidget(
                        icon: Icons.image_not_supported,
                        title: 'No media yet',
                        subtitle: 'Backend is currently loading content for this subreddit.\nTry refreshing in a few moments.',
                      ),
                    )
                  : PageView.builder(
                  controller: _pageController,
                  itemCount: state.items.length,
                  scrollDirection: Axis.horizontal,
                  onPageChanged: (index) {
                    debugPrint('[Slideshow] onPageChanged index=$index');
                    ref.read(slideshowProvider(widget.source).notifier).jumpTo(index);
                  },
                  itemBuilder: (context, index) {
                    if (index >= state.items.length) return const SizedBox();
                    final asset = state.items[index];
                    if (index == state.currentIndex) {
                      _logAsset(asset);
                    }
                    return GestureDetector(
                      onTapUp: (details) {
                        final width = MediaQuery.of(context).size.width;
                        if (details.localPosition.dx < width * 0.3) {
                          ref.read(slideshowProvider(widget.source).notifier).galleryPrevious();
                        } else if (details.localPosition.dx > width * 0.7) {
                          ref.read(slideshowProvider(widget.source).notifier).galleryNext();
                        } else {
                          ref.read(slideshowProvider(widget.source).notifier).toggleOverlay();
                        }
                      },
                      child: MediaViewer(
                        key: ValueKey('${asset.id}_${state.gallerySubIndex}'),
                        asset: asset,
                        isMuted: state.isMuted,
                        galleryIndex: state.gallerySubIndex,
                        onMediaError: (errorType) => _onMediaError(errorType),
                      ),
                    );
                  },
                ),

          // Loading more indicator
          if (state.isLoadingMore)
            Positioned(
              top: 60,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                      const SizedBox(width: 8),
                      const Text('Loading more...', style: TextStyle(color: Colors.white, fontSize: 12)),
                    ],
                  ),
                ),
              ),
            ),

          // Overlay
          SlideshowOverlay(
            currentAsset: currentAsset,
            currentIndex: state.currentIndex,
            totalItems: state.items.length,
            galleryIndex: state.gallerySubIndex,
            galleryLength: currentGalleryLength,
            isPlaying: state.isPlaying,
            isMuted: state.isMuted,
            isFullscreen: state.isFullscreen,
            visible: state.overlayVisible,
            source: widget.source,
            onBack: () => context.pop(),
            onPrevious: () => ref.read(slideshowProvider(widget.source).notifier).galleryPrevious(),
            onPlayPause: () => ref.read(slideshowProvider(widget.source).notifier).togglePlay(),
            onNext: () => ref.read(slideshowProvider(widget.source).notifier).galleryNext(),
            onToggleMute: () => ref.read(slideshowProvider(widget.source).notifier).toggleMute(),
            onToggleFullscreen: () => _toggleFullscreen(state),
            onDownload: () => _downloadMedia(currentAsset),
            onShare: () => _shareMedia(currentAsset),
            onOpenReddit: () => _openOnReddit(currentAsset),
            onChipTap: (index) => ref.read(slideshowProvider(widget.source).notifier).jumpTo(index),
          ),
        ],
      ),
    );
  }

  void _onMediaError(MediaErrorType errorType) {
    final state = ref.read(slideshowProvider(widget.source));
    if (state.currentIndex >= state.items.length) return;

    final asset = state.items[state.currentIndex];
    final isGallery = asset.isGallery && asset.galleryUrls != null && asset.galleryUrls!.isNotEmpty;
    final isLastInGallery = isGallery && state.gallerySubIndex >= asset.galleryUrls!.length - 1;
    final failedUrl = isGallery && asset.galleryUrls != null && state.gallerySubIndex < asset.galleryUrls!.length
        ? asset.galleryUrls![state.gallerySubIndex]
        : asset.isVideo && asset.videoUrl != null
            ? asset.videoUrl!
            : asset.mediaUrl;

    logMediaError(
      redditId: asset.id,
      subreddit: asset.subreddit,
      url: failedUrl,
      errorType: errorType,
      isGallery: isGallery,
      isLastInGallery: isLastInGallery,
    );

    if (mounted) {
      ref.read(slideshowProvider(widget.source).notifier).galleryNext();
    }
  }

  void _toggleFullscreen(SlideshowState state) {
    ref.read(slideshowProvider(widget.source).notifier).toggleFullscreen();
    if (!state.isFullscreen) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.black,
        statusBarIconBrightness: Brightness.light,
      ));
    } else {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.black,
        statusBarIconBrightness: Brightness.light,
      ));
    }
  }

  void _downloadMedia(MediaAsset? asset) async {
    if (asset == null) return;
    try {
      final url = UrlSanitizer.sanitize(
        asset.isVideo ? (asset.videoUrl ?? asset.mediaUrl) : asset.mediaUrl,
      );
      final dir = await getTemporaryDirectory();
      final ext = asset.isVideo ? '.mp4' : '.jpg';
      final file = File('${dir.path}/${asset.id}$ext');
      final dio = Dio();
      await dio.download(url, file.path);
      if (mounted) {
        context.showSnackBar('Download completed');
      }
    } catch (e) {
      if (mounted) {
        context.showSnackBar('Download failed: $e', isError: true);
      }
    }
  }

  void _shareMedia(MediaAsset? asset) {
    if (asset == null) return;
    Share.share(UrlSanitizer.sanitize(asset.mediaUrl));
  }

  void _openOnReddit(MediaAsset? asset) async {
    if (asset == null) return;
    final url = 'https://reddit.com/r/${asset.subreddit}/comments/${asset.id}';
    if (await canLaunchUrl(Uri.parse(url))) {
      await launchUrl(Uri.parse(url));
    }
  }
}
