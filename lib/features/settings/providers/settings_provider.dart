import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../domain/settings_model.dart';
import '../data/settings_repository.dart';
import '../../../core/network/api_client.dart';
import '../../../core/network/result.dart';
import '../../../core/constants/api_constants.dart';
import '../../../core/errors/app_error.dart';

final settingsProvider =
    AsyncNotifierProvider<SettingsNotifier, SettingsModel>(SettingsNotifier.new);

class SettingsNotifier extends AsyncNotifier<SettingsModel> {
  @override
  Future<SettingsModel> build() async {
    final repo = ref.read(settingsRepositoryProvider);
    return repo.loadFull();
  }

  Future<void> updateBackendUrl(String url) async {
    final current = state.value ?? const SettingsModel();
    final updated = current.copyWith(backendUrl: url);
    state = AsyncData(updated);
    final repo = ref.read(settingsRepositoryProvider);
    await repo.saveFull(updated);
  }

  Future<void> toggleNsfw(bool value) async {
    final current = state.value ?? const SettingsModel();
    final updated = current.copyWith(nsfwEnabled: value);
    state = AsyncData(updated);
    final repo = ref.read(settingsRepositoryProvider);
    await repo.saveFull(updated);
  }

  Future<void> setThemeMode(String mode) async {
    final current = state.value ?? const SettingsModel();
    final updated = current.copyWith(themeMode: mode);
    state = AsyncData(updated);
    final repo = ref.read(settingsRepositoryProvider);
    await repo.saveFull(updated);
  }

  Future<void> setSlideshowInterval(int seconds) async {
    final current = state.value ?? const SettingsModel();
    final updated = current.copyWith(slideshowIntervalSeconds: seconds);
    state = AsyncData(updated);
    final repo = ref.read(settingsRepositoryProvider);
    await repo.saveFull(updated);
  }

  Future<void> setDefaultSortMode(String mode) async {
    final current = state.value ?? const SettingsModel();
    final updated = current.copyWith(defaultSortMode: mode);
    state = AsyncData(updated);
    final repo = ref.read(settingsRepositoryProvider);
    await repo.saveFull(updated);
  }

  Future<void> _syncSubredditsToBackend(List<String> subreddits) async {
    final current = state.valueOrNull;
    if (current == null || current.backendUrl.isEmpty) return;
    try {
      final client = ApiClient(baseUrl: current.backendUrl);
      await client.post(
        ApiConstants.subredditsSync,
        data: {'subreddits': subreddits},
      );
    } catch (_) {}
  }

  Future<void> addSubreddit(String name) async {
    final current = state.value ?? const SettingsModel();
    if (current.subreddits.contains(name)) return;
    final updatedSubs = [...current.subreddits, name];
    final updated = current.copyWith(subreddits: updatedSubs);
    state = AsyncData(updated);
    final repo = ref.read(settingsRepositoryProvider);
    await repo.saveFull(updated);
    _syncSubredditsToBackend(updatedSubs);
    debugPrint('[SETTINGS] subreddits=${updated.subreddits}');
  }

  Future<void> removeSubreddit(String name) async {
    final current = state.value ?? const SettingsModel();
    final updatedSubs = current.subreddits.where((s) => s != name).toList();
    final updated = current.copyWith(subreddits: updatedSubs);
    state = AsyncData(updated);
    final repo = ref.read(settingsRepositoryProvider);
    await repo.saveFull(updated);
    _syncSubredditsToBackend(updatedSubs);
    debugPrint('[SETTINGS] subreddits=${updated.subreddits}');
  }

  Future<void> updateSubreddit(String oldName, String newName) async {
    final current = state.value ?? const SettingsModel();
    final updatedSubs = current.subreddits.map((s) => s == oldName ? newName : s).toList();
    final updated = current.copyWith(subreddits: updatedSubs);
    state = AsyncData(updated);
    final repo = ref.read(settingsRepositoryProvider);
    await repo.saveFull(updated);
    _syncSubredditsToBackend(updatedSubs);
  }

  Result<bool> validateBackendUrl(String url) {
    if (url.isEmpty) return Failure(const NotConfiguredError());
    return const Success(true);
  }
}
