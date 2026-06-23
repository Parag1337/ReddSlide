import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/errors/app_error.dart';
import '../../../shared/widgets/empty_state_widget.dart';
import '../../../shared/widgets/app_error_widget.dart';
import '../../settings/providers/settings_provider.dart';
import '../../slideshow/domain/slideshow_source.dart';
import '../data/feed_repository.dart';
import 'widgets/subreddit_card.dart';

final homeFeedProvider = FutureProvider.autoDispose.family<Map<String, String?>, String>((ref, subreddit) async {
  final repo = ref.watch(feedRepositoryProvider);
  final result = await repo.getFeed(subreddits: subreddit, limit: 1);
  return result.when(
    (data) => {subreddit: data.items.isNotEmpty ? data.items.first.thumbnailUrl : null},
    (error) => <String, String?>{subreddit: null},
  );
});

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  bool _selectionMode = false;
  final Set<String> _selectedSubreddits = {};

  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(settingsProvider);
    final theme = Theme.of(context);
    final screenWidth = MediaQuery.of(context).size.width;
    final crossAxisCount = screenWidth >= 900 ? 4 : (screenWidth >= 600 ? 3 : 2);

    return settingsAsync.when(
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Scaffold(
        body: AppErrorWidget(
          error: NetworkError(e.toString()),
          onSettings: () => context.go('/settings'),
        ),
      ),
      data: (settings) {
        if (settings.backendUrl.isEmpty) {
          return _buildNotConfigured(theme);
        }

        if (settings.subreddits.isEmpty) {
          return _buildEmptySubreddits(theme);
        }

        return Scaffold(
          appBar: AppBar(
            title: Text('RedSlide', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
            actions: [
              _QueueStatusChip(),
              const SizedBox(width: 8),
              _HealthIndicator(),
              const SizedBox(width: 8),
            ],
          ),
          body: RefreshIndicator(
            onRefresh: () async {},
            child: LayoutBuilder(
              builder: (context, constraints) {
                return CustomScrollView(
                  slivers: [
                    SliverPadding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                      sliver: SliverGrid(
                        gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                          crossAxisCount: crossAxisCount,
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 12,
                          childAspectRatio: 3 / 4,
                        ),
                        delegate: SliverChildBuilderDelegate(
                          (context, index) {
                            if (index >= settings.subreddits.length) return const SizedBox();
                            final sub = settings.subreddits[index];
                            final coverAsync = ref.watch(homeFeedProvider(sub));
                            final coverUrl = coverAsync.valueOrNull?[sub];
                            return SubredditCard(
                              name: sub,
                              coverUrl: coverUrl,
                              enabled: true,
                              isSelected: _selectedSubreddits.contains(sub),
                              selectionMode: _selectionMode,
                              onTap: () {
                                if (_selectionMode) {
                                  _toggleSelection(sub);
                                } else {
                                  context.push('/subreddit/$sub');
                                }
                              },
                              onLongPress: () {
                                if (!_selectionMode) {
                                  setState(() {
                                    _selectionMode = true;
                                    _selectedSubreddits.add(sub);
                                  });
                                }
                              },
                            );
                          },
                          childCount: settings.subreddits.length,
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
          floatingActionButton: _selectionMode
              ? FloatingActionButton.extended(
                  onPressed: _selectedSubreddits.isEmpty
                      ? null
                      : () {
                          final source = MultiSubredditSource(
                            subreddits: _selectedSubreddits.toList(),
                            sortMode: settings.defaultSortMode,
                          );
                          setState(() {
                            _selectionMode = false;
                            _selectedSubreddits.clear();
                          });
                          context.push('/slideshow', extra: SlideshowRouteExtra(source: source));
                        },
                  icon: const Icon(Icons.play_arrow),
                  label: Text('${_selectedSubreddits.length} selected'),
                )
              : FloatingActionButton.extended(
                  onPressed: () {
                    final source = MultiSubredditSource(
                      subreddits: settings.subreddits,
                      sortMode: settings.defaultSortMode,
                    );
                    context.push('/slideshow', extra: SlideshowRouteExtra(source: source));
                  },
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('Start All'),
                ),
        );
      },
    );
  }

  Widget _buildNotConfigured(ThemeData theme) {
    return Scaffold(
      body: EmptyStateWidget(
        icon: Icons.cloud_off,
        title: 'Backend not configured',
        subtitle: 'Set your backend URL in Settings to get started.',
        actionLabel: 'Open Settings',
        onAction: () => context.go('/settings'),
      ),
    );
  }

  Widget _buildEmptySubreddits(ThemeData theme) {
    return Scaffold(
      appBar: AppBar(title: Text('RedSlide', style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700))),
      body: EmptyStateWidget(
        icon: Icons.subscriptions,
        title: 'No subreddits yet',
        subtitle: 'Add subreddits in Settings to start browsing.',
        actionLabel: 'Open Settings',
        onAction: () => context.go('/settings'),
      ),
    );
  }

  void _toggleSelection(String sub) {
    setState(() {
      if (_selectedSubreddits.contains(sub)) {
        _selectedSubreddits.remove(sub);
        if (_selectedSubreddits.isEmpty) {
          _selectionMode = false;
        }
      } else {
        _selectedSubreddits.add(sub);
      }
    });
  }
}

class _QueueStatusChip extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.queue_play_next, size: 14, color: theme.colorScheme.primary),
          const SizedBox(width: 4),
          Text('--', style: theme.textTheme.labelSmall),
        ],
      ),
    );
  }
}

class _HealthIndicator extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    return Container(
      width: 8,
      height: 8,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: theme.colorScheme.primary,
      ),
    );
  }
}

final resumeSessionProvider = Provider.family<ResumeSession?, String>((ref, key) => null);

class ResumeSession {
  final SlideshowSource source;
  final int index;
  final bool isPlaying;
  ResumeSession({required this.source, required this.index, required this.isPlaying});
}
