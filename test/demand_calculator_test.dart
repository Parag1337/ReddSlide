import 'package:flutter_test/flutter_test.dart';
import 'package:redslide/features/slideshow/domain/readiness_state.dart';
import 'package:redslide/features/slideshow/domain/demand_calculator.dart';

void main() {
  final calculator = const DemandCalculator();

  group('DemandCalculator.computeNeedCount', () {
    test('all ready returns correct need', () {
      final states = [ReadinessState.ready, ReadinessState.ready, ReadinessState.ready];
      expect(calculator.computeNeedCount(states, targetBudget: 10), 7);
    });

    test('all unavailable returns full budget', () {
      final states = [ReadinessState.unavailable, ReadinessState.unavailable];
      expect(calculator.computeNeedCount(states, targetBudget: 5), 5);
    });

    test('all likelyReady uses 0.5 weight', () {
      final states = [ReadinessState.likelyReady, ReadinessState.likelyReady];
      expect(calculator.computeNeedCount(states, targetBudget: 3), 2);
    });

    test('mixed states computes correctly', () {
      final states = [
        ReadinessState.ready,
        ReadinessState.likelyReady,
        ReadinessState.unavailable,
      ];
      // score = 1.0 + 0.5 + 0.0 = 1.5, ceil = 2, need = 10 - 2 = 8
      expect(calculator.computeNeedCount(states, targetBudget: 10), 8);
    });

    test('empty list returns full budget', () {
      expect(calculator.computeNeedCount([], targetBudget: 10), 10);
    });

    test('zero budget returns zero', () {
      final states = [ReadinessState.ready, ReadinessState.ready];
      expect(calculator.computeNeedCount(states, targetBudget: 0), 0);
    });

    test('negative budget returns zero', () {
      final states = [ReadinessState.ready];
      expect(calculator.computeNeedCount(states, targetBudget: -1), 0);
    });

    test('score exceeding budget returns zero', () {
      final states = List.filled(10, ReadinessState.ready);
      expect(calculator.computeNeedCount(states, targetBudget: 5), 0);
    });

    test('score exactly matching budget returns zero', () {
      final states = [ReadinessState.ready, ReadinessState.ready];
      expect(calculator.computeNeedCount(states, targetBudget: 2), 0);
    });

    test('single ready returns budget minus one', () {
      final states = [ReadinessState.ready];
      expect(calculator.computeNeedCount(states, targetBudget: 10), 9);
    });

    test('large list exceeding budget returns zero', () {
      final states = List.filled(100, ReadinessState.ready);
      expect(calculator.computeNeedCount(states, targetBudget: 40), 0);
    });

    test('long tail of unavailable items', () {
      final states = [
        ReadinessState.ready,
        ReadinessState.unavailable,
        ReadinessState.unavailable,
        ReadinessState.unavailable,
      ];
      // score = 1.0, ceil = 1, need = 4 - 1 = 3
      expect(calculator.computeNeedCount(states, targetBudget: 4), 3);
    });

    test('single likelyReady with budget 1', () {
      final states = [ReadinessState.likelyReady];
      // score = 0.5, ceil = 1, need = 1 - 1 = 0
      expect(calculator.computeNeedCount(states, targetBudget: 1), 0);
    });

    test('two likelyReady with budget 2', () {
      final states = [ReadinessState.likelyReady, ReadinessState.likelyReady];
      // score = 1.0, ceil = 1, need = 2 - 1 = 1
      expect(calculator.computeNeedCount(states, targetBudget: 2), 1);
    });

    test('const constructor creates identical instances', () {
      const a = DemandCalculator();
      const b = DemandCalculator();
      expect(a, same(b));
    });
  });
}
