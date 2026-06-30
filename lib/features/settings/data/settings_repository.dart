import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../domain/settings_model.dart';
import '../../../core/display_quality/display_quality_mode.dart';
import '../../../core/network/result.dart';
import '../../../core/errors/app_error.dart';
import '../../../core/constants/api_constants.dart';
import '../../../core/network/api_client.dart';
import '../../../features/slideshow/domain/media_filter.dart';

final settingsRepositoryProvider = Provider<SettingsRepository>((ref) {
  return SettingsRepository();
});

class SettingsRepository {
  static const _key = 'redslide_settings';

  Future<SettingsModel> load() => loadFull();

  Future<void> save(SettingsModel settings) => saveFull(settings);

  Future<SettingsModel> loadFull() async {
    final prefs = await SharedPreferences.getInstance();
    final qualityRaw = prefs.getString('${_key}_display_quality');
    final mediaFilterRaw = prefs.getString('${_key}_media_filter');
    return SettingsModel(
      backendUrl: prefs.getString('${_key}_url') ?? '',
      nsfwEnabled: prefs.getBool('${_key}_nsfw') ?? false,
      themeMode: prefs.getString('${_key}_theme') ?? 'system',
      slideshowIntervalSeconds: prefs.getInt('${_key}_interval') ?? 5,
      defaultSortMode: prefs.getString('${_key}_sort') ?? 'hot',
      subreddits: prefs.getStringList('${_key}_subreddits') ?? [],
      displayQualityMode: qualityRaw != null
          ? DisplayQualityMode.fromJson(qualityRaw)
          : DisplayQualityMode.smart,
      mediaFilter: mediaFilterRaw != null
          ? MediaFilter.fromQuery(mediaFilterRaw)
          : MediaFilter.all,
    );
  }

  Future<void> saveFull(SettingsModel settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('${_key}_url', settings.backendUrl);
    await prefs.setBool('${_key}_nsfw', settings.nsfwEnabled);
    await prefs.setString('${_key}_theme', settings.themeMode);
    await prefs.setInt('${_key}_interval', settings.slideshowIntervalSeconds);
    await prefs.setString('${_key}_sort', settings.defaultSortMode);
    await prefs.setStringList('${_key}_subreddits', settings.subreddits);
    await prefs.setString(
        '${_key}_display_quality', settings.displayQualityMode.toJson());
    await prefs.setString(
        '${_key}_media_filter', settings.mediaFilter.name);
  }

  Future<Result<bool>> validateBackendUrl(String url, ApiClient client) async {
    final result = await client.get(url + ApiConstants.health);
    return result.when(
      (data) {
        try {
          return const Success(true);
        } catch (_) {
          return Failure(ParseError('Invalid health response'));
        }
      },
      (error) => Failure(error),
    );
  }
}
