class AppConstants {
  AppConstants._();

  static const int defaultSlideshowIntervalSeconds = 5;
  static const int tier1PreloadCount = 10;
  static const int tier2PreloadCount = 20;
  static const int historyCount = 5;
  static const int preloadTriggerRemaining = 30;
  static const int queueChipWindow = 25;
  static const int searchHistoryMax = 8;
  static const int overlayAutoHideMs = 3000;
  static const int paginationPageSize = 50;
  static const int mergeEngineBufferSize = 25;

  /// ImageCache configuration
  static const int imageCacheCapacity = 500;
  static const int imageCacheSizeMb = 200;

  /// Preload system
  static const int maxConcurrentPreloads = 3;
  static const int preloadedUrlSetMaxSize = 500;

  /// Timeout for image preload (milliseconds).
  static const int imagePreloadTimeoutMs = 60000;

  /// Max concurrent VideoPlayerController initializations
  static const int maxConcurrentVideoPrep = 2;

  /// Timeout for video initialization (milliseconds)
  static const int videoInitTimeoutMs = 15000;
}
