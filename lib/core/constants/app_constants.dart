class AppConstants {
  AppConstants._();

  static const int defaultSlideshowIntervalSeconds = 5;
  static const int maxCacheMemoryItems = 500;
  static const int tier1PreloadCount = 10;
  static const int tier2PreloadCount = 20;
  static const int historyCount = 5;
  static const int preloadTriggerRemaining = 30;
  static const int queueChipWindow = 25;
  static const int searchHistoryMax = 8;
  static const int searchDebounceMs = 500;
  static const double grid80PercentTrigger = 0.8;
  static const int maxRetries = 3;
  static const int overlayAutoHideMs = 3000;
  static const int paginationPageSize = 50;
  static const int mergeEngineBufferSize = 25;

  /// ImageCache configuration
  static const int imageCacheCapacity = 500;
  static const int imageCacheSizeMb = 200;

  /// Preload system
  static const int maxConcurrentPreloads = 3;
  static const int preloadedUrlSetMaxSize = 500;
  static const int preloadCheckIntervalMs = 100;

  /// Timeout for image preload (milliseconds).
  /// Prevents a single slow/failed image from blocking a worker indefinitely.
  static const int imagePreloadTimeoutMs = 60000;

  /// Video pre-initialization window (how many videos ahead to prepare)
  static const int videoPreloadWindow = 2;

  /// Max concurrent VideoPlayerController initializations
  static const int maxConcurrentVideoPrep = 2;

  /// Timeout for video initialization (milliseconds)
  static const int videoInitTimeoutMs = 15000;
}
