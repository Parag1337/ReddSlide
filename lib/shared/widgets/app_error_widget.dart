import 'package:flutter/material.dart';
import '../../core/errors/app_error.dart';

class AppErrorWidget extends StatelessWidget {
  final AppError error;
  final VoidCallback? onRetry;
  final VoidCallback? onSettings;

  const AppErrorWidget({
    super.key,
    required this.error,
    this.onRetry,
    this.onSettings,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final errorInfo = _getErrorInfo();

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.error_outline, size: 48, color: theme.colorScheme.error),
            const SizedBox(height: 16),
            Text(errorInfo.title, style: theme.textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              errorInfo.message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (onRetry != null)
                  FilledButton.tonalIcon(
                    onPressed: onRetry,
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry'),
                  ),
                if (onSettings != null) ...[
                  const SizedBox(width: 12),
                  FilledButton.tonalIcon(
                    onPressed: onSettings,
                    icon: const Icon(Icons.settings),
                    label: const Text('Settings'),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  _ErrorInfo _getErrorInfo() {
    return switch (error) {
      NetworkError(:final message) => _ErrorInfo('Connection Error', message),
      ServerError(:final statusCode, :final message) => _ErrorInfo('Server Error ($statusCode)', message),
      NotConfiguredError() => _ErrorInfo('Backend Not Configured', 'Please set your backend URL in Settings.'),
      ParseError(:final message) => _ErrorInfo('Data Error', message),
      NotFoundError() => _ErrorInfo('Not Found', 'The requested content was not found.'),
    };
  }
}

class _ErrorInfo {
  final String title;
  final String message;
  const _ErrorInfo(this.title, this.message);
}
