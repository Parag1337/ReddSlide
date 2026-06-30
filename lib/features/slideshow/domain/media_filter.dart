enum MediaFilter {
  all,
  images,
  videos;

  String get queryValue => name;

  static MediaFilter fromQuery(String? value) {
    return switch (value) {
      'images' => MediaFilter.images,
      'videos' => MediaFilter.videos,
      _ => MediaFilter.all,
    };
  }
}
