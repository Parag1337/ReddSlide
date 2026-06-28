abstract class PreparationScheduler {
  void Function(String url)? get onUrlStarted;
  set onUrlStarted(void Function(String url)? cb);

  void Function(String url)? get onUrlReady;
  set onUrlReady(void Function(String url)? cb);

  void Function(String url)? get onUrlFailed;
  set onUrlFailed(void Function(String url)? cb);

  void onIndexChanged(int currentIndex, {int galleryIndex = 0});

  void onPlaylistReplaced();

  Set<String> get plannedUrls;

  bool get isIdle;

  bool get hasFailed;

  void dispose();
}
