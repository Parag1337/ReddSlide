import 'dart:math';
import '../../feed/domain/media_asset.dart';

class SubredditBuffer {
  final String subreddit;
  final List<MediaAsset> items;
  String? cursor;
  bool hasMore;
  bool isLoading;
  bool initialLoaded;
  int _consumePointer;

  SubredditBuffer({
    required this.subreddit,
    List<MediaAsset>? items,
    this.cursor,
    this.hasMore = true,
    this.isLoading = false,
    this.initialLoaded = false,
    int consumePointer = 0,
  })  : items = items ?? [],
        _consumePointer = consumePointer;

  bool get hasUnconsumed => _consumePointer < items.length;
  int get remainingCount => items.length - _consumePointer;

  MediaAsset? get nextUnconsumed =>
      hasUnconsumed ? items[_consumePointer] : null;

  void consumeNext() {
    if (hasUnconsumed) _consumePointer++;
  }
}

class SubredditPageResult {
  final List<MediaAsset> items;
  final String? cursor;
  final bool hasMore;

  SubredditPageResult({
    required this.items,
    this.cursor,
    required this.hasMore,
  });
}

typedef FetchSubredditPage = Future<SubredditPageResult> Function(
  String subreddit, {
  String? cursor,
});

class MergeEngine {
  final List<String> subreddits;
  final FetchSubredditPage _fetchPage;
  final Random _random = Random();

  final List<SubredditBuffer> _buffers = [];
  final List<MediaAsset> _merged = [];
  int _lastBufferIndex = -1;
  int _consecutiveCount = 0;
  String? _lastAuthor;
  String? _lastDomain;

  bool _initialized = false;

  static const int _lowWatermark = 8;
  static const int _mergeBatchSize = 20;
  static const int _initialLoadCount = 3;

  MergeEngine({
    required this.subreddits,
    required FetchSubredditPage fetchPage,
  }) : _fetchPage = fetchPage;

  List<SubredditBuffer> get buffers => _buffers;
  List<MediaAsset> get merged => _merged;
  bool get isInitialized => _initialized;
  bool get hasMoreSources =>
      _buffers.any((b) => b.hasMore || b.hasUnconsumed);

  Future<void> initialize() async {
    for (final sub in subreddits) {
      _buffers.add(SubredditBuffer(subreddit: sub));
    }

    final loadCount = min(_initialLoadCount, _buffers.length);
    final loadFutures = <Future<void>>[];
    for (int i = 0; i < loadCount; i++) {
      loadFutures.add(_loadBuffer(i));
    }
    await Future.wait(loadFutures);

    for (int i = loadCount; i < _buffers.length; i++) {
      _loadBuffer(i);
    }

    _generateBatch(_mergeBatchSize);
    _initialized = true;
  }

  Future<void> _loadBuffer(int index) async {
    final buffer = _buffers[index];
    if (buffer.isLoading || !buffer.hasMore) return;
    buffer.isLoading = true;

    try {
      final result = await _fetchPage(buffer.subreddit, cursor: buffer.cursor);
      _addToBuffer(index, result.items);
      buffer.cursor = result.cursor;
      buffer.hasMore = result.hasMore;
    } catch (_) {
    } finally {
      buffer.isLoading = false;
      buffer.initialLoaded = true;
    }
  }

  void _addToBuffer(int index, List<MediaAsset> newItems) {
    final buffer = _buffers[index];
    final existingIds = buffer.items.map((e) => e.id).toSet();
    for (final item in newItems) {
      if (!existingIds.contains(item.id)) {
        buffer.items.add(item);
        existingIds.add(item.id);
      }
    }
  }

  void autoRefill() {
    for (int i = 0; i < _buffers.length; i++) {
      final buffer = _buffers[i];
      if (buffer.remainingCount < _lowWatermark && buffer.hasMore && !buffer.isLoading) {
        _loadBuffer(i);
      }
    }
    _generateBatch(_mergeBatchSize);
  }

  List<MediaAsset> drainMerged() {
    final items = List<MediaAsset>.from(_merged);
    _merged.clear();
    return items;
  }

  void _generateBatch(int count) {
    final batchSize = min(count, _mergeBatchSize);
    for (int i = 0; i < batchSize; i++) {
      final asset = _selectNext();
      if (asset == null) break;
      _merged.add(asset);
    }
  }

  MediaAsset? _selectNext() {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final candidates = <_Candidate>[];

    for (int bi = 0; bi < _buffers.length; bi++) {
      final buffer = _buffers[bi];
      if (!buffer.hasUnconsumed) continue;

      if (_consecutiveCount >= 2 && _lastBufferIndex == bi) continue;

      final item = buffer.nextUnconsumed!;

      double score = 0.45 * _random.nextDouble();

      if (item.createdUtc != null) {
        final ageSeconds = max(1, now - item.createdUtc!);
        final freshness = max(0.0, 1.0 - (ageSeconds / 604800.0));
        score += 0.35 * freshness;
      } else {
        score += 0.35 * 0.5;
      }

      double diversity = 0.0;
      if (_lastBufferIndex == bi) {
        diversity -= 0.20;
      }
      if (item.author == _lastAuthor) {
        diversity -= 0.05;
      }
      final domain = _extractDomain(item.mediaUrl);
      if (domain != null && domain == _lastDomain) {
        diversity -= 0.02;
      }

      score += 0.20 * diversity;

      candidates.add(_Candidate(bufferIndex: bi, asset: item, score: score));
    }

    if (candidates.isEmpty) {
      if (_buffers.any((b) => b.hasUnconsumed)) {
        for (int bi = 0; bi < _buffers.length; bi++) {
          if (!_buffers[bi].hasUnconsumed) continue;
          final item = _buffers[bi].nextUnconsumed!;
          if (_lastBufferIndex == bi) {
            _consecutiveCount++;
          } else {
            _consecutiveCount = 1;
            _lastBufferIndex = bi;
          }
          _lastAuthor = item.author;
          _lastDomain = _extractDomain(item.mediaUrl);
          _buffers[bi].consumeNext();
          return item;
        }
      }
      return null;
    }

    candidates.sort((a, b) => b.score.compareTo(a.score));
    final best = candidates.first;

    if (_lastBufferIndex == best.bufferIndex) {
      _consecutiveCount++;
    } else {
      _consecutiveCount = 1;
      _lastBufferIndex = best.bufferIndex;
    }

    _lastAuthor = best.asset.author;
    _lastDomain = _extractDomain(best.asset.mediaUrl);

    _buffers[best.bufferIndex].consumeNext();

    return best.asset;
  }

  String? _extractDomain(String url) {
    try {
      final uri = Uri.parse(url);
      return uri.host;
    } catch (_) {
      return null;
    }
  }

  void dispose() {
    _buffers.clear();
    _merged.clear();
  }
}

class _Candidate {
  final int bufferIndex;
  final MediaAsset asset;
  double score;

  _Candidate({
    required this.bufferIndex,
    required this.asset,
    required this.score,
  });
}
