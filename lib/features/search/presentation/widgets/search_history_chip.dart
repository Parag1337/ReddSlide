import 'package:flutter/material.dart';
import '../../../../core/constants/theme_constants.dart';

class SearchHistoryChip extends StatelessWidget {
  final String query;
  final VoidCallback onTap;
  final VoidCallback onDelete;

  const SearchHistoryChip({
    super.key,
    required this.query,
    required this.onTap,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: InputChip(
        avatar: Icon(Icons.history, size: 14, color: theme.colorScheme.onSurfaceVariant),
        label: Text(query),
        onPressed: onTap,
        onDeleted: onDelete,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.chip),
        ),
      ),
    );
  }
}
