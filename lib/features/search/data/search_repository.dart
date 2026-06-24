import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/result.dart';
import '../../../core/constants/api_constants.dart';
import '../../settings/providers/settings_provider.dart';
import '../../feed/data/feed_repository.dart';
import '../../slideshow/domain/slideshow_source.dart';

final searchRepositoryProvider = Provider<SearchRepository>((ref) {
  final settings = ref.watch(settingsProvider).valueOrNull;
  final baseUrl = settings?.backendUrl ?? '';
  final apiClient = ref.watch(apiClientProvider(baseUrl));
  return SearchRepository(apiClient: apiClient);
});

class SearchRepository {
  final ApiClient _apiClient;

  SearchRepository({required this._apiClient});

  Future<Result<FeedResponse>> searchReddit({
    required String query,
    required SearchMode mode,
    int limit = 50,
    String? after,
    List<String>? subreddits,
  }) async {
    final params = <String, dynamic>{
      'q': query,
      'mode': mode == SearchMode.local ? 'local' : 'global',
      'limit': limit,
    };
    if (after != null) params['after'] = after;
    if (subreddits != null && subreddits.isNotEmpty) {
      params['subreddits'] = subreddits.join(',');
    }

    debugPrint('[SEARCH_REPOSITORY] searchReddit query=$query mode=$mode after=$after subreddits=$subreddits');

    final result = await _apiClient.get(
      ApiConstants.searchReddit,
      queryParameters: params,
      fromJson: (json) => FeedResponse.fromJson(json as Map<String, dynamic>),
    );
    result.when(
      (data) => debugPrint('[SEARCH_REPOSITORY] returned=${data.items.length} hasMore=${data.hasMore} after=${data.after}'),
      (e) => debugPrint('[SEARCH_REPOSITORY] error=$e'),
    );
    return result;
  }

  Future<Result<FeedResponse>> search({
    required String query,
    int limit = ApiConstants.searchDefaultLimit,
    int page = 1,
    List<String>? subreddits,
    String? mediaType,
    String? sort,
  }) async {
    final params = <String, dynamic>{
      'q': query,
      'limit': limit,
      'page': page,
    };
    if (subreddits != null && subreddits.isNotEmpty) {
      params['subreddits'] = subreddits.join(',');
    }
    if (mediaType != null) params['media_type'] = mediaType;
    if (sort != null) params['sort'] = sort;

    final result = await _apiClient.get(
      ApiConstants.search,
      queryParameters: params,
      fromJson: (json) => FeedResponse.fromJson(json as Map<String, dynamic>),
    );
    return result;
  }

  Future<Result<FeedResponse>> searchDebug({
    required String query,
    int limit = ApiConstants.searchDefaultLimit,
    int page = 1,
  }) async {
    final result = await _apiClient.get(
      ApiConstants.searchDebug,
      queryParameters: {
        'q': query,
        'limit': limit,
        'page': page,
      },
      fromJson: (json) => FeedResponse.fromJson(json as Map<String, dynamic>),
    );
    return result;
  }
}
