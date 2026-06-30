import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/result.dart';
import '../../../core/constants/api_constants.dart';
import '../../settings/providers/settings_provider.dart';
import '../domain/media_asset.dart';

final feedRepositoryProvider = Provider<FeedRepository>((ref) {
  final settings = ref.watch(settingsProvider).valueOrNull;
  final baseUrl = settings?.backendUrl ?? '';
  final apiClient = ref.watch(apiClientProvider(baseUrl));
  return FeedRepository(apiClient: apiClient);
});

class FeedRepository {
  final ApiClient _apiClient;

  FeedRepository({required this._apiClient});

  Future<Result<FeedResponse>> getFeed({
    int limit = ApiConstants.defaultLimit,
    String? after,
    String? subreddits,
    String? sort,
  }) async {
    final params = <String, dynamic>{'limit': limit};
    if (after != null) params['after'] = after;
    if (subreddits != null && subreddits.isNotEmpty) params['subreddits'] = subreddits;
    if (sort != null) params['sort'] = sort;

    final result = await _apiClient.get(
      ApiConstants.feed,
      queryParameters: params,
      fromJson: (json) => FeedResponse.fromJson(json as Map<String, dynamic>),
    );
    return result;
  }

  Future<Result<QueueResponse>> getQueueStatus() async {
    final result = await _apiClient.get(
      ApiConstants.feedQueue,
      fromJson: (json) => QueueResponse.fromJson(json as Map<String, dynamic>),
    );
    return result;
  }

  Future<Result<MediaAsset>> getMedia(String id) async {
    final result = await _apiClient.get(
      '${ApiConstants.media}/$id',
      fromJson: (json) => MediaAsset.fromJson(json as Map<String, dynamic>),
    );
    return result;
  }

  Future<Result<void>> startSlideshow(String id) async {
    final result = await _apiClient.post(
      '${ApiConstants.mediaStart}/$id',
    );
    return result.when((_) => const Success(null), (e) => Failure(e));
  }

  Future<Result<void>> syncSubreddits(List<String> subreddits) async {
    final result = await _apiClient.post(
      ApiConstants.subredditsSync,
      data: {'subreddits': subreddits},
    );
    return result.when((_) => const Success(null), (e) => Failure(e));
  }

  Future<Result<HealthResponse>> getHealth() async {
    final result = await _apiClient.get(
      ApiConstants.health,
      fromJson: (json) => HealthResponse.fromJson(json as Map<String, dynamic>),
    );
    return result;
  }
}

class FeedResponse {
  final List<MediaAsset> items;
  final String? after;
  final bool hasMore;
  final int totalResults;

  const FeedResponse({
    required this.items,
    this.after,
    required this.hasMore,
    this.totalResults = 0,
  });

  factory FeedResponse.fromJson(Map<String, dynamic> json) {
    final itemsList = (json['items'] as List<dynamic>)
        .map((e) => MediaAsset.fromJson(e as Map<String, dynamic>))
        .toList();
    return FeedResponse(
      items: itemsList,
      after: json['after'] as String?,
      hasMore: json['has_more'] as bool? ?? false,
      totalResults: json['total_results'] as int? ?? json['total'] as int? ?? 0,
    );
  }
}

class ProgressiveSearchResponse {
  final List<MediaAsset> items;
  final bool hasMore;
  final String? after;
  final String? sessionId;
  final bool done;

  const ProgressiveSearchResponse({
    required this.items,
    required this.hasMore,
    this.after,
    this.sessionId,
    this.done = false,
  });

  factory ProgressiveSearchResponse.fromJson(Map<String, dynamic> json) {
    final itemsList = (json['items'] as List<dynamic>)
        .map((e) => MediaAsset.fromJson(e as Map<String, dynamic>))
        .toList();
    return ProgressiveSearchResponse(
      items: itemsList,
      hasMore: json['has_more'] as bool? ?? false,
      after: json['after'] as String?,
      sessionId: json['session_id'] as String?,
      done: json['done'] as bool? ?? false,
    );
  }
}

class QueueResponse {
  final int total;

  const QueueResponse({required this.total});

  factory QueueResponse.fromJson(Map<String, dynamic> json) {
    return QueueResponse(
      total: json['total'] as int? ?? 0,
    );
  }
}

class HealthResponse {
  final String status;
  final bool database;
  final bool oauthValid;
  final int queueSize;
  final Map<String, dynamic> providers;

  const HealthResponse({
    required this.status,
    required this.database,
    required this.oauthValid,
    required this.queueSize,
    required this.providers,
  });

  factory HealthResponse.fromJson(Map<String, dynamic> json) {
    return HealthResponse(
      status: json['status'] as String? ?? 'unknown',
      database: json['database'] as bool? ?? false,
      oauthValid: json['oauth_valid'] as bool? ?? false,
      queueSize: json['queue_size'] as int? ?? 0,
      providers: json['providers'] as Map<String, dynamic>? ?? {},
    );
  }
}
