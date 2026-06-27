import 'dart:developer';
import 'dart:math' hide log;
import '../../../core/media/media_source.dart';
import '../../feed/domain/media_asset.dart';

class SourceBuffer {
  final MediaSource source;
  final List<MediaAsset> items;
  bool hasMore;
  bool isLoading;
  int _consumePointer;

  SourceBuffer({
    required this.source,
    List<MediaAsset>? items,
    this.hasMore = true,
    this.isLoading = false,
    int consumePointer = 0,
  })  : items = items ?? [],
        _consumePointer = consumePointer;

  bool get hasUnconsumed => _consumePointer < items.length;
  int get remainingCount => items.length - _consumePointer;
  bool get isExhausted => !hasMore && !hasUnconsumed;

  MediaAsset? get nextUnconsumed =>
      hasUnconsumed ? items[_consumePointer] : null;

  void consumeNext() {
    if (hasUnconsumed) _consumePointer++;
  }

  Future<void> loadNextPage() async {
    if (isLoading || !hasMore) return;
    isLoading = true;
    try {
      final page = await source.loadNext();
      _addItems(page.items);
      hasMore = page.hasMore;
    } catch (e) {
      log('[BUFFER] loadNextPage error source=$source error=$e');
    } finally {
      isLoading = false;
    }
  }

  void _addItems(List<MediaAsset> newItems) {
    final existingIds = items.map((e) => e.id).toSet();
    int added = 0;
    for (final item in newItems) {
      if (!existingIds.contains(item.id)) {
        items.add(item);
        existingIds.add(item.id);
        added++;
      }
    }
    if (added != newItems.length) {
      log('[BUFFER] dedup incoming=${newItems.length} new=$added duplicates=${newItems.length - added}');
    }
  }
}

class MergeEngine {
  final List<MediaSource> _sources;
  final Random _random = Random();

  final List<SourceBuffer> _buffers = [];
  final List<MediaAsset> _merged = [];
  int _lastBufferIndex = -1;
  int _consecutiveCount = 0;
  String? _lastAuthor;
  String? _lastDomain;

  bool _initialized = false;

  static const int _lowWatermark = 8;
  static const int _mergeBatchSize = 20;

  MergeEngine({
    required List<MediaSource> sources,
  }) : _sources = sources;

  List<MediaSource> get sources => _sources;
  List<SourceBuffer> get buffers => _buffers;
  List<MediaAsset> get merged => _merged;
  bool get isInitialized => _initialized;
  bool get hasMoreSources =>
      _buffers.any((b) => b.hasMore || b.hasUnconsumed);

  Future<void> initialize() async {
    for (final source in _sources) {
      _buffers.add(SourceBuffer(source: source));
    }

    final loadFutures = <Future<void>>[];
    for (int i = 0; i < _buffers.length; i++) {
      loadFutures.add(_buffers[i].loadNextPage());
    }
    await Future.wait(loadFutures);

    _generateBatch(_mergeBatchSize);
    _initialized = true;
  }

  Future<void> autoRefill() async {
    final futures = <Future<void>>[];
    for (int i = 0; i < _buffers.length; i++) {
      final buffer = _buffers[i];
      if (buffer.remainingCount < _lowWatermark && buffer.hasMore && !buffer.isLoading) {
        log('[AUTOREFILL] buffer=$i remaining=${buffer.remainingCount} lowWatermark=$_lowWatermark');
        futures.add(buffer.loadNextPage());
      }
    }
    if (futures.isNotEmpty) {
      log('[AUTOREFILL] awaiting ${futures.length} refills');
      await Future.wait(futures);
    }
    _generateBatch(_mergeBatchSize);
  }

  List<MediaAsset> drainMerged() {
    final items = List<MediaAsset>.from(_merged);
    _merged.clear();
    return items;
  }

  void generateBatch() => _generateBatch(_mergeBatchSize);

  void _generateBatch(int count) {
    final batchSize = min(count, _mergeBatchSize);
    int selected = 0;
    for (int i = 0; i < batchSize; i++) {
      final asset = _selectNext();
      if (asset == null) break;
      _merged.add(asset);
      selected++;
    }
    log('[MERGE_GENERATE] selected=$selected target=$batchSize buffers=${_buffers.length}');
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

    MediaAsset? result;
    if (candidates.isEmpty) {
      if (_buffers.any((b) => b.hasUnconsumed)) {
        for (int bi = 0; bi < _buffers.length; bi++) {
          if (!_buffers[bi].hasUnconsumed) continue;
          result = _buffers[bi].nextUnconsumed!;
          if (_lastBufferIndex == bi) {
            _consecutiveCount++;
          } else {
            _consecutiveCount = 1;
            _lastBufferIndex = bi;
          }
          _lastAuthor = result.author;
          _lastDomain = _extractDomain(result.mediaUrl);
          _buffers[bi].consumeNext();
          break;
        }
      }
    } else {
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
      result = best.asset;
    }

    log('[MERGE_SELECT] selected=${result?.id ?? "null"} candidates=${candidates.length}');
    return result;
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
    for (final source in _sources) {
      source.dispose();
    }
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
