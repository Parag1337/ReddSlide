import '../../feed/domain/media_asset.dart';

class PlaylistManager {
  final List<MediaAsset> _items = [];
  int _currentIndex = 0;

  List<MediaAsset> get items => _items;
  int get currentIndex => _currentIndex;
  int get length => _items.length;
  bool get isEmpty => _items.isEmpty;
  bool get hasPrevious => _currentIndex > 0;
  bool get hasNext => _currentIndex < _items.length - 1;
  bool get isNearEnd => _currentIndex >= _items.length - 5;

  MediaAsset? get current =>
      _currentIndex >= 0 && _currentIndex < _items.length
          ? _items[_currentIndex]
          : null;

  MediaAsset? itemAt(int index) =>
      index >= 0 && index < _items.length ? _items[index] : null;

  void append(List<MediaAsset> items) {
    _items.addAll(items);
  }

  MediaAsset? next() {
    if (_currentIndex + 1 < _items.length) {
      _currentIndex++;
      return _items[_currentIndex];
    }
    return null;
  }

  MediaAsset? previous() {
    if (_currentIndex > 0) {
      _currentIndex--;
      return _items[_currentIndex];
    }
    return null;
  }

  void jumpTo(int index) {
    if (index >= 0 && index < _items.length) {
      _currentIndex = index;
    }
  }

  int get remainingCount => _items.length - _currentIndex - 1;

  bool advance() {
    if (_currentIndex + 1 < _items.length) {
      _currentIndex++;
      return true;
    }
    return false;
  }

  void clear() {
    _items.clear();
    _currentIndex = 0;
  }

  void dispose() {
    clear();
  }
}
