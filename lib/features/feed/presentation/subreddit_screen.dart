import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../shared/widgets/loading_shimmer.dart';
import '../../../shared/widgets/empty_state_widget.dart';
import '../../../shared/widgets/app_error_widget.dart';
import '../../settings/providers/settings_provider.dart';
import '../../settings/domain/settings_model.dart';
import '../../slideshow/domain/slideshow_source.dart';
import '../providers/feed_provider.dart';
import 'widgets/media_grid.dart';

class SubredditScreen extends ConsumerStatefulWidget {
  final String subredditName;

  const SubredditScreen({super.key, required this.subredditName});

  @override
  ConsumerState<SubredditScreen> createState() => _SubredditScreenState();
}

class _SubredditScreenState extends ConsumerState<SubredditScreen> {
  @override
  void initState() {
    super.initState();
    Future.microtask(() {
      ref.read(feedProvider(widget.subredditName).notifier).loadInitial();
    });
  }

  @override
  Widget build(BuildContext context) {
    final feedState = ref.watch(feedProvider(widget.subredditName));
    final settings = ref.watch(settingsProvider).valueOrNull;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text('r/${widget.subredditName}'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: () => ref.read(feedProvider(widget.subredditName).notifier).refresh(),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.sort),
            tooltip: 'Sort',
            onSelected: (mode) {
              ref.read(feedProvider(widget.subredditName).notifier).setSort(mode);
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'hot', child: Text('Hot')),
              const PopupMenuItem(value: 'new', child: Text('New')),
              const PopupMenuItem(value: 'top', child: Text('Top')),
            ],
          ),
        ],
      ),
      body: _buildBody(feedState, settings, theme),
      floatingActionButton: feedState.items.isNotEmpty && !feedState.isLoading
          ? FloatingActionButton.extended(
              onPressed: () {
                context.push('/slideshow', extra: SlideshowRouteExtra(
                  source: SubredditSource(subreddit: widget.subredditName),
                ));
              },
              icon: const Icon(Icons.play_arrow),
              label: const Text('Slideshow'),
            )
          : null,
    );
  }

  Widget _buildBody(dynamic feedState, SettingsModel? settings, ThemeData theme) {
    if (feedState.isLoading) {
      return const ShimmerGrid(count: 6, aspectRatio: 1, crossAxisCount: 2);
    }

    if (feedState.error != null) {
      return AppErrorWidget(
        error: feedState.error!,
        onRetry: () => ref.read(feedProvider(widget.subredditName).notifier).loadInitial(),
      );
    }

    if (feedState.items.isEmpty) {
      return EmptyStateWidget(
        icon: Icons.image_not_supported,
        title: 'No media yet',
        subtitle: 'Backend is loading content for r/${widget.subredditName}.\nTry refreshing in a few moments.',
        actionLabel: 'Refresh',
        onAction: () => ref.read(feedProvider(widget.subredditName).notifier).refresh(),
      );
    }

    return MediaGrid(
      items: feedState.items,
      isLoading: feedState.isLoading,
      isLoadingMore: feedState.isLoadingMore,
      nsfwEnabled: settings?.nsfwEnabled ?? false,
      onItemTap: (index) {
        context.push('/slideshow', extra: SlideshowRouteExtra(
          source: SubredditSource(subreddit: widget.subredditName),
          startIndex: index,
        ));
      },
      onLoadMore: () => ref.read(feedProvider(widget.subredditName).notifier).loadMore(),
    );
  }
}
