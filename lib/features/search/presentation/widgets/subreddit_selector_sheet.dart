import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/constants/theme_constants.dart';
import '../../../settings/providers/settings_provider.dart';
import '../../providers/search_provider.dart';

class SubredditSelectorSheet extends ConsumerStatefulWidget {
  const SubredditSelectorSheet({super.key});

  @override
  ConsumerState<SubredditSelectorSheet> createState() => _SubredditSelectorSheetState();
}

class _SubredditSelectorSheetState extends ConsumerState<SubredditSelectorSheet> {
  String _filter = '';

  @override
  Widget build(BuildContext context) {
    final searchState = ref.watch(searchProvider);
    final settings = ref.watch(settingsProvider).valueOrNull;
    final allSubreddits = settings?.subreddits ?? [];
    final theme = Theme.of(context);

    final filtered = _filter.isEmpty
        ? allSubreddits
        : allSubreddits.where((s) => s.toLowerCase().contains(_filter.toLowerCase())).toList();

    return Padding(
      padding: EdgeInsets.only(
        left: AppSpacing.lg,
        right: AppSpacing.lg,
        top: AppSpacing.lg,
        bottom: MediaQuery.of(context).viewInsets.bottom + AppSpacing.lg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Select Subreddits', style: theme.textTheme.titleMedium),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(context),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          TextField(
            decoration: InputDecoration(
              hintText: 'Filter subreddits...',
              prefixIcon: Icon(Icons.search, size: 20, color: theme.colorScheme.onSurfaceVariant),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.button),
                borderSide: BorderSide.none,
              ),
              filled: true,
              fillColor: theme.colorScheme.surfaceContainerHighest,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              suffixIcon: _filter.isNotEmpty
                  ? IconButton(
                      icon: Icon(Icons.clear, size: 18, color: theme.colorScheme.onSurfaceVariant),
                      onPressed: () => setState(() => _filter = ''),
                    )
                  : null,
            ),
            style: theme.textTheme.bodyMedium,
            onChanged: (v) => setState(() => _filter = v),
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              TextButton.icon(
                icon: const Icon(Icons.select_all, size: 18),
                label: const Text('Select All'),
                onPressed: () {
                  ref.read(searchProvider.notifier).setSelectedSubreddits(List.from(allSubreddits));
                },
              ),
              const SizedBox(width: AppSpacing.sm),
              TextButton.icon(
                icon: const Icon(Icons.deselect, size: 18),
                label: const Text('Clear All'),
                onPressed: () {
                  ref.read(searchProvider.notifier).setSelectedSubreddits([]);
                },
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: filtered.map((sub) {
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
              }).toList(),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Done'),
            ),
          ),
        ],
      ),
    );
  }
}