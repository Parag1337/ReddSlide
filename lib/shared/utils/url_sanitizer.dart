class UrlSanitizer {
  static String _sanitizeUrl(String url) {
    return url
        .replaceAll('external-preview.redd.it', 'preview.redd.it')
        .replaceAll('external-i.redd.it', 'i.redd.it');
  }

  static String sanitize(String url) {
    return _sanitizeUrl(url);
  }

  static List<String> sanitizeAll(List<String> urls) {
    return urls.map(_sanitizeUrl).toList();
  }

  static String? sanitizeOptional(String? url) {
    return url != null ? _sanitizeUrl(url) : null;
  }

  static bool hasPreviewUrl(String url) {
    return url.contains('preview.redd.it');
  }
}
