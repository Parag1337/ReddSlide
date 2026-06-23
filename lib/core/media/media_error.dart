import 'dart:developer';

enum MediaErrorType {
  http404,
  http410,
  timeout,
  socketError,
  videoInitError,
  unknown;

  String get label {
    return switch (this) {
      http404 => 'HTTP_404',
      http410 => 'HTTP_410',
      timeout => 'TIMEOUT',
      socketError => 'SOCKET_ERROR',
      videoInitError => 'VIDEO_INIT_ERROR',
      unknown => 'UNKNOWN',
    };
  }
}

String _actionLabel(bool isGallery, bool isLastInGallery) {
  if (isGallery && !isLastInGallery) return 'SKIP_GALLERY_NEXT';
  return 'SKIP_NEXT';
}

void logMediaError({
  required String redditId,
  required String subreddit,
  required String url,
  required MediaErrorType errorType,
  required bool isGallery,
  required bool isLastInGallery,
}) {
  final action = _actionLabel(isGallery, isLastInGallery);
  log(
    '[MediaError] '
    'reddit_id=$redditId '
    'subreddit=$subreddit '
    'url=$url '
    'reason=${errorType.label} '
    'action=$action',
  );
}
