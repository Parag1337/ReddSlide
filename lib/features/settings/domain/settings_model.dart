import '../../../core/display_quality/display_quality_mode.dart';
import '../../../features/slideshow/domain/media_filter.dart';

class SettingsModel {
  final String backendUrl;
  final bool nsfwEnabled;
  final String themeMode;
  final int slideshowIntervalSeconds;
  final String defaultSortMode;
  final List<String> subreddits;
  final DisplayQualityMode displayQualityMode;
  final MediaFilter mediaFilter;

  const SettingsModel({
    this.backendUrl = '',
    this.nsfwEnabled = false,
    this.themeMode = 'system',
    this.slideshowIntervalSeconds = 5,
    this.defaultSortMode = 'hot',
    this.subreddits = const [],
    this.displayQualityMode = DisplayQualityMode.smart,
    this.mediaFilter = MediaFilter.all,
  });

  SettingsModel copyWith({
    String? backendUrl,
    bool? nsfwEnabled,
    String? themeMode,
    int? slideshowIntervalSeconds,
    String? defaultSortMode,
    List<String>? subreddits,
    DisplayQualityMode? displayQualityMode,
    MediaFilter? mediaFilter,
  }) {
    return SettingsModel(
      backendUrl: backendUrl ?? this.backendUrl,
      nsfwEnabled: nsfwEnabled ?? this.nsfwEnabled,
      themeMode: themeMode ?? this.themeMode,
      slideshowIntervalSeconds:
          slideshowIntervalSeconds ?? this.slideshowIntervalSeconds,
      defaultSortMode: defaultSortMode ?? this.defaultSortMode,
      subreddits: subreddits ?? this.subreddits,
      displayQualityMode: displayQualityMode ?? this.displayQualityMode,
      mediaFilter: mediaFilter ?? this.mediaFilter,
    );
  }

  Map<String, dynamic> toJson() => {
        'backendUrl': backendUrl,
        'nsfwEnabled': nsfwEnabled,
        'themeMode': themeMode,
        'slideshowIntervalSeconds': slideshowIntervalSeconds,
        'defaultSortMode': defaultSortMode,
        'subreddits': subreddits,
        'displayQualityMode': displayQualityMode.toJson(),
        'mediaFilter': mediaFilter.name,
      };

  factory SettingsModel.fromJson(Map<String, dynamic> json) => SettingsModel(
        backendUrl: json['backendUrl'] as String? ?? '',
        nsfwEnabled: json['nsfwEnabled'] as bool? ?? false,
        themeMode: json['themeMode'] as String? ?? 'system',
        slideshowIntervalSeconds:
            json['slideshowIntervalSeconds'] as int? ?? 5,
        defaultSortMode: json['defaultSortMode'] as String? ?? 'hot',
        subreddits: (json['subreddits'] as List<dynamic>?)
                ?.map((e) => e as String)
                .toList() ??
            [],
        displayQualityMode: json['displayQualityMode'] != null
            ? DisplayQualityMode.fromJson(json['displayQualityMode'] as String)
            : DisplayQualityMode.smart,
        mediaFilter: MediaFilter.fromQuery(json['mediaFilter'] as String?),
      );
}
