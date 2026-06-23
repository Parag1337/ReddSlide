class ApiConstants {
  ApiConstants._();

  static const String feed = '/api/feed';
  static const String feedQueue = '/api/feed/queue';
  static const String search = '/api/search';
  static const String searchDebug = '/api/search/debug';
  static const String health = '/api/health';
  static const String mediaStart = '/api/media/start';
  static const String media = '/api/media';
  static const String subredditsSync = '/api/subreddits/sync';
  static const String subredditsFetch = '/api/subreddits/fetch';

  static const int defaultLimit = 20;
  static const int maxLimit = 100;
  static const int searchDefaultLimit = 20;
  static const int connectTimeoutMs = 10000;
  static const int receiveTimeoutMs = 30000;
}
