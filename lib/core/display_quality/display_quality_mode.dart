enum DisplayQualityMode {
  smart,
  original,
  auto;

  String get displayLabel {
    switch (this) {
      case DisplayQualityMode.smart:
        return 'Smart (Recommended)';
      case DisplayQualityMode.original:
        return 'Original (Advanced)';
      case DisplayQualityMode.auto:
        return 'Auto';
    }
  }

  String get displayDescription {
    switch (this) {
      case DisplayQualityMode.smart:
        return 'Optimized for your device\'s display. Uses a display-sized image that '
            'looks virtually identical during normal viewing while reducing memory usage '
            'and improving slideshow speed.';
      case DisplayQualityMode.original:
        return 'Displays images at their full resolution. Provides the best quality for '
            'deep zooming. May increase memory usage and reduce slideshow performance '
            'with extremely large images.';
      case DisplayQualityMode.auto:
        return 'Automatic (reserved for future use)';
    }
  }

  String toJson() => name;

  static DisplayQualityMode fromJson(String value) {
    return DisplayQualityMode.values.firstWhere(
      (m) => m.name == value,
      orElse: () => DisplayQualityMode.smart,
    );
  }
}
