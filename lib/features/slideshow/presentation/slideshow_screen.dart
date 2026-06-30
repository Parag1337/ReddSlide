import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path_provider/path_provider.dart';
import 'package:dio/dio.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:share_plus/share_plus.dart';
import '../../../core/constants/theme_constants.dart';
import '../../../core/debug/trace.dart';
import '../../../core/display_quality/display_quality_mode.dart';
import '../../../core/extensions/context_extensions.dart';
import '../../../core/media/media_error.dart';
import '../../../shared/utils/url_sanitizer.dart';
import '../../../shared/widgets/empty_state_widget.dart';
import '../../feed/domain/media_asset.dart';
import '../../settings/domain/settings_model.dart';
import '../../settings/providers/settings_provider.dart';
import '../domain/metrics_collector.dart';
import '../domain/slide_profiler.dart'; // TEMPORARY — Phase 7.2A
import '../domain/slideshow_source.dart';
import '../providers/slideshow_provider.dart';
import 'widgets/media_viewer.dart';
import 'widgets/slideshow_overlay.dart';

class SlideshowScreen extends ConsumerStatefulWidget {
  final SlideshowSource source;
  final int startIndex;

  const SlideshowScreen({
    super.key,
    required this.source,
    this.startIndex = 0,
  });

  @override
  ConsumerState<SlideshowScreen> createState() => _SlideshowScreenState();
}

