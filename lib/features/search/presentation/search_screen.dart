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
import 'widgets/search_result_tile.dart';
import 'widgets/search_history_chip.dart';

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

  @override
  Widget build(BuildContext context) {
    final searchState = ref.watch(searchProvider);
    final settings = ref.watch(settingsProvider).valueOrNull;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: SizedBox(
          height: 40,
          child: TextField(
            controller: _searchController,
            autofocus: true,
            decoration: InputDecoration(
              hintText: 'Search across all subreddits...',
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
              _debouncer.call(() {
                _currentQuery = value.trim();
                if (_currentQuery.isNotEmpty) {
                  ref.read(searchProvider.notifier).search(_currentQuery);
                } else {
                  ref.read(searchProvider.notifier).clearResults();
                }
              });
            },
          ),
        ),
      ),
      body: _buildBody(searchState, settings, theme),
      bottomNavigationBar: searchState.results.isNotEmpty && !searchState.isLoading
          ? _buildSlideshowBar(searchState, theme)
          : null,
    );
  }

  Widget _buildBody(SearchState searchState, dynamic settings, ThemeData theme) {
    if (searchState.isLoading) {
      return const ShimmerGrid(count: 6, crossAxisCount: 1, aspectRatio: 5);
    }

    if (_currentQuery.isEmpty) {
      if (searchState.recentQueries.isNotEmpty) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('Recent searches', style: theme.textTheme.titleSmall),
                  TextButton(
                    onPressed: () => ref.read(searchProvider.notifier).clearHistory(),
                    child: const Text('Clear all'),
                  ),
                ],
              ),
            ),
            SizedBox(
              height: 40,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: searchState.recentQueries.map((q) {
                  return SearchHistoryChip(
                    query: q,
                    onTap: () {
                      _searchController.text = q;
                      _currentQuery = q;
                      ref.read(searchProvider.notifier).search(q);
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
      return EmptyStateWidget(
        icon: Icons.search,
        title: 'Search across all subreddits',
        subtitle: 'Find wallpapers, art, and more',
      );
    }

    if (searchState.error != null) {
      return EmptyStateWidget(
        icon: Icons.error_outline,
        title: 'Search failed',
        actionLabel: 'Try again',
        onAction: () => ref.read(searchProvider.notifier).search(_currentQuery),
      );
    }

    if (searchState.results.isEmpty) {
      return EmptyStateWidget(
        icon: Icons.search_off,
        title: 'No results for "$_currentQuery"',
        subtitle: searchState.isDebugFallback ? 'Showing partial matches' : null,
      );
    }

    return Column(
      children: [
        if (searchState.isDebugFallback)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: theme.colorScheme.tertiaryContainer,
            child: Text(
              'Showing partial matches',
              style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onTertiaryContainer),
            ),
          ),
        Expanded(
          child: ListView.builder(
            controller: _scrollController,
            itemCount: searchState.results.length + (searchState.isLoadingMore ? 1 : 0),
            itemBuilder: (context, index) {
              if (index >= searchState.results.length) {
                return const Padding(
                  padding: EdgeInsets.all(16),
                  child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                );
              }
              final asset = searchState.results[index];
              return SearchResultTile(
                asset: asset,
                onTap: () {
                  context.push('/slideshow', extra: SlideshowRouteExtra(
                    source: SearchSource(query: _currentQuery),
                    startIndex: index,
                  ));
                },
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _buildSlideshowBar(SearchState searchState, ThemeData theme) {
    return Container(
      height: 56,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        border: Border(top: BorderSide(color: theme.colorScheme.outlineVariant, width: 0.5)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            Expanded(
              child: Text(
                '${searchState.results.length} results for "$_currentQuery"',
                style: theme.textTheme.bodyMedium,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            FilledButton.icon(
              onPressed: () {
                context.push('/slideshow', extra: SlideshowRouteExtra(
                  source: SearchSource(query: _currentQuery),
                  startIndex: 0,
                ));
              },
              icon: const Icon(Icons.play_arrow, size: 18),
              label: const Text('Slideshow'),
            ),
          ],
        ),
      ),
    );
  }
}
