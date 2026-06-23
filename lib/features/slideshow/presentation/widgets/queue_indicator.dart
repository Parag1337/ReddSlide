import 'package:flutter/material.dart';
import '../../../../core/constants/app_constants.dart';

class QueueIndicator extends StatelessWidget {
  final int totalItems;
  final int currentIndex;
  final void Function(int index)? onChipTap;

  const QueueIndicator({
    super.key,
    required this.totalItems,
    required this.currentIndex,
    this.onChipTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final window = AppConstants.queueChipWindow;
    final start = (currentIndex - window).clamp(0, totalItems);
    final end = (currentIndex + window).clamp(0, totalItems);

    return SizedBox(
      height: 40,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        itemCount: (end - start).clamp(0, totalItems),
        itemBuilder: (context, index) {
          final itemIndex = start + index;
          final isCurrent = itemIndex == currentIndex;
          return GestureDetector(
            onTap: () => onChipTap?.call(itemIndex),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
              padding: EdgeInsets.symmetric(horizontal: isCurrent ? 10.0 : 6.0),
              decoration: BoxDecoration(
                color: isCurrent ? theme.colorScheme.primary : theme.colorScheme.surfaceContainerHigh,
                borderRadius: BorderRadius.circular(14),
              ),
              alignment: Alignment.center,
              child: Text(
                '${itemIndex + 1}',
                style: TextStyle(
                  color: isCurrent ? theme.colorScheme.onPrimary : theme.colorScheme.onSurfaceVariant,
                  fontSize: isCurrent ? 13 : 11,
                  fontWeight: isCurrent ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