class _SlideshowScreenState extends ConsumerState<SlideshowScreen> with WidgetsBindingObserver {
  late final PageController _pageController;
  ProviderSubscription<int?>? _currentIndexSub;
  ProviderSubscription<AsyncValue<SettingsModel>>? _settingsSub;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(initialPage: widget.startIndex);
    WidgetsBinding.instance.addObserver(this);
    _setProfilerSource(); // TEMPORARY — Phase 7.2A
    Future.microtask(() {
      if (!mounted) return;
      final notifier = ref.read(slideshowProvider(widget.source).notifier);
      final settings = ref.read(settingsProvider).valueOrNull;

      notifier.attachPreparationEngine(
        context,
        displayQualityMode: settings?.displayQualityMode ?? DisplayQualityMode.smart,
      );

      notifier.initialize();

      if (widget.startIndex > 0) {
        notifier.setStartIndex(widget.startIndex);
      }
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

  void _setProfilerSource() { // TEMPORARY — Phase 7.2A
    final tag = switch (widget.source) {
      SubredditSource() => 'subreddit',
      MultiSubredditSource() => 'multi',
      GlobalFeedSource() => 'global',
      SearchSource() => 'search',
      GroupSource() => 'group',
    };
    SlideProfiler.setSourceType(tag);
  }

  @override
  void dispose() {
    Trace.t('SlideshowScreen.dispose', ['pageController', _pageController.hasClients]);
    debugPrint(SlideProfiler.dumpReport()); // TEMPORARY — Phase 7.2A
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

  Future<void> _saveSession() async {}

  @override
  Widget build(BuildContext context) {
    final isLoading = ref.watch(slideshowProvider(widget.source).select((s) => s.isLoading));
    final itemsEmpty = ref.watch(slideshowProvider(widget.source).select((s) => s.items.isEmpty));
    Trace.t('SlideshowScreen.build', ['isLoading', isLoading, 'itemsEmpty', itemsEmpty]);

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          _SlideshowPageContent(
            source: widget.source,
            pageController: _pageController,
            onPageChanged: (index) {
              ref.read(slideshowProvider(widget.source).notifier).jumpTo(index);
            },
            isLoading: isLoading,
            itemsEmpty: itemsEmpty,
            onMediaError: _onMediaError,
            onVideoCompleted: (url) {
              ref.read(slideshowProvider(widget.source).notifier).galleryNext();
            },
          ),
          Consumer(
            builder: (context, ref, _) {
              final isLoadingMore = ref.watch(
                slideshowProvider(widget.source).select((s) => s.isLoadingMore),
              );
              if (!isLoadingMore) return const SizedBox.shrink();
              return Positioned(
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
              );
            },
          ),
          _SlideshowOverlayContent(
            source: widget.source,
            pageController: _pageController,
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
  }
}

class _SlideshowPageContent extends ConsumerStatefulWidget {
  final SlideshowSource source;
  final PageController pageController;
  final ValueChanged<int> onPageChanged;
  final bool isLoading;
  final bool itemsEmpty;
  final void Function(MediaErrorType) onMediaError;
  final void Function(String url)? onVideoCompleted;

  const _SlideshowPageContent({
    required this.source,
    required this.pageController,
    required this.onPageChanged,
    required this.isLoading,
    required this.itemsEmpty,
    required this.onMediaError,
    this.onVideoCompleted,
  });

  @override
  ConsumerState<_SlideshowPageContent> createState() => _SlideshowPageContentState();
}

class _SlideshowPageContentState extends ConsumerState<_SlideshowPageContent> {
  String? _lastVisibleAssetId;
  bool _emittedOpened = false;
  bool _emittedFirstRequested = false;

  void _emitOpenedIfNeeded(SlideshowNotifier notifier) {
    if (!_emittedOpened) {
      _emittedOpened = true;
      final desc = switch (widget.source) {
        SubredditSource(:final subreddit) => 'subreddit=$subreddit',
        MultiSubredditSource(:final subreddits) => 'subreddits=${subreddits.length}',
        GlobalFeedSource() => 'global',
        SearchSource(:final query) => 'query=$query',
        GroupSource(:final groupName) => 'group=$groupName',
      };
      notifier.metrics.recordEvent(MetricEventType.slideshowOpened, data: {'source': desc});
    }
  }

  void _emitFirstRequestedIfNeeded(SlideshowNotifier notifier, String assetId, int index) {
    if (!_emittedFirstRequested) {
      _emittedFirstRequested = true;
      notifier.metrics.recordEvent(MetricEventType.firstImageRequested, data: {
        'assetId': assetId,
        'index': index,
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.isLoading) {
      return const Center(child: CircularProgressIndicator(color: Colors.white));
    }
    if (widget.itemsEmpty) {
      return const Center(
        child: EmptyStateWidget(
          icon: Icons.image_not_supported,
          title: 'No media yet',
          subtitle: 'Backend is currently loading content for this subreddit.\nTry refreshing in a few moments.',
        ),
      );
    }

    final items = ref.watch(slideshowProvider(widget.source).select((s) => s.items));
    final currentIndex = ref.watch(slideshowProvider(widget.source).select((s) => s.currentIndex));
    final gallerySubIndex = ref.watch(slideshowProvider(widget.source).select((s) => s.gallerySubIndex));
    final isMuted = ref.watch(slideshowProvider(widget.source).select((s) => s.isMuted));
    ref.watch(slideshowProvider(widget.source).select((s) => s.preparationRevision));
    final notifier = ref.read(slideshowProvider(widget.source).notifier);

    _emitOpenedIfNeeded(notifier);
    SlideProfiler.recordPageViewBuild(); // TEMPORARY — Phase 7.2A
    Trace.t('SlideshowPageContent.build', [
      'revision', ref.watch(slideshowProvider(widget.source).select((s) => s.preparationRevision)),
      'items', items.length,
      'index', currentIndex,
      'galleryIndex', gallerySubIndex,
    ]);

    return PageView.builder(
      controller: widget.pageController,
      itemCount: items.length,
      scrollDirection: Axis.horizontal,
      onPageChanged: widget.onPageChanged,
      itemBuilder: (context, index) {
        if (index >= items.length) return const SizedBox();
        final asset = items[index];
        final handle = notifier.getPreparedHandle(
          asset,
          galleryIndex: index == currentIndex ? gallerySubIndex : 0,
        );
        Trace.t('PageView.itemBuilder', [
          'page', index,
          'assetId', asset.id,
          'isVideo', asset.isVideo,
          'handleState', handle.state.name,
          'ctrl', '${handle.controller?.hashCode}',
          'ctrlInit', '${handle.controller?.value.isInitialized}',
          'failed', handle.preparationFailed,
        ]);
        if (index == currentIndex && asset.id != _lastVisibleAssetId) {
          _lastVisibleAssetId = asset.id;
          _emitFirstRequestedIfNeeded(notifier, asset.id, index);
          notifier.metrics.recordEvent(
            asset.isVideo
                ? MetricEventType.slideshowVideoVisible
                : MetricEventType.slideshowImageVisible,
            data: {'assetId': asset.id, 'index': index},
          );
        }
        return RepaintBoundary(
          child: GestureDetector(
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
              handle: handle,
              isMuted: isMuted,
              onMediaError: widget.onMediaError,
              onImageDecoded: (url, {required bool wasCached}) {
                notifier.metrics.recordEvent(
                  wasCached ? MetricEventType.imageCacheHit : MetricEventType.imageCacheMiss,
                  data: {'assetId': asset.id, 'index': index, 'url': url},
                );
                notifier.metrics.recordEvent(MetricEventType.imageDecoded, data: {
                  'assetId': asset.id,
                  'index': index,
                  'url': url,
                  'wasCached': wasCached,
                });
              },
              onVideoFirstFrame: (url) {
                notifier.metrics.recordEvent(MetricEventType.videoFirstFrameRendered, data: {
                  'assetId': asset.id,
                  'index': index,
                  'url': url,
                });
              },
              onVideoCompleted: widget.onVideoCompleted,
            ),
          ),
        );
      },
    );
  }
}

class _SlideshowOverlayContent extends ConsumerWidget {
  final SlideshowSource source;
  final PageController pageController;

  const _SlideshowOverlayContent({
    required this.source,
    required this.pageController,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(slideshowProvider(source));
    final currentAsset = state.items.isNotEmpty && state.currentIndex < state.items.length
        ? state.items[state.currentIndex]
        : null;
    final currentGalleryLength = currentAsset != null && currentAsset.isGallery && currentAsset.galleryUrls != null
        ? currentAsset.galleryUrls!.length
        : 0;

    return SlideshowOverlay(
      source: source,
      currentAsset: currentAsset,
      currentIndex: state.currentIndex,
      totalItems: state.items.length,
      galleryIndex: state.gallerySubIndex,
      galleryLength: currentGalleryLength,
      isPlaying: state.isPlaying,
      isMuted: state.isMuted,
      isFullscreen: state.isFullscreen,
      visible: state.overlayVisible,
      onBack: () => context.pop(),
      onPrevious: () => ref.read(slideshowProvider(source).notifier).galleryPrevious(),
      onPlayPause: () => ref.read(slideshowProvider(source).notifier).togglePlay(),
      onNext: () => ref.read(slideshowProvider(source).notifier).galleryNext(),
      onToggleMute: () => ref.read(slideshowProvider(source).notifier).toggleMute(),
      onToggleFullscreen: () {
        ref.read(slideshowProvider(source).notifier).toggleFullscreen();
        _applyFullscreenMode(!state.isFullscreen);
      },
      onDownload: () => _downloadMedia(context, currentAsset),
      onShare: () => _shareMedia(currentAsset),
      onOpenReddit: () => _openOnReddit(currentAsset),
      onChipTap: (index) => ref.read(slideshowProvider(source).notifier).jumpTo(index),
    );
  }
}

void _applyFullscreenMode(bool fullscreen) {
  if (fullscreen) {
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

Future<void> _downloadMedia(BuildContext context, MediaAsset? asset) async {
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
    if (context.mounted) {
      context.showSnackBar('Download completed');
    }
  } catch (e) {
    if (context.mounted) {
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
