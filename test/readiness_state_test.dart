import 'package:flutter_test/flutter_test.dart';
import 'package:redslide/features/slideshow/domain/readiness_state.dart';

void main() {
  group('ReadinessState', () {
    test('has exactly three values', () {
      expect(ReadinessState.values.length, 3);
    });

    test('values are distinct', () {
      expect(ReadinessState.ready, isNot(ReadinessState.likelyReady));
      expect(ReadinessState.likelyReady, isNot(ReadinessState.unavailable));
      expect(ReadinessState.ready, isNot(ReadinessState.unavailable));
    });

    test('can be instantiated', () {
      const ready = ReadinessState.ready;
      const likely = ReadinessState.likelyReady;
      const unavailable = ReadinessState.unavailable;
      expect(ready.name, 'ready');
      expect(likely.name, 'likelyReady');
      expect(unavailable.name, 'unavailable');
    });
  });
}
