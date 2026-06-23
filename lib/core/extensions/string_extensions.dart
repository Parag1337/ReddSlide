extension StringExtensions on String {
  String get truncateSubreddit {
    if (startsWith('r/')) return this;
    return 'r/$this';
  }

  String get formatNumber {
    final n = int.tryParse(this);
    if (n == null) return this;
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
    return toString();
  }
}
