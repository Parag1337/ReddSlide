import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/result.dart';
import '../../../core/constants/api_constants.dart';
import '../../settings/providers/settings_provider.dart';
import '../../feed/data/feed_repository.dart';

final searchRepositoryProvider = Provider<SearchRepository>((ref) {
  final settings = ref.watch(settingsProvider).valueOrNull;
  final baseUrl = settings?.backendUrl ?? '';
  final apiClient = ref.watch(apiClientProvider(baseUrl));
  return SearchRepository(apiClient: apiClient);
});

class SearchRepository {
  final ApiClient _apiClient;

  SearchRepository({required this._apiClient});

  Future<Result<FeedResponse>> search({
    required String query,
    int limit = ApiConstants.searchDefaultLimit,
    int page = 1,
  }) async {
    final result = await _apiClient.get(
      ApiConstants.search,
      queryParameters: {
        'q': query,
        'limit': limit,
        'page': page,
      },
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
