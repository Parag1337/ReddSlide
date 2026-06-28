import '../../feed/domain/media_asset.dart';

sealed class SlideshowSource {
  const SlideshowSource();
}

class SubredditSource extends SlideshowSource {
  final String subreddit;
  final String? sortMode;
  const SubredditSource({required this.subreddit, this.sortMode});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SubredditSource && subreddit == other.subreddit && sortMode == other.sortMode;

  @override
  int get hashCode => Object.hash(subreddit, sortMode);
}

class MultiSubredditSource extends SlideshowSource {
  final List<String> subreddits;
  final String? sortMode;
  const MultiSubredditSource({required this.subreddits, this.sortMode});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MultiSubredditSource &&
          const ListEquality().equals(subreddits, other.subreddits) &&
          sortMode == other.sortMode;

  @override
  int get hashCode => Object.hash(Object.hashAll(subreddits), sortMode);
}

class GlobalFeedSource extends SlideshowSource {
  const GlobalFeedSource();

  @override
  bool operator ==(Object other) => identical(this, other) || other is GlobalFeedSource;

  @override
  int get hashCode => runtimeType.hashCode;
}

enum SearchMode { local, global }

class SearchSource extends SlideshowSource {
  final String query;
  final SearchMode mode;
  final List<String>? subreddits;
  final String? mediaType;
  final String? sort;
  final List<MediaAsset>? initialResults;
  const SearchSource({
    required this.query,
    this.mode = SearchMode.global,
    this.subreddits,
    this.mediaType,
    this.sort,
    this.initialResults,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SearchSource &&
          query == other.query &&
          mode == other.mode &&
          const ListEquality().equals(subreddits ?? [], other.subreddits ?? []) &&
          mediaType == other.mediaType &&
          sort == other.sort &&
          identical(initialResults, other.initialResults);

  @override
  int get hashCode => Object.hash(query, mode, Object.hashAll(subreddits ?? []), mediaType, sort, initialResults.hashCode);
}

class GroupSource extends SlideshowSource {
  final String groupName;
  final List<String> subreddits;
  final String? filter;
  const GroupSource({required this.groupName, required this.subreddits, this.filter});

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GroupSource &&
          groupName == other.groupName &&
          const ListEquality().equals(subreddits, other.subreddits) &&
          filter == other.filter;

  @override
  int get hashCode => Object.hash(groupName, Object.hashAll(subreddits), filter);
}

class SlideshowRouteExtra {
  final SlideshowSource source;
  final int startIndex;
  const SlideshowRouteExtra({
    required this.source,
    this.startIndex = 0,
  });
}

class ListEquality {
  const ListEquality();
  bool equals(List a, List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
