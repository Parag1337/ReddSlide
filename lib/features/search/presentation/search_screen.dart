import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/constants/theme_constants.dart';
import '../../../core/utils/debouncer.dart';
import '../../../shared/widgets/empty_state_widget.dart';
import '../../../shared/widgets/loading_shimmer.dart';
import '../../settings/providers/settings_provider.dart';
import '../../slideshow/domain/slideshow_source.dart';
import '../providers/search_provider.dart';
import 'widgets/search_history_chip.dart';
import 'widgets/search_result_card.dart';
import 'widgets/search_filter_sheet.dart';

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({super.key});

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _searchController = TextEditingController();
  final _debouncer = Debouncer(delay: const Duration(milliseconds: 500));
  final _scrollController = ScrollController();
  String _currentQuery = '';

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _searchController.dispose();
    _debouncer.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scrollController.position.pixels >= _scrollController.position.maxScrollExtent * 0.8) {
      ref.read(searchProvider.notifier).loadMore();
    }
  }

  void _executeSearch(String query) {
    _currentQuery = query.trim();
    if (_currentQuery.isNotEmpty) {
      ref.read(searchProvider.notifier).search(_currentQuery);
    }
  }

  @override
  Widget build(BuildContext context) {
    final searchState = ref.watch(searchProvider);
    final settings = ref.watch(settingsProvider).valueOrNull;
    final theme = Theme.of(context);
    final allSubreddits = settings?.subreddits ?? [];
    final hasSearched = _currentQuery.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: SizedBox(
          height: 40,
          child: TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: 'Search...',
              hintStyle: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.button),
                borderSide: BorderSide.none,
              ),
              filled: true,
              fillColor: theme.colorScheme.surfaceContainerHighest,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12),
              prefixIcon: Icon(Icons.search, size: 20, color: theme.colorScheme.onSurfaceVariant),
              suffixIcon: _searchController.text.isNotEmpty
                  ? IconButton(
                      icon: Icon(Icons.clear, size: 18, color: theme.colorScheme.onSurfaceVariant),
                      onPressed: () {
                        _searchController.clear();
                        ref.read(searchProvider.notifier).clearResults();
                        setState(() => _currentQuery = '');
                      },
                    )
                  : null,
            ),
            style: theme.textTheme.bodyLarge,
            onChanged: (value) {
              setState(() {});
            },
            onSubmitted: (value) {
              _executeSearch(value);
            },
          ),
        ),
      ),
      body: hasSearched && searchState.results.isNotEmpty
          ? _buildResults(searchState, theme, allSubreddits)
          : hasSearched && searchState.isLoading
              ? const ShimmerGrid(count: 6, crossAxisCount: 2, aspectRatio: 1)
              : _buildInitial(searchState, theme, allSubreddits),
    );
  }

  Widget _buildInitial(SearchState searchState, ThemeData theme, List<String> allSubreddits) {
    final subredditsAvailable = allSubreddits.isNotEmpty;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(AppSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildModeSelector(searchState, theme),
          const SizedBox(height: AppSpacing.lg),
          if (searchState.mode == SearchMode.local && subredditsAvailable)
            _buildSubredditSelector(searchState, theme, allSubreddits),
          const SizedBox(height: AppSpacing.lg),
          if (searchState.mode == SearchMode.local && !subredditsAvailable)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.lg),
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  child: Text(
                    'No subreddits configured. Go to Settings to add subreddits, then use Local Search.',
                    style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              ),
            ),
          if (searchState.recentQueries.isNotEmpty) _buildRecentSearches(searchState, theme),
          if (searchState.error != null)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.lg),
              child: EmptyStateWidget(
                icon: Icons.error_outline,
                title: 'Search failed',
                actionLabel: 'Try again',
                onAction: () => _executeSearch(_currentQuery),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildModeSelector(SearchState searchState, ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Mode', style: theme.textTheme.titleSmall),
        const SizedBox(height: AppSpacing.sm),
        SegmentedButton<SearchMode>(
          segments: const [
            ButtonSegment(value: SearchMode.local, label: Text('Local Search')),
            ButtonSegment(value: SearchMode.global, label: Text('Global Search')),
          ],
          selected: {searchState.mode},
          onSelectionChanged: (modeSet) {
            ref.read(searchProvider.notifier).setMode(modeSet.first);
          },
          showSelectedIcon: false,
          style: ButtonStyle(
            visualDensity: VisualDensity.compact,
            shape: WidgetStatePropertyAll(
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.button)),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSubredditSelector(SearchState searchState, ThemeData theme, List<String> allSubreddits) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.md),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.subscriptions, size: 20, color: theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: AppSpacing.sm),
                Text('Subreddits', style: theme.textTheme.titleSmall),
                const Spacer(),
                TextButton(
                  onPressed: () {
                    ref.read(searchProvider.notifier).setSelectedSubreddits(List.from(allSubreddits));
                  },
                  child: const Text('Select All'),
                ),
                TextButton(
                  onPressed: () {
                    ref.read(searchProvider.notifier).setSelectedSubreddits([]);
                  },
                  child: const Text('Clear'),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            ...allSubreddits.map((sub) {
              final isSelected = searchState.selectedSubreddits.contains(sub);
              return CheckboxListTile(
                dense: true,
                visualDensity: VisualDensity.compact,
                title: Text('r/$sub', style: theme.textTheme.bodyMedium),
                value: isSelected,
                onChanged: (_) {
                  ref.read(searchProvider.notifier).toggleSubreddit(sub);
                },
                controlAffinity: ListTileControlAffinity.leading,
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildRecentSearches(SearchState searchState, ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('Recent searches', style: theme.textTheme.titleSmall),
            TextButton(
              onPressed: () => ref.read(searchProvider.notifier).clearHistory(),
              child: const Text('Clear all'),
            ),
          ],
        ),
        SizedBox(
          height: 40,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: searchState.recentQueries.map((q) {
              return SearchHistoryChip(
                query: q,
                onTap: () {
                  _searchController.text = q;
                  _executeSearch(q);
                },
                onDelete: () {
                  ref.read(searchProvider.notifier).removeRecentQuery(q);
                },
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  Widget _buildResults(SearchState searchState, ThemeData theme, List<String> allSubreddits) {
    final resultCount = searchState.totalResults > 0 ? searchState.totalResults : searchState.results.length;

    return Column(
      children: [
        _buildResultsHeader(searchState, theme, resultCount),
        const Divider(height: 1),
        Expanded(child: _buildResultsGrid(searchState, theme)),
      ],
    );
  }

  Widget _buildResultsHeader(SearchState searchState, ThemeData theme, int resultCount) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(AppSpacing.lg, AppSpacing.md, AppSpacing.sm, AppSpacing.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '"${searchState.query}"',
                      style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$resultCount ${resultCount == 1 ? 'Result' : 'Results'}',
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: Icon(Icons.filter_list, color: theme.colorScheme.onSurfaceVariant),
                tooltip: 'Filters',
                onPressed: () {
                  showModalBottomSheet(
                    context: context,
                    builder: (_) => const SearchFilterSheet(),
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.dialog)),
                    ),
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: () {
                context.push('/slideshow', extra: SlideshowRouteExtra(
                  source: SearchSource(
                    query: searchState.query,
                    mode: searchState.mode,
                    subreddits: searchState.mode == SearchMode.local && searchState.selectedSubreddits.isNotEmpty
                        ? searchState.selectedSubreddits
                        : null,
                    mediaType: searchState.mediaType,
                    sort: searchState.sort,
                  ),
                  startIndex: 0,
                ));
              },
              icon: const Icon(Icons.play_arrow, size: 20),
              label: const Text('Start Slideshow'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildResultsGrid(SearchState searchState, ThemeData theme) {
    final screenWidth = MediaQuery.of(context).size.width;
    final crossAxisCount = screenWidth >= 900 ? 4 : (screenWidth >= 600 ? 3 : 2);

    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollEndNotification &&
            notification.metrics.pixels >= notification.metrics.maxScrollExtent * 0.8) {
          ref.read(searchProvider.notifier).loadMore();
        }
        return false;
      },
      child: CustomScrollView(
        controller: _scrollController,
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            sliver: SliverGrid(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: crossAxisCount,
                crossAxisSpacing: AppSpacing.md,
                mainAxisSpacing: AppSpacing.md,
                childAspectRatio: 0.7,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  if (index >= searchState.results.length) return const SizedBox();
                  final asset = searchState.results[index];
                  return SearchResultCard(
                    asset: asset,
                    nsfwEnabled: true,
                    onTap: () {
                      context.push('/slideshow', extra: SlideshowRouteExtra(
                        source: SearchSource(
                          query: searchState.query,
                          mode: searchState.mode,
                          subreddits: searchState.mode == SearchMode.local && searchState.selectedSubreddits.isNotEmpty
                              ? searchState.selectedSubreddits
                              : null,
                          mediaType: searchState.mediaType,
                          sort: searchState.sort,
                        ),
                        startIndex: index,
                      ));
                    },
                  );
                },
                childCount: searchState.results.length,
              ),
            ),
          ),
          if (searchState.isLoadingMore)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.xxl),
                child: Center(
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ),
              ),
            ),
          if (!searchState.hasMore && searchState.results.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.xxl),
                child: Center(
                  child: Text(
                    'No more results',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
