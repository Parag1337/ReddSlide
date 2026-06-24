import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/constants/theme_constants.dart';
import '../../providers/search_provider.dart';

class SearchFilterSheet extends ConsumerWidget {
  const SearchFilterSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(searchProvider);
    final theme = Theme.of(context);

    return Padding(
      padding: EdgeInsets.only(
        left: AppSpacing.xxl,
        right: AppSpacing.xxl,
        top: AppSpacing.xxl,
        bottom: MediaQuery.of(context).viewInsets.bottom + AppSpacing.xxl,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Filters', style: theme.textTheme.titleLarge),
              TextButton(
                onPressed: () {
                  ref.read(searchProvider.notifier).resetFilters();
                },
                child: const Text('Reset'),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xl),
          Text('Media Type', style: theme.textTheme.titleSmall),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              _buildFilterChip(theme, 'All', null, state.mediaType, () {
                ref.read(searchProvider.notifier).setMediaType(null);
              }),
              _buildFilterChip(theme, 'Images', 'images', state.mediaType, () {
                ref.read(searchProvider.notifier).setMediaType('images');
              }),
              _buildFilterChip(theme, 'Galleries', 'galleries', state.mediaType, () {
                ref.read(searchProvider.notifier).setMediaType('galleries');
              }),
              _buildFilterChip(theme, 'Videos', 'videos', state.mediaType, () {
                ref.read(searchProvider.notifier).setMediaType('videos');
              }),
            ],
          ),
          const SizedBox(height: AppSpacing.xl),
          Text('Sort By', style: theme.textTheme.titleSmall),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              _buildFilterChip(theme, 'Relevance', null, state.sort, () {
                ref.read(searchProvider.notifier).setSort(null);
              }),
              _buildFilterChip(theme, 'Newest', 'newest', state.sort, () {
                ref.read(searchProvider.notifier).setSort('newest');
              }),
              _buildFilterChip(theme, 'Most Upvoted', 'most_upvoted', state.sort, () {
                ref.read(searchProvider.notifier).setSort('most_upvoted');
              }),
            ],
          ),
          const SizedBox(height: AppSpacing.xxl),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () {
                final query = state.query;
                if (query.isNotEmpty) {
                  ref.read(searchProvider.notifier).search(query);
                }
                Navigator.pop(context);
              },
              child: const Text('Apply Filters'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChip(
    ThemeData theme,
    String label,
    String? value,
    String? currentValue,
    VoidCallback onSelected,
  ) {
    final isSelected = value == currentValue;
    return FilterChip(
      label: Text(label),
      selected: isSelected,
      onSelected: (_) => onSelected(),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(AppRadius.chip)),
    );
  }
}