import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../../core/constants/theme_constants.dart';
import '../../domain/media_asset.dart';
import 'media_card.dart';

class MediaGrid extends ConsumerWidget {
  final List<MediaAsset> items;
  final bool isLoading;
  final bool isLoadingMore;
  final bool nsfwEnabled;
  final void Function(int index)? onItemTap;
  final VoidCallback? onLoadMore;

  const MediaGrid({
    super.key,
    required this.items,
    this.isLoading = false,
    this.isLoadingMore = false,
    required this.nsfwEnabled,
    this.onItemTap,
    this.onLoadMore,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final screenWidth = MediaQuery.of(context).size.width;
    final crossAxisCount = screenWidth >= 900 ? 4 : (screenWidth >= 600 ? 3 : 2);

    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollEndNotification &&
            notification.metrics.pixels >= notification.metrics.maxScrollExtent * 0.8) {
          onLoadMore?.call();
        }
        return false;
      },
      child: CustomScrollView(
        slivers: [
          SliverPadding(
            padding: const EdgeInsets.all(AppSpacing.lg),
            sliver: SliverGrid(
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: crossAxisCount,
                crossAxisSpacing: AppSpacing.md,
                mainAxisSpacing: AppSpacing.md,
                childAspectRatio: 1,
              ),
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  if (index >= items.length) return const SizedBox();
                  final filtered = items;
                  return MediaCard(
                    asset: filtered[index],
                    nsfwEnabled: nsfwEnabled,
                    onTap: () => onItemTap?.call(index),
                  );
                },
                childCount: items.length,
              ),
            ),
          ),
          if (isLoadingMore)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.xxl),
                child: Center(
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
